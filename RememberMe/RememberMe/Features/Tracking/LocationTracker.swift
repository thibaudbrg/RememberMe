import Core
import CoreLocation
import CoreMotion
import Foundation
import OSLog
import Observation
import Persistence
import UIKit

/// Phase 5 runtime adapter for the live background tracker. Hosts the actual
/// `CLLocationManager` and `CMMotionActivityManager`, bridges every delegate
/// callback into a `TrackerInput`, and applies the `TrackerAction`s returned by
/// the pure state machine (`Core.TrackerStateMachine`) to the hardware.
///
/// Owns the two long-running timers:
/// - 180-second "you've been stationary in tracking long enough — close the trip" timer.
///   Started on motion-stationary in `.tracking`, cancelled on motion-moving.
/// - 15-minute "you've been stationary long enough — go to deep sleep" timer.
///   Started by the state machine on entry to `.stationary`.
///
/// Phase 5 deliberately does NOT yet persist trips or path points. `openTrip` /
/// `closeTrip` actions log to OSLog. Phase 6 wires those into `EventWriter`.
@MainActor
@Observable
final class LocationTracker: NSObject {
    /// Current state machine state. Observable so the Settings UI can show it.
    private(set) var state: TrackerState = .off
    /// Ambient flags (enabled + authorized).
    private(set) var environment: TrackerEnvironment = .initial
    /// Latest known authorization status. Observable so the Settings UI shows it.
    private(set) var authorizationStatus: CLAuthorizationStatus
    /// Latest known accuracy authorization. When `.reducedAccuracy` (Precise
    /// Location off), every fix arrives at 1–5 km accuracy and the 65 m gate
    /// rejects all of them — trips open/close but no activity row is written.
    /// Observable so the Settings UI can warn the user.
    private(set) var accuracyAuthorization: CLAccuracyAuthorization

    /// Ring buffer of recent tracker events for the diagnostic log sheet, newest
    /// first. Backed by an on-disk file (`TrackerLogStore`) so it survives the
    /// process being suspended OR terminated-and-relaunched in the background —
    /// which is exactly when you want to see what the tracker did while the app
    /// wasn't open. Loaded from disk on launch.
    private(set) var recentEvents: [TrackerLogEntry] = []
    private let recentEventsLimit = 2000
    /// On-disk backing for `recentEvents`. Nil only if the support directory is
    /// unavailable (never, in practice). Same file protection as the DB.
    private let logStore = TrackerLogStore()
    /// Last motion-activity category we logged. Used to suppress duplicate
    /// "still walking" entries — only log when the category changes.
    private var lastLoggedMotionCategory: String?
    /// True only while the tracker's own `requestAlwaysAuthorization()` flow is
    /// mid-escalation (When-In-Use granted, Always not yet asked). Gates the
    /// auto-escalation in the auth callback so a When-In-Use grant from the map's
    /// locate-me flow — or a cold launch — never burns the one-shot Always prompt.
    private var pendingAlwaysEscalation = false

    struct TrackerLogEntry: Identifiable, Sendable, Hashable {
        let id = UUID()
        let timestamp: Date
        let category: Category
        let message: String
        let detail: String?

        enum Category: String, Sendable, Hashable, CaseIterable {
            case stateTransition
            case fix
            case visit
            case motion
            case auth
            case timer
            case user
            case error
        }
    }

    func clearLog() {
        recentEvents = []
        lastLoggedMotionCategory = nil
        logStore.clear()
    }

    private func recordLog(
        _ category: TrackerLogEntry.Category,
        _ message: String,
        detail: String? = nil
    ) {
        let entry = TrackerLogEntry(timestamp: Date(), category: category, message: message, detail: detail)
        recentEvents.insert(entry, at: 0)
        if recentEvents.count > recentEventsLimit {
            recentEvents.removeLast(recentEvents.count - recentEventsLimit)
        }
        logStore.append(entry, compactingTo: recentEventsLimit)
    }

    private let locationManager: CLLocationManager
    private let motionManager: CMMotionActivityManager
    private var sleepThresholdTimer: Timer?
    private var deepSleepThresholdTimer: Timer?
    /// One-shot ~60s timer armed on entry to `.waking`. If no motion/SLC/visit
    /// confirms movement before it fires, we fall back to `.stationary` so we
    /// don't sit in `.waking` with probe GPS running forever (the failure mode
    /// when Motion & Fitness is denied).
    private var wakingProbeTimer: Timer?
    /// Wall-clock instant the 15-min deep-sleep timer is due to fire. Timers don't
    /// fire while the process is suspended, so we also record the deadline and check
    /// it lazily on any wake event — if it has passed, we cut straight to .deepSleep.
    private var deepSleepDeadline: Date?
    private var motionUpdatesActive = false

    // MARK: - Persistence (Phase 6)
    /// Set by AppEnvironment after the DB opens. Until then, persistence calls
    /// no-op (logged). Once set, every trip's open/append/close lands in the
    /// `events` + `path_points` tables.
    private var tripWriter: LiveTripWriter?
    /// In-flight trip state — id, start time, next sequence number, and a
    /// small in-memory buffer of fixes that haven't been flushed to disk yet.
    private struct OpenTrip {
        let id: UUID
        let startedAt: Date
        let tzOffsetMinutes: Int
        var nextSeq: Int
        var lastFixTime: Date
        var pendingPoints: [PathPoint]
        /// First fix coordinate captured during this trip (set on the first
        /// appendFix). Used as the activity's start coordinate when the trip
        /// closes. Nil if no fix landed before close (rare but possible).
        var startCoord: Coordinate?
        /// Latest fix coordinate. Used as the activity's end coordinate.
        var endCoord: Coordinate?
        /// Sum of consecutive haversine distances. Cheap to maintain online
        /// vs. re-querying path_points on close.
        var distanceMeters: Double
        /// Confidence-weighted vote tally of motion samples seen during this
        /// trip. On close, we ask it for the dominant mode.
        var motionAggregator: MotionAggregator
    }
    private var openTrip: OpenTrip?

    /// Currently-open visit (one at a time — you're physically in one place
    /// at any moment). Created on a `CLVisit` arrival callback; updated on
    /// the departure callback. Nil when no visit is active.
    private struct OpenVisit {
        let eventID: UUID
        let placeID: String
        let arrival: Date
        let coordinate: Coordinate
        /// False when the arrival happened before the DB was bound — the row
        /// doesn't exist yet, so the departure must insert instead of update.
        let persisted: Bool
    }
    private var openVisit: OpenVisit?
    /// Breadcrumb of the currently-open trip, including points not yet flushed
    /// to disk. The map draws this as the live "where I've been so far" line.
    /// Cleared when the trip closes (the persisted path takes over).
    private(set) var livePathCoordinates: [Coordinate] = []
    /// Flush threshold — write to disk every N buffered points so a crash
    /// loses at most this many. Each write is small, ~5 IOPS — cheap.
    private let flushPointsThreshold = 5
    /// Callback invoked on the main actor after a trip finalises so the UI
    /// can re-fetch counts / day-timeline. Wired by AppEnvironment.
    private var onTripFinalised: (() async -> Void)?

    /// Serial chain of pending DB writes. Every persistence operation is appended
    /// to this chain so writes execute in submission order on one task at a time —
    /// the single SQLCipher connection cannot survive concurrent `BEGIN IMMEDIATE`.
    /// Chaining also guarantees a visit departure UPDATE never runs before its
    /// arrival INSERT (M13) and that finalise never races the point flush (H1).
    private var persistChain: Task<Void, Never> = Task {}

    /// Routes one DB write through the serial chain. The op runs only after every
    /// previously-enqueued op completes, preserving FIFO order across event types.
    /// Detached so the synchronous DB write runs off the main actor (as the
    /// previous `Task.detached` writes did), not on the UI thread.
    private func enqueuePersist(
        stage: String,
        _ op: @escaping @Sendable () async throws -> Void
    ) {
        persistChain = Task.detached(priority: .userInitiated) { [prev = persistChain] in
            await prev.value
            do {
                try await op()
            } catch {
                await self.logPersistError(stage, error)
            }
        }
    }

    private static let log = Logger(subsystem: "com.tibo.rememberme", category: "tracker")

    override init() {
        let lm = CLLocationManager()
        locationManager = lm
        motionManager = CMMotionActivityManager()
        authorizationStatus = lm.authorizationStatus
        accuracyAuthorization = lm.accuracyAuthorization
        environment = TrackerEnvironment(
            enabled: false,
            authorizedAlways: lm.authorizationStatus == .authorizedAlways
        )
        super.init()
        lm.delegate = self
        // Manual sleep management — we know better than iOS's heuristic.
        lm.pausesLocationUpdatesAutomatically = false

        // Restore the persisted diagnostic log so the sheet shows what the
        // tracker did across previous (possibly background) sessions, then mark
        // this launch so gaps between sessions are visible in the timeline.
        recentEvents = logStore.loadNewestFirst(limit: recentEventsLimit)
        let launchKind = UserDefaults.standard.bool(forKey: Settings.liveTrackingEnabledKey)
            ? (lm.authorizationStatus == .authorizedAlways ? "tracking armed" : "tracking on, not Always")
            : "tracking off"
        recordLog(.user, "app launched", detail: "\(launchKind) · auth=\(authString(lm.authorizationStatus))")

        // Arm synchronously when the user has tracking on. iOS delivers the
        // SLC/visit event that background-relaunched us within milliseconds —
        // long before the async DB open calls setEnabled. Without this the
        // machine sits in .off and drops the wake event, missing the trip.
        if UserDefaults.standard.bool(forKey: Settings.liveTrackingEnabledKey) {
            consume(.userToggled(true))
        }
    }

    // MARK: - Public API (called from Settings UI / AppEnvironment)

    /// Wire the persistence layer. Called by AppEnvironment after the DB opens.
    /// Until this is called, `openTrip` / `closeTrip` actions log but don't
    /// persist — safe in unit tests that don't touch the DB.
    func bindPersistence(
        writer: LiveTripWriter,
        onTripFinalised: @escaping () async -> Void
    ) {
        self.tripWriter = writer
        self.onTripFinalised = onTripFinalised
        Self.log.notice("persistence bound")
        recordLog(.user, "persistence bound", detail: "writer is ready; trips will land in the DB")

        // A trip may already be open in memory (it started before the DB bound —
        // e.g. a background relaunch armed tracking and fixes landed before the
        // async open completed). Its events row was never inserted, so the
        // buffered points would FK-fail on flush. Create the row now, then flush.
        if let trip = openTrip {
            let id = trip.id
            let start = trip.startedAt
            let tz = trip.tzOffsetMinutes
            enqueuePersist(stage: "openTrip (mid-trip bind)") {
                try writer.openTrip(eventID: id, start: start, tzOffsetMinutes: tz)
            }
            flushPendingPoints()
        }
    }

    /// Called when the user flips the Live tracking toggle.
    func setEnabled(_ enabled: Bool) {
        Self.log.notice("setEnabled(\(enabled))")
        recordLog(.user, enabled ? "user enabled tracking" : "user disabled tracking")
        consume(.userToggled(enabled))
    }

    /// Triggers the iOS "Allow Always" prompt. Handles the two-step iOS flow
    /// (When-In-Use first, then escalate to Always via the delegate callback).
    func requestAlwaysAuthorization() {
        switch authorizationStatus {
        case .notDetermined:
            // When-In-Use prompts first; the auth callback escalates to Always
            // once granted. Mark the escalation as ours so the callback only
            // upgrades for this flow, not for an unrelated When-In-Use grant.
            pendingAlwaysEscalation = true
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    /// Opens the system Settings app at this app's page. Used when the user has
    /// denied authorization and we need them to flip it manually.
    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - State-machine bridge

    private func consume(_ input: TrackerInput) {
        let result = TrackerStateMachine.next(from: state, environment: environment, input: input)
        let oldState = state
        state = result.newState
        environment = result.environment
        if oldState != result.newState {
            Self.log.notice("state \(oldState.rawValue, privacy: .public) → \(result.newState.rawValue, privacy: .public) (input: \(String(describing: input), privacy: .public))")
            recordLog(
                .stateTransition,
                "\(oldState.rawValue) → \(result.newState.rawValue)",
                detail: "trigger: \(describe(input))"
            )
        }
        for action in result.actions {
            apply(action)
        }
        // Manage the .waking probe timeout outside the pure state machine: arm it
        // on entry to .waking, cancel it on any exit. (Guard on oldState so we
        // don't re-arm on no-op .waking inputs.)
        if oldState != result.newState {
            if result.newState == .waking {
                startWakingProbeTimer()
            } else if oldState == .waking {
                cancelWakingProbeTimer()
            }
        }
    }

    private func describe(_ input: TrackerInput) -> String {
        switch input {
        case .userToggled(let on): return "userToggled(\(on))"
        case .authorizationChanged(let always): return "auth changed (always=\(always))"
        case .significantLocationChange: return "significant location change"
        case .visitArrived: return "visit arrived"
        case .visitDeparted: return "visit departed"
        case .motionMoving: return "motion: moving"
        case .motionStationary: return "motion: stationary"
        case .sleepThresholdReached: return "180s sleep timer fired"
        case .deepSleepThresholdReached: return "15min deep-sleep timer fired"
        case .wakingProbeTimedOut: return "60s waking-probe timer fired"
        }
    }

    private func apply(_ action: TrackerAction) {
        switch action {
        case .armSignificantChanges:
            locationManager.startMonitoringSignificantLocationChanges()
        case .disarmSignificantChanges:
            locationManager.stopMonitoringSignificantLocationChanges()
        case .armVisits:
            locationManager.startMonitoringVisits()
        case .disarmVisits:
            locationManager.stopMonitoringVisits()
        case .armMotion:
            startMotionUpdates()
        case .disarmMotion:
            stopMotionUpdates()
        case .armFullGPS(let accuracy):
            locationManager.desiredAccuracy = clAccuracy(for: accuracy)
            locationManager.distanceFilter = kCLDistanceFilterNone
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
        case .disarmFullGPS:
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
        case .startDeepSleepThresholdTimer:
            startDeepSleepTimer()
        case .cancelDeepSleepThresholdTimer:
            cancelDeepSleepTimer()
        case .cancelSleepThresholdTimer:
            cancelSleepThresholdTimer()
        case .openTrip:
            beginTrip()
        case .closeTrip:
            finaliseTrip()
        }
    }

    private func clAccuracy(for accuracy: TrackerAccuracy) -> CLLocationAccuracy {
        switch accuracy {
        case .best: kCLLocationAccuracyBest
        case .probe: kCLLocationAccuracyHundredMeters
        }
    }

    // MARK: - Trip persistence (Phase 6)

    private func beginTrip() {
        guard openTrip == nil else { return } // already open — idempotent
        let now = Date()
        let tzOffset = TimeZone.current.secondsFromGMT(for: now) / 60
        let trip = OpenTrip(
            id: UUID(),
            startedAt: now,
            tzOffsetMinutes: tzOffset,
            nextSeq: 0,
            lastFixTime: now,
            pendingPoints: [],
            startCoord: nil,
            endCoord: nil,
            distanceMeters: 0,
            motionAggregator: MotionAggregator()
        )
        openTrip = trip
        livePathCoordinates = []

        guard let writer = tripWriter else {
            recordLog(.user, "openTrip (no persistence bound — skipping DB)", detail: trip.id.uuidString)
            return
        }
        Self.log.notice("openTrip id=\(trip.id.uuidString, privacy: .public)")
        recordLog(.user, "trip opened", detail: "id=\(trip.id.uuidString.prefix(8))…")
        let id = trip.id
        let start = trip.startedAt
        let tz = trip.tzOffsetMinutes
        enqueuePersist(stage: "openTrip") {
            try writer.openTrip(eventID: id, start: start, tzOffsetMinutes: tz)
        }
    }

    /// Appends a fresh location fix to the in-memory buffer. Flushes to disk
    /// when the buffer crosses the threshold.
    private func appendFix(_ location: CLLocation) {
        guard var trip = openTrip else { return }
        let elapsedSeconds = location.timestamp.timeIntervalSince(trip.startedAt)
        let offsetMinutes = max(0, Int(elapsedSeconds / 60))
        let coord = Coordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        let point = PathPoint(coordinate: coord, offsetMinutes: offsetMinutes)
        trip.pendingPoints.append(point)
        trip.lastFixTime = location.timestamp
        if let previous = trip.endCoord {
            trip.distanceMeters += PolylineDirection.haversineMeters(previous, coord)
        }
        if trip.startCoord == nil { trip.startCoord = coord }
        trip.endCoord = coord
        openTrip = trip
        livePathCoordinates.append(coord)
        if trip.pendingPoints.count >= flushPointsThreshold {
            flushPendingPoints()
        }
    }

    /// Flushes any buffered points to disk immediately. Called when the app
    /// comes to the foreground so the day view includes the freshest fixes.
    func flushNow() {
        flushPendingPoints()
    }

    /// Routes a motion sample to the open trip's aggregator. No-op when no
    /// trip is open (samples between trips are uninteresting for activity
    /// classification — the trip end-points already capture the macro view).
    private func recordMotionSampleForActiveTrip(_ sample: MotionSample) {
        guard var trip = openTrip else { return }
        trip.motionAggregator.record(sample)
        openTrip = trip
    }

    /// Persists any buffered points to disk. Idempotent; safe to call when the
    /// buffer is empty.
    private func flushPendingPoints() {
        guard var trip = openTrip, !trip.pendingPoints.isEmpty else { return }
        guard let writer = tripWriter else { return }
        let pointsToWrite = trip.pendingPoints
        let startingSeq = trip.nextSeq
        trip.nextSeq += pointsToWrite.count
        trip.pendingPoints = []
        let id = trip.id
        let lastFix = trip.lastFixTime
        let tz = trip.tzOffsetMinutes
        openTrip = trip
        recordLog(
            .fix,
            "flushed \(pointsToWrite.count) point\(pointsToWrite.count == 1 ? "" : "s")",
            detail: "seq \(startingSeq)…\(startingSeq + pointsToWrite.count - 1)"
        )
        persistChain = Task.detached(priority: .userInitiated) { [prev = persistChain] in
            await prev.value
            do {
                try writer.appendPoints(
                    eventID: id,
                    startingSequence: startingSeq,
                    points: pointsToWrite
                )
                // Update end_ts so a crash mid-trip preserves a realistic duration.
                try writer.updateEnd(eventID: id, end: lastFix, tzOffsetMinutes: tz)
            } catch {
                // The write failed — re-queue the batch into the still-open trip's
                // buffer and roll nextSeq back so a later flush retries it instead
                // of dropping the points permanently.
                await self.requeueFailedFlush(tripID: id, points: pointsToWrite, error: error)
            }
        }
    }

    /// Restores a failed flush back into the open trip's buffer (prepended, so
    /// sequence order is preserved) and rolls `nextSeq` back. No-op if the trip
    /// already closed or a new trip opened in the meantime — those points are
    /// orphaned regardless and re-inserting them would corrupt the new trip.
    private func requeueFailedFlush(tripID: UUID, points: [PathPoint], error: Error) async {
        if var trip = openTrip, trip.id == tripID {
            trip.pendingPoints.insert(contentsOf: points, at: 0)
            trip.nextSeq -= points.count
            openTrip = trip
            recordLog(.error, "flush failed — re-queued \(points.count) point\(points.count == 1 ? "" : "s")", detail: error.localizedDescription)
        }
        await logPersistError("appendPoints", error)
    }

    private func finaliseTrip() {
        guard let trip = openTrip else { return }
        flushPendingPoints()
        // Read AFTER flush since flushPendingPoints bumps nextSeq via the
        // mutated copy — re-read from openTrip for the canonical value.
        let finalTrip = openTrip ?? trip
        openTrip = nil
        livePathCoordinates = []

        guard let writer = tripWriter else {
            recordLog(.user, "closeTrip (no persistence bound)", detail: finalTrip.id.uuidString)
            return
        }
        Self.log.notice("closeTrip id=\(finalTrip.id.uuidString, privacy: .public) seq=\(finalTrip.nextSeq, privacy: .public)")

        let dominant = finalTrip.motionAggregator.dominantMode()
        recordLog(
            .user,
            "trip closed",
            detail: "id=\(finalTrip.id.uuidString.prefix(8))… points=\(finalTrip.nextSeq) mode=\(dominant.mode) p=\(String(format: "%.2f", dominant.probability)) dist=\(Int(finalTrip.distanceMeters))m"
        )

        let pathID = finalTrip.id
        let activityID = UUID() // separate id from the path — events PK is `id`
        let start = finalTrip.startedAt
        let end = finalTrip.lastFixTime
        let tz = finalTrip.tzOffsetMinutes
        let startCoord = finalTrip.startCoord ?? Coordinate(latitude: 0, longitude: 0)
        let endCoord = finalTrip.endCoord ?? startCoord
        let distance = finalTrip.distanceMeters
        let mode = dominant.mode
        let probability = dominant.probability
        let refresh = onTripFinalised
        let hasFixes = finalTrip.startCoord != nil

        persistChain = Task.detached(priority: .userInitiated) { [prev = persistChain] in
            await prev.value
            do {
                try writer.updateEnd(eventID: pathID, end: end, tzOffsetMinutes: tz)
                // Only write the activity sibling if we actually captured fixes.
                // A trip that closed before any fix landed (rare, but possible
                // if motion goes stationary fast) has no useful endpoints.
                if hasFixes {
                    try writer.writeActivity(
                        eventID: activityID,
                        start: start,
                        end: end,
                        tzOffsetMinutes: tz,
                        startCoord: startCoord,
                        endCoord: endCoord,
                        distanceMeters: distance,
                        mode: mode,
                        probability: probability
                    )
                }
            } catch {
                await self.logPersistError("finaliseTrip", error)
            }
            await refresh?()
        }
    }

    // MARK: - Visit persistence (Phase 8)

    private func persistVisitArrival(coordinate: Coordinate, arrival: Date) {
        // If we already have an open visit (shouldn't normally happen — you
        // can't arrive at two places at once — but iOS occasionally re-fires),
        // close it first with the new arrival as a best-guess departure so we
        // don't leak open rows.
        if let stale = openVisit {
            persistVisitDeparture(coordinate: stale.coordinate, arrival: stale.arrival, departure: arrival)
        }

        let tzOffset = TimeZone.current.secondsFromGMT(for: arrival) / 60

        guard let writer = tripWriter else {
            // Remember it in memory (persisted=false) — the departure handler
            // inserts the full row once the writer is bound.
            openVisit = OpenVisit(
                eventID: UUID(),
                placeID: "live-\(UUID().uuidString)",
                arrival: arrival,
                coordinate: coordinate,
                persisted: false
            )
            recordLog(.user, "visit arrival (no persistence bound)")
            return
        }

        // iOS re-delivers the same visit across app relaunches with an
        // identical arrivalDate. If a row for this arrival already exists,
        // adopt it instead of inserting a duplicate.
        if let existing = try? writer.findLiveVisit(arrival: arrival, near: coordinate) {
            openVisit = OpenVisit(
                eventID: existing.eventID,
                placeID: existing.placeID,
                arrival: arrival,
                coordinate: coordinate,
                persisted: true
            )
            recordLog(.user, "visit re-delivered — adopted existing row", detail: "place=\(existing.placeID.prefix(13))…")
            return
        }

        let placeID = "live-\(UUID().uuidString)"
        let eventID = UUID()
        openVisit = OpenVisit(eventID: eventID, placeID: placeID, arrival: arrival, coordinate: coordinate, persisted: true)
        recordLog(.user, "visit opened", detail: "place=\(placeID.prefix(13))…")

        enqueuePersist(stage: "openVisit") {
            try writer.openVisit(
                eventID: eventID,
                placeID: placeID,
                coordinate: coordinate,
                start: arrival,
                end: arrival, // placeholder — closeVisit updates this
                tzOffsetMinutes: tzOffset
            )
        }
    }

    private func persistVisitDeparture(coordinate: Coordinate, arrival: Date, departure: Date) {
        guard let writer = tripWriter else {
            recordLog(.user, "visit departure (no persistence bound)")
            openVisit = nil
            return
        }

        if let open = openVisit, open.persisted {
            // Standard path: close the visit we opened on arrival.
            let id = open.eventID
            let placeID = open.placeID
            let tzOffset = TimeZone.current.secondsFromGMT(for: departure) / 60
            openVisit = nil
            recordLog(
                .user,
                "visit closed",
                detail: "place=\(placeID.prefix(13))… dur=\(Int(departure.timeIntervalSince(arrival)))s"
            )
            persistChain = Task.detached(priority: .userInitiated) { [prev = persistChain] in
                await prev.value
                do {
                    try writer.closeVisit(eventID: id, end: departure, tzOffsetMinutes: tzOffset)
                } catch {
                    await self.logPersistError("closeVisit", error)
                }
                await self.askForRefresh()
            }
        } else {
            // Either the arrival predates the DB binding (persisted=false), or
            // the app restarted between arrival and departure. The row for
            // this arrival may already exist from a previous process — close
            // it if so, otherwise write a fresh visit with the full window.
            let unpersisted = openVisit // non-nil only in the persisted=false case
            openVisit = nil
            if let existing = try? writer.findLiveVisit(arrival: arrival, near: coordinate) {
                let tzOffset = TimeZone.current.secondsFromGMT(for: departure) / 60
                recordLog(
                    .user,
                    "visit closed (recovered existing row)",
                    detail: "place=\(existing.placeID.prefix(13))… dur=\(Int(departure.timeIntervalSince(arrival)))s"
                )
                persistChain = Task.detached(priority: .userInitiated) { [prev = persistChain] in
                    await prev.value
                    do {
                        try writer.closeVisit(eventID: existing.eventID, end: departure, tzOffsetMinutes: tzOffset)
                    } catch {
                        await self.logPersistError("closeVisit (recovery)", error)
                    }
                    await self.askForRefresh()
                }
                return
            }
            let placeID = unpersisted?.placeID ?? "live-\(UUID().uuidString)"
            let eventID = unpersisted?.eventID ?? UUID()
            let tzOffset = TimeZone.current.secondsFromGMT(for: arrival) / 60
            recordLog(
                .user,
                "visit (recovered, no open arrival)",
                detail: "place=\(placeID.prefix(13))… dur=\(Int(departure.timeIntervalSince(arrival)))s"
            )
            persistChain = Task.detached(priority: .userInitiated) { [prev = persistChain] in
                await prev.value
                do {
                    try writer.openVisit(
                        eventID: eventID,
                        placeID: placeID,
                        coordinate: coordinate,
                        start: arrival,
                        end: departure,
                        tzOffsetMinutes: tzOffset
                    )
                } catch {
                    await self.logPersistError("openVisit (recovery)", error)
                }
                await self.askForRefresh()
            }
        }
    }

    private func askForRefresh() async {
        await onTripFinalised?()
    }

    private func logPersistError(_ stage: String, _ error: Error) async {
        await MainActor.run {
            Self.log.error("\(stage, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.recordLog(.error, "persist \(stage) failed", detail: error.localizedDescription)
        }
    }

    // MARK: - Motion updates (CMMotionActivityManager)

    private func startMotionUpdates() {
        guard !motionUpdatesActive else { return }
        guard CMMotionActivityManager.isActivityAvailable() else {
            Self.log.warning("CMMotionActivity unavailable on this device")
            return
        }
        // Surface denied/restricted Motion & Fitness so the degraded mode (no
        // motion classification — the .waking probe timeout becomes the only exit)
        // is visible in the live-tracking log.
        let motionAuth = CMMotionActivityManager.authorizationStatus()
        if motionAuth == .denied || motionAuth == .restricted {
            Self.log.warning("Motion & Fitness permission \(motionAuth == .denied ? "denied" : "restricted", privacy: .public) — no activity classification")
            recordLog(.auth, "Motion & Fitness \(motionAuth == .denied ? "denied" : "restricted")", detail: "tracker relies on GPS speed + waking-probe timeout only")
        }
        motionUpdatesActive = true
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            Task { @MainActor in
                self.handleMotionActivity(activity)
            }
        }
    }

    private func stopMotionUpdates() {
        guard motionUpdatesActive else { return }
        motionUpdatesActive = false
        motionManager.stopActivityUpdates()
    }

    private func handleMotionActivity(_ activity: CMMotionActivity) {
        // Ignore "unknown" (no bits set) to avoid flapping. Treat any motion bit
        // as "moving"; explicit stationary as "stationary".
        let category = motionCategory(for: activity)
        // Only log when the dominant category changes — CMMotion fires multiple
        // updates a second; logging each would drown out useful entries.
        if let category, category != lastLoggedMotionCategory {
            recordLog(.motion, category, detail: "confidence: \(motionConfidence(activity))")
            lastLoggedMotionCategory = category
        }
        // Feed the active trip's aggregator (no-op when no trip is open).
        recordMotionSampleForActiveTrip(motionSample(from: activity))

        // Check the moving bits BEFORE stationary: CMMotionActivity flags aren't
        // mutually exclusive, and Apple delivers automotive+stationary during
        // stop-and-go traffic. Treating that as stationary would start the sleep
        // timer and split one drive into multiple trips. Any motion bit wins.
        if activity.walking || activity.running || activity.automotive || activity.cycling {
            cancelSleepThresholdTimer()
            consume(.motionMoving)
        } else if activity.stationary {
            if state == .tracking, sleepThresholdTimer == nil {
                startSleepThresholdTimer()
            }
            consume(.motionStationary)
        }
    }

    private func motionSample(from activity: CMMotionActivity) -> MotionSample {
        let confidence: MotionSample.Confidence = switch activity.confidence {
        case .high: .high
        case .medium: .medium
        case .low: .low
        @unknown default: .low
        }
        return MotionSample(
            walking: activity.walking,
            running: activity.running,
            cycling: activity.cycling,
            automotive: activity.automotive,
            stationary: activity.stationary,
            confidence: confidence
        )
    }

    private func motionCategory(for activity: CMMotionActivity) -> String? {
        var parts: [String] = []
        if activity.walking { parts.append("walking") }
        if activity.running { parts.append("running") }
        if activity.cycling { parts.append("cycling") }
        if activity.automotive { parts.append("automotive") }
        if activity.stationary { parts.append("stationary") }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }

    private func motionConfidence(_ activity: CMMotionActivity) -> String {
        switch activity.confidence {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        @unknown default: "?"
        }
    }

    // MARK: - Timers

    private func startSleepThresholdTimer() {
        cancelSleepThresholdTimer()
        Self.log.notice("started 180s sleep-threshold timer")
        recordLog(.timer, "180s sleep timer started", detail: "fires if motion stays stationary")
        sleepThresholdTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.sleepThresholdTimer = nil
                self?.consume(.sleepThresholdReached)
            }
        }
    }

    private func cancelSleepThresholdTimer() {
        if sleepThresholdTimer != nil {
            Self.log.debug("cancelled sleep-threshold timer")
            recordLog(.timer, "180s sleep timer cancelled", detail: "motion resumed before fire")
        }
        sleepThresholdTimer?.invalidate()
        sleepThresholdTimer = nil
    }

    private func startWakingProbeTimer() {
        cancelWakingProbeTimer()
        recordLog(.timer, "60s waking-probe timer started", detail: "falls back to stationary if no movement confirmed")
        wakingProbeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.wakingProbeTimer = nil
                self?.consume(.wakingProbeTimedOut)
            }
        }
    }

    private func cancelWakingProbeTimer() {
        wakingProbeTimer?.invalidate()
        wakingProbeTimer = nil
    }

    private func startDeepSleepTimer() {
        cancelDeepSleepTimer()
        Self.log.notice("started 15min deep-sleep timer")
        recordLog(.timer, "15min deep-sleep timer started")
        deepSleepDeadline = Date().addingTimeInterval(15 * 60)
        deepSleepThresholdTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.deepSleepThresholdTimer = nil
                self?.deepSleepDeadline = nil
                self?.consume(.deepSleepThresholdReached)
            }
        }
    }

    private func cancelDeepSleepTimer() {
        if deepSleepThresholdTimer != nil {
            recordLog(.timer, "15min deep-sleep timer cancelled")
        }
        deepSleepThresholdTimer?.invalidate()
        deepSleepThresholdTimer = nil
        deepSleepDeadline = nil
    }

    /// Checks the wall-clock deep-sleep deadline on a wake event. If the deadline
    /// passed while the process was suspended (the Timer couldn't fire), cut
    /// straight to .deepSleep and report that we handled the wake. Returns true
    /// when it consumed the wake so the caller skips its normal handling.
    private func handleDeepSleepDeadlineIfExpired() -> Bool {
        guard state == .stationary, let deadline = deepSleepDeadline, Date() >= deadline else {
            return false
        }
        recordLog(.timer, "deep-sleep deadline elapsed while suspended", detail: "cutting to deepSleep")
        deepSleepThresholdTimer?.invalidate()
        deepSleepThresholdTimer = nil
        deepSleepDeadline = nil
        consume(.deepSleepThresholdReached)
        return true
    }
}

private func authString(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "notDetermined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorizedAlways: "authorizedAlways"
    case .authorizedWhenInUse: "authorizedWhenInUse"
    @unknown default: "unknown"
    }
}

private func formatTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}

extension LocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        let newAccuracy = manager.accuracyAuthorization
        Task { @MainActor in
            self.authorizationStatus = newStatus
            self.accuracyAuthorization = newAccuracy
            self.recordLog(.auth, "auth status: \(authString(newStatus))")
            if newAccuracy == .reducedAccuracy {
                self.recordLog(.auth, "Precise Location is off", detail: "fixes arrive at 1–5 km — trips won't record")
            }
            // Auto-escalate to Always only when WE kicked off the escalation via
            // requestAlwaysAuthorization() — never for a When-In-Use grant from the
            // map's locate-me flow or at cold launch (that would silently burn the
            // one-shot iOS "Change to Always?" prompt out of context).
            if newStatus == .authorizedWhenInUse, self.pendingAlwaysEscalation {
                self.pendingAlwaysEscalation = false
                manager.requestAlwaysAuthorization()
            } else if newStatus != .authorizedWhenInUse {
                // Settled (Always/denied/restricted) — the escalation is resolved.
                self.pendingAlwaysEscalation = false
            }
            self.consume(.authorizationChanged(authorizedAlways: newStatus == .authorizedAlways))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [self] in
            guard let last = locations.last else { return }
            Self.log.notice("didUpdateLocations count=\(locations.count) state=\(self.state.rawValue, privacy: .public) coord=\(last.coordinate.latitude, privacy: .private),\(last.coordinate.longitude, privacy: .private) acc=\(last.horizontalAccuracy, privacy: .private)")
            // iOS delivers both SLC and active-mode updates through the same
            // callback. Distinguish by current state: in .deepSleep we know this
            // is an SLC fire; in .waking/.tracking it's an active-mode fix that
            // Phase 6 will buffer into the trip.
            let coordString = String(format: "%.5f, %.5f", last.coordinate.latitude, last.coordinate.longitude)
            let accString = String(format: "±%.0fm", last.horizontalAccuracy)
            self.recordLog(
                .fix,
                "\(coordString)  \(accString)",
                detail: "count=\(locations.count) state=\(self.state.rawValue)"
            )
            if handleDeepSleepDeadlineIfExpired() {
                // The 15-min stationary window already elapsed while suspended —
                // we cut to .deepSleep. Re-feed the SLC so it wakes us from there.
                consume(.significantLocationChange)
            } else if state == .deepSleep || state == .stationary {
                // Both states monitor SLC; an SLC fire while stationary means the
                // user has started moving again — wake and re-arm probe GPS so we
                // don't miss the trip after a stop. (.stationary, .significantLocationChange)
                // → .waking is already defined in the state machine.
                consume(.significantLocationChange)
            } else if state == .waking {
                // Motion can lag by several seconds (or be denied entirely).
                // A probe fix with a credible speed reading is movement
                // evidence on its own — commit to tracking.
                if last.speed >= 1.0, last.horizontalAccuracy > 0 {
                    consume(.motionMoving)
                }
            } else if state == .tracking {
                // Active recording — append every delivered fix to the open trip
                // buffer (iOS batches multiple fixes via deferred delivery and
                // background wakes; CL delivers them oldest-first). High-accuracy
                // fixes only; reject the wild ±100m+ samples a GPS can spit out
                // during cold-start.
                for location in locations where location.horizontalAccuracy > 0 && location.horizontalAccuracy <= 65 {
                    self.appendFix(location)
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let departure = visit.departureDate
        let isDeparture = departure != Date.distantFuture
        // iOS reports arrivalDate == .distantPast for the first departure after
        // monitoring starts (the user was already at the place). Writing it raw
        // anchors the visit in year 1 — clamp it to the departure so the row gets
        // a sane (zero-duration) start. Do this before any persistence/lookup/log.
        let rawArrival = visit.arrivalDate
        let arrival = (rawArrival == .distantPast && isDeparture) ? departure : rawArrival
        let lat = visit.coordinate.latitude
        let lon = visit.coordinate.longitude
        Task { @MainActor in
            Self.log.notice("didVisit \(isDeparture ? "depart" : "arrive", privacy: .public) at \(lat, privacy: .private),\(lon, privacy: .private)")
            let coordString = String(format: "%.5f, %.5f", lat, lon)
            let dateString: String
            if isDeparture {
                dateString = "departed \(formatTime(departure))"
            } else {
                dateString = "arrived \(formatTime(arrival))"
            }
            self.recordLog(
                .visit,
                isDeparture ? "visit depart" : "visit arrive",
                detail: "\(coordString) — \(dateString)"
            )

            // Phase 8: persist visit lifecycle.
            // - Arrival callback (departure == distantFuture): open a new visit
            //   event with end == start as placeholder, remember its id.
            // - Departure callback: if we have a remembered open visit, update
            //   its end_ts. If not (app restart between arrival and departure),
            //   write a fresh visit with both timestamps.
            let coord = Coordinate(latitude: lat, longitude: lon)
            if isDeparture {
                self.persistVisitDeparture(coordinate: coord, arrival: arrival, departure: departure)
            } else {
                self.persistVisitArrival(coordinate: coord, arrival: arrival)
            }

            // A departure is a wake event — if the deep-sleep window already
            // elapsed while suspended, cut to .deepSleep first so the departure
            // wakes us cleanly from there.
            if isDeparture { _ = self.handleDeepSleepDeadlineIfExpired() }
            self.consume(isDeparture ? .visitDeparted : .visitArrived)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            Self.log.error("CLLocationManager error: \(error.localizedDescription, privacy: .public)")
            self.recordLog(.error, "CL error", detail: error.localizedDescription)
        }
    }
}

/// On-disk backing for the tracker's diagnostic log. Append-only JSONL, kept under
/// Application Support next to the database with the SAME file protection
/// (`.completeUntilFirstUserAuthentication`, so background writes work after the first
/// post-boot unlock) and excluded from backup. The lines carry the same precise
/// coordinates the encrypted DB already stores, so this is not a new data exposure —
/// it never leaves the device and is wiped by the log sheet's Clear button.
///
/// Confined to `LocationTracker`'s main actor; all I/O is small and synchronous.
private final class TrackerLogStore {
    /// One persisted line. Compact keys keep the file small at ~1 fix/sec.
    private struct Line: Codable {
        let t: Double          // epoch seconds
        let c: String          // category rawValue
        let m: String          // message
        let d: String?         // detail
    }

    private let fileURL: URL?
    private var handle: FileHandle?
    private var appendsSinceCompaction = 0
    /// Rewrite the file from its tail this often, bounding growth to ~cap + this.
    private let compactionInterval = 256

    init() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fileURL = nil
            return
        }
        let dir = support.appendingPathComponent("RememberMe", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tracker-log.jsonl")
        fileURL = url
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            excludeFromBackup(url)
        } else {
            // Migrate protection on existing files (and re-assert backup exclusion).
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            excludeFromBackup(url)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    /// Loads up to `limit` most-recent entries, newest first (matching the in-memory buffer).
    func loadNewestFirst(limit: Int) -> [LocationTracker.TrackerLogEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        let lines = data.split(separator: 0x0A)   // '\n'
        let parsed: [LocationTracker.TrackerLogEntry] = lines.suffix(limit).compactMap { slice in
            guard let line = try? decoder.decode(Line.self, from: Data(slice)),
                  let category = LocationTracker.TrackerLogEntry.Category(rawValue: line.c)
            else { return nil }
            return LocationTracker.TrackerLogEntry(
                timestamp: Date(timeIntervalSince1970: line.t),
                category: category,
                message: line.m,
                detail: line.d
            )
        }
        return parsed.reversed()   // file is chronological; buffer is newest-first
    }

    /// Appends one entry, compacting the file to `cap` lines periodically.
    func append(_ entry: LocationTracker.TrackerLogEntry, compactingTo cap: Int) {
        guard let handle else { return }
        let line = Line(
            t: entry.timestamp.timeIntervalSince1970,
            c: entry.category.rawValue,
            m: entry.message,
            d: entry.detail
        )
        guard var encoded = try? JSONEncoder().encode(line) else { return }
        encoded.append(0x0A)
        try? handle.write(contentsOf: encoded)

        appendsSinceCompaction += 1
        if appendsSinceCompaction >= compactionInterval {
            appendsSinceCompaction = 0
            compact(to: cap)
        }
    }

    /// Truncates the file to its last `cap` lines (atomic rewrite).
    private func compact(to cap: Int) {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > cap else { return }
        var tail = Data()
        for slice in lines.suffix(cap) {
            tail.append(contentsOf: slice)
            tail.append(0x0A)
        }
        _ = try? handle?.close()
        try? tail.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        handle = try? FileHandle(forWritingTo: fileURL)
        try? handle?.seekToEnd()
    }

    func clear() {
        guard let fileURL else { return }
        _ = try? handle?.close()
        try? Data().write(to: fileURL, options: .atomic)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
