import Core
import Foundation
import Observation
import OSLog
import Persistence

/// State + actions for the live app. Created once at launch, injected via the SwiftUI `.environment(_:)`.
///
/// Ownership:
/// - `keyStore`: persists the DB key in the Keychain
/// - `database`: opened lazily on first call to `ensureOpen()`; lives until app termination
/// - `counts`, `importStatus`: observed by the SwiftUI tree
@MainActor
@Observable
final class AppEnvironment {
    enum ImportStatus: Equatable, Sendable {
        case idle
        case running(stage: String)
        /// `skipped` = malformed/undecodable records; `skippedOlder` = records dropped by
        /// the free tier's 14-day import window (0 when Premium / no cutoff).
        case completed(Persistence.EventCounts, skipped: Int, skippedOlder: Int)
        case failed(message: String)
    }

    private let keyStore: any KeyStore
    private let databasePath: String
    private var database: SQLCipherDatabase?
    private(set) var geocoder: GeocodingService?
    let pathRefinement: PathRefinementController = PathRefinementController()

    /// App-lifetime live background tracker. Created eagerly so SLC / visit
    /// callbacks delivered to the app on background-relaunch land on a live
    /// instance. See `LocationTracker` for the state machine bridge.
    let tracker: LocationTracker = LocationTracker()

    var counts: Persistence.EventCounts = .empty
    var insights: InsightsSummary = .empty
    var selectedPlace: VisitMarker?
    var importStatus: ImportStatus = .idle

    // MARK: - Day filter (round 5)

    /// Currently selected calendar day (anchor) in the user's local timezone, at midnight.
    /// Combined with `selectedRange` this drives the visible date range on the map + timeline.
    var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// How wide a date range the user is viewing.
    enum DateRangeKind: String, Equatable, Sendable, CaseIterable, Identifiable {
        case day, week, month
        var id: String { rawValue }

        var label: String {
            switch self {
            case .day: "Day"
            case .week: "Week"
            case .month: "Month"
            }
        }
    }

    var selectedRange: DateRangeKind = .day

    /// Days that have at least one event. Used by the calendar UI to mark them with a dot
    /// and to pick a sensible default day when "today" is empty.
    var daysWithData: [Date] = []

    var dayMarkers: [VisitMarker] = []
    var dayTrips: [TripSummary] = []
    var dayPathTraces: [PathTrace] = []
    /// Per-activity refined polylines for the current day. Populated by `loadDay` from
    /// `path_points` rows keyed under activity ids — these only exist after a refinement
    /// (single-leg via `applyRefinement`, or each leg of a multi-leg split). Empty for
    /// activities that have not been refined; those fall back to time-sliced GPS samples.
    var dayRefinedPolylines: [UUID: [Coordinate]] = [:]
    /// Set of activity event ids for the current day that have been refined (single-trip
    /// audit row, or derived sub-activity from a multi-leg / journey refinement). Drives
    /// the small green check shown on the timeline mode icon so the user can scan a day
    /// at a glance and see which rows have been touched.
    var dayRefinedActivityIDs: Set<UUID> = []
    /// Precomputed multi-leg journeys for the current day, keyed by every activity id
    /// that participates as a leg. Lets the timeline context-menu look up the journey
    /// instantly instead of running the detector inside the SwiftUI closure (which
    /// caused lag and intermittent "missing menu item" bugs).
    var dayJourneysByAnchor: [UUID: Journey] = [:]
    var dayTimeline: [TimelineEntry] = []
    var daySummary: DaySummary = .empty

    /// Polylines to draw for the current day, computed once in `loadDay` from
    /// `dayPathTraces` / `dayTrips` / `dayRefinedPolylines`. MapScreen reads these directly
    /// instead of recomputing the O(activities × paths × samples) plan inside its `body`
    /// (which re-ran on every camera gesture).
    var dayTripRenders: [TripRenderPlan.PolylineRender] = []
    /// Sparse direction-of-travel markers along `dayTripRenders`, computed alongside it.
    var dayDirectionMarkers: [DirectionMarker] = []

    /// Photos taken on the selected day (only populated when the user enabled the toggle and
    /// granted Photos library access). Empty otherwise.
    var dayPhotos: [GeoPhoto] = []
    let photoLibrary = PhotoLibraryService()

    /// Ids of timeline entries that have a nearby photo. Precomputed when `dayTimeline` or
    /// `dayPhotos` change so the eager timeline VStack does an O(1) `Set` lookup per row
    /// instead of re-running the O(photos) `hasNearbyPhoto` scan on every render (M26).
    private(set) var entryIDsWithNearbyPhotos: Set<TimelineEntry.ID> = []

    private func recomputeEntryIDsWithNearbyPhotos() {
        guard !dayPhotos.isEmpty else {
            entryIDsWithNearbyPhotos = []
            return
        }
        entryIDsWithNearbyPhotos = Set(dayTimeline.filter { hasNearbyPhoto(for: $0) }.map(\.id))
    }

    // MARK: - Navigation (round 6)

    /// One frame of the navigation history. Capturing what the drawer should restore on "Back".
    struct NavigationSnapshot: Equatable, Sendable {
        let day: Date
        let drawerTab: DrawerTab
        let focusedItem: MapFocusItem?
        init(day: Date, drawerTab: DrawerTab, focusedItem: MapFocusItem?) {
            self.day = day
            self.drawerTab = drawerTab
            self.focusedItem = focusedItem
        }
    }

    enum DrawerTab: String, Equatable, Sendable, CaseIterable {
        case timeline
        case photos
        case insights
    }

    /// What the map should currently focus on. Set when the user taps a timeline row;
    /// cleared on day change or back-navigation.
    enum MapFocusItem: Equatable, Sendable {
        case visit(placeID: String, coordinate: Coordinate)
        case trip(id: UUID)
        case path(id: UUID)
        case photo(id: String, coordinate: Coordinate)
    }

    var drawerTab: DrawerTab = .timeline
    var focusedItem: MapFocusItem?
    private(set) var navigationStack: [NavigationSnapshot] = []

    /// Coarse drawer state — small (peek), medium, large.
    enum DrawerSize: String, Equatable, Sendable, CaseIterable {
        case small, medium, large

        /// Approximate drawer height in points for a given screen height.
        /// `small` is the fixed peek detent we use in RootView (`.height(180)`).
        func heightInPoints(screenHeight: CGFloat) -> CGFloat {
            switch self {
            case .small: 180
            case .medium: screenHeight * 0.5
            case .large: screenHeight * 0.92
            }
        }
    }

    var drawerSize: DrawerSize = .small

    /// Session-only filter applied to the timeline list (does not affect the map).
    enum TimelineFilter: String, Equatable, Sendable, CaseIterable, Identifiable {
        case all, trips, visits, walking, vehicle, transit
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All"
            case .trips: "Trips"
            case .visits: "Visits"
            case .walking: "Walking"
            case .vehicle: "Driving"
            case .transit: "Transit"
            }
        }

        /// True if the given `TimelineEntry` passes this filter.
        func matches(_ entry: TimelineEntry) -> Bool {
            switch self {
            case .all:
                true
            case .trips:
                entry.kind == "activity"
            case .visits:
                entry.kind == "visit"
            case .walking:
                isActivityMatchingMode(entry, contains: ["walk", "running"])
            case .vehicle:
                isActivityMatchingMode(entry, contains: ["vehicle", "car", "motorcycl"])
            case .transit:
                isActivityMatchingMode(entry, contains: ["subway", "train", "bus", "transit"])
            }
        }

        private func isActivityMatchingMode(_ entry: TimelineEntry, contains needles: [String]) -> Bool {
            guard case let .activity(_, mode) = entry.detail else { return false }
            let normalized = mode.lowercased()
            return needles.contains { normalized.contains($0) }
        }
    }

    var timelineFilter: TimelineFilter = .all

    /// `dayTimeline` filtered by `timelineFilter`. Computed so callers can subscribe to changes
    /// in either the source list or the filter without manual refresh code.
    var filteredDayTimeline: [TimelineEntry] {
        guard timelineFilter != .all else { return dayTimeline }
        return dayTimeline.filter(timelineFilter.matches)
    }

    /// Visible events in the day timeline list. Path rows are hidden because the map already
    /// draws them as the trip line.
    var visibleDayEvents: [TimelineEntry] {
        filteredDayTimeline.filter { $0.kind != "path" }
    }

    /// `dayMarkers` collapsed so repeated visits to the same named place within a short
    /// window only show one dot on the map. Trips, paths, and timeline rows are unaffected —
    /// only the visible point markers.
    var dedupedDayMarkers: [VisitMarker] {
        dedupMarkersByLabel(dayMarkers, within: 600) // 10 min
    }

    /// Group markers by their display label (user-chosen wins, else resolved). For each group,
    /// keep the earliest marker plus any later one that's more than `within` seconds after the
    /// last kept one. Markers without a label pass through unchanged.
    private func dedupMarkersByLabel(_ markers: [VisitMarker], within: TimeInterval) -> [VisitMarker] {
        let sorted = markers.sorted { $0.mostRecentVisit < $1.mostRecentVisit }
        var output: [VisitMarker] = []
        var lastKeptByLabel: [String: VisitMarker] = [:]

        for marker in sorted {
            guard let label = marker.displayLabel, !label.isEmpty else {
                // No label → can't safely dedup; keep all.
                output.append(marker)
                continue
            }
            if let previous = lastKeptByLabel[label] {
                let gap = marker.mostRecentVisit.timeIntervalSince(previous.mostRecentVisit)
                if gap > within {
                    output.append(marker)
                    lastKeptByLabel[label] = marker
                }
                // Otherwise: skip — same-name visit happened within the window.
            } else {
                output.append(marker)
                lastKeptByLabel[label] = marker
            }
        }

        // Restore the descending-by-time order that the rest of the app expects.
        return output.sorted { $0.mostRecentVisit > $1.mostRecentVisit }
    }

    /// Returns true if `dayPhotos` contains at least one photo within `closeBySeconds` and
    /// `closeByMeters` of `entry`'s window. Used to flag a small photo indicator on event rows.
    func hasNearbyPhoto(for entry: TimelineEntry, closeBySeconds: TimeInterval = 1_800, closeByMeters: Double = 300) -> Bool {
        guard !dayPhotos.isEmpty else { return false }
        // For activities/visits, use the start coordinate where available.
        let referenceCoordinate: Coordinate?
        switch entry.detail {
        case let .activity(_, _):
            referenceCoordinate = nil // activities don't have a single point; just check time
        case let .visit(_, _, _, _, coordinate):
            referenceCoordinate = coordinate
        case .path:
            referenceCoordinate = nil
        }

        for photo in dayPhotos {
            let timeOverlapping = photo.creationDate >= entry.start.date.addingTimeInterval(-closeBySeconds)
                && photo.creationDate <= entry.end.date.addingTimeInterval(closeBySeconds)
            guard timeOverlapping else { continue }
            if let reference = referenceCoordinate {
                let distance = PolylineDirection.haversineMeters(reference, photo.coordinate)
                if distance <= closeByMeters { return true }
            } else {
                // Time-only check for activities (which span a path, not a point).
                return true
            }
        }
        return false
    }

    var canGoBack: Bool {
        !navigationStack.isEmpty
    }

    // MARK: - Init

    init(keyStore: any KeyStore, databasePath: String) {
        self.keyStore = keyStore
        self.databasePath = databasePath
        pathRefinement.bind(environment: self)
    }

    /// The production environment: real Keychain, real on-disk database under Application Support.
    static func live() -> AppEnvironment {
        AppEnvironment(
            keyStore: KeychainKeyStore(),
            databasePath: defaultDatabasePath()
        )
    }

    /// Preview / unit-test environment: in-memory key, in-memory database.
    static func preview() -> AppEnvironment {
        AppEnvironment(
            keyStore: InMemoryKeyStore(),
            databasePath: SQLCipherDatabase.inMemoryPath
        )
    }

    // MARK: - Database lifecycle

    /// Opens (or creates) the encrypted database and refreshes published state.
    /// Idempotent — safe to call multiple times.
    func ensureOpen() async {
        if database != nil { return }
        do {
            let opened = try DatabaseFactory.open(
                at: databasePath,
                keyStore: keyStore,
                excludeFromBackup: databasePath != SQLCipherDatabase.inMemoryPath
            )
            database = opened
            // Apply file protection now that the DB file is guaranteed to exist. Idempotent.
            // Done on every launch so existing users migrate from .complete to
            // .completeUntilFirstUserAuthentication when they update to this build.
            if databasePath != SQLCipherDatabase.inMemoryPath {
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: databasePath
                )
            }
            geocoder = GeocodingService(database: opened) { [weak self] in
                // Only the per-day timeline lookups need to repaint; map markers stay stable
                // so the SwiftUI Map doesn't tear down and reload its tiles on every resolution.
                await self?.refreshDayTimeline()
            }
            await refresh()

            // If there are places we haven't named yet, start the background trickle.
            // (No-op when everything is resolved.)
            if let database,
               let unresolved = try? Persistence.fetchUnresolvedPlaceIDs(in: database, limit: 1),
               !unresolved.isEmpty
            {
                geocoder?.start()
            }

            // Wire persistence into the live tracker now that the DB is open.
            // Without this, openTrip / closeTrip actions log but don't persist.
            let tripWriter = LiveTripWriter(database: opened)
            tracker.bindPersistence(
                writer: tripWriter,
                onTripFinalised: { [weak self] in
                    await self?.refresh()
                }
            )

            // Phase 9: recover orphaned live-tracker path events from a previous
            // run that crashed before their sibling activity could be written.
            // For each orphan, write a placeholder activity (mode=unknown) from
            // whatever path-point data survived so the trip is fully finalised
            // and doesn't keep surfacing on every launch.
            let recovered = await recoverOrphanedLiveTrips(writer: tripWriter)

            // One-time hygiene for rows written by earlier builds: Null Island
            // placeholder activities (the "Unknown 0m trip in the Atlantic")
            // and duplicate visits from re-delivered CLVisit callbacks.
            let removedNullIsland = (try? tripWriter.deleteNullIslandActivities()) ?? 0
            let removedDuplicates = (try? tripWriter.dedupeLiveVisits()) ?? 0
            if recovered + removedNullIsland + removedDuplicates > 0 {
                Logger(subsystem: "com.tibo.rememberme", category: "recovery")
                    .notice("cleanup: \(recovered) orphan(s) finalised, \(removedNullIsland) null-island activitie(s) and \(removedDuplicates) duplicate visit(s) removed")
                await refresh()
            }

            // Resume live tracking if the user had it enabled in a previous session.
            // Read UserDefaults directly so AppEnvironment stays independent of Settings.
            // The tracker's state machine collapses back to .off if auth was revoked.
            let trackingEnabled = UserDefaults.standard.bool(forKey: Settings.liveTrackingEnabledKey)
            if trackingEnabled {
                tracker.setEnabled(true)
            }
        } catch {
            importStatus = .failed(message: "Couldn't open database: \(error.localizedDescription)")
        }
    }

    /// Re-reads everything from the database — counts, markers, trips, timeline, day filter.
    /// Use after big writes (initial open, import). For granular updates after a single
    /// geocoded name lands, prefer `refreshDayTimeline()` so the SwiftUI `Map` doesn't
    /// reassign its markers array (which triggers a tile reload flash).
    func refresh() async {
        guard let database else { return }
        do {
            counts = try Persistence.eventCounts(in: database)
            insights = (try? Persistence.fetchInsights(in: database)) ?? .empty
            daysWithData = try Persistence.fetchDaysWithData(in: database)
            // If today has nothing AND there is data elsewhere, snap to the most recent day.
            if let mostRecent = daysWithData.first,
               !calendar.isDate(selectedDay, inSameDayAs: mostRecent),
               !daysWithData.contains(where: { calendar.isDate($0, inSameDayAs: selectedDay) })
            {
                selectedDay = mostRecent
            }
            await loadDay()
        } catch {
            importStatus = .failed(message: "Couldn't refresh: \(error.localizedDescription)")
        }
    }

    /// Refresh ONLY the day-filtered timeline list. Used by the geocoding background loop
    /// so newly-resolved place names appear in the visible timeline without provoking the
    /// `Map` view to re-render its annotations (which causes a brief map tile reload).
    func refreshDayTimeline() async {
        guard let database else { return }
        let fresh = (try? Persistence.fetchTimeline(in: database, dayRange: dayRange)) ?? dayTimeline
        // Skip the reassignment (and the dependent recompute + SwiftUI invalidation) when the
        // timeline hasn't actually changed — the geocoding trickle calls this every ~1.2 s.
        guard fresh != dayTimeline else { return }
        dayTimeline = fresh
        recomputeEntryIDsWithNearbyPhotos()
    }

    private static let loadDayLog = Logger(subsystem: "com.tibo.rememberme", category: "loadDay")

    /// Runs `fetch`, returning `fallback` on error — but, unlike a bare `try?`, logs the
    /// failure first so a blank day caused by a read error is diagnosable instead of looking
    /// identical to "no data" (L56).
    private func loggingFetch<T>(_ label: String, fallback: T, _ fetch: () throws -> T) -> T {
        do {
            return try fetch()
        } catch {
            Self.loadDayLog.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return fallback
        }
    }

    /// Re-fetches all per-day data (markers/trips/paths/timeline/summary) for the current
    /// `selectedDay`. Called on selection changes.
    func loadDay() async {
        guard let database else { return }
        let range = dayRange
        dayMarkers = loggingFetch("fetchVisitMarkers", fallback: []) { try Persistence.fetchVisitMarkers(in: database, dayRange: range) }
        let rawTrips = loggingFetch("fetchTrips", fallback: []) { try Persistence.fetchTrips(in: database, dayRange: range) }
        dayPathTraces = loggingFetch("fetchPathTraces", fallback: []) { try Persistence.fetchPathTraces(in: database, dayRange: range) }
        // Heal trips whose Google metadata is clearly wrong (endpoints + distance that
        // don't match the path samples). Render-time only — DB is untouched.
        dayTrips = rawTrips.map { Self.heal(trip: $0, withPaths: dayPathTraces) }
        dayRefinedPolylines = loggingFetch("fetchActivityPolylines", fallback: [:]) { try Persistence.fetchActivityPolylines(in: database, dayRange: range) }
        dayRefinedActivityIDs = loggingFetch("fetchRefinedActivityIDs", fallback: []) { try Persistence.fetchRefinedActivityIDs(in: database, dayRange: range) }
        // Compute the polyline render plan + direction markers once per data change so the
        // map's body doesn't re-run the O(activities × paths × samples) pipeline on every
        // camera gesture (M22).
        dayTripRenders = TripRenderPlan.renders(
            paths: dayPathTraces,
            activities: dayTrips,
            refinedByActivity: dayRefinedPolylines
        )
        dayDirectionMarkers = dayTripRenders.flatMap { render in
            PolylineDirection.markers(for: render.coordinates, polylineID: render.id)
        }
        let rawTimeline = loggingFetch("fetchTimeline", fallback: []) { try Persistence.fetchTimeline(in: database, dayRange: range) }
        // Apply the same render-time heal to timeline rows so the "13.8 km" label on
        // a corrupted Google activity matches the corrected distance on the trip detail
        // screen + the polyline on the map.
        let tripsByID = Dictionary(uniqueKeysWithValues: dayTrips.map { ($0.id, $0) })
        dayTimeline = rawTimeline.map { entry in
            guard entry.kind == "activity",
                  case let .activity(_, mode) = entry.detail,
                  let healed = tripsByID[entry.id]
            else {
                return entry
            }
            return TimelineEntry(
                id: entry.id,
                kind: entry.kind,
                start: entry.start,
                end: entry.end,
                detail: .activity(distanceMeters: healed.distanceMeters, mode: mode)
            )
        }
        daySummary = loggingFetch("fetchDaySummary", fallback: .empty) { try Persistence.fetchDaySummary(in: database, dayRange: range) }
        dayJourneysByAnchor = precomputeJourneys(trips: dayTrips, timeline: dayTimeline)
        recomputeEntryIDsWithNearbyPhotos()
        // dayPhotos is loaded separately by MapScreen when its toggle is on (we don't want
        // to ask for Photos access from this layer; the view decides when).
    }

    private static let photosLog = Logger(subsystem: "com.tibo.rememberme", category: "photos")

    /// Fetches day photos when the user has the toggle on and granted access. Safe to call
    /// even when the toggle is off — it just clears the array.
    func loadDayPhotos(enabled: Bool) async {
        guard enabled else {
            dayPhotos = []
            recomputeEntryIDsWithNearbyPhotos()
            return
        }
        let status = await photoLibrary.ensureAuthorized()
        let range = dayRange
        Self.photosLog.notice("loadDayPhotos enabled=\(enabled, privacy: .public) auth=\(String(describing: status), privacy: .public) start=\(range.lowerBound, privacy: .public) end=\(range.upperBound, privacy: .public)")
        guard status == .authorized || status == .limited else {
            dayPhotos = []
            recomputeEntryIDsWithNearbyPhotos()
            return
        }
        let photos = await photoLibrary.photos(in: range)
        Self.photosLog.notice("fetched \(photos.count, privacy: .public) photos for selectedDay=\(self.selectedDay, privacy: .public)")
        dayPhotos = photos
        recomputeEntryIDsWithNearbyPhotos()
    }

    /// Sets the selected day and re-fetches day data. Clears any focused map item
    /// (the map will fit to the new day's overall data).
    func selectDay(_ date: Date) async {
        selectedDay = calendar.startOfDay(for: date)
        focusedItem = nil
        await loadDay()
    }

    // MARK: - Navigation

    /// Pushes the current state on the stack and applies the supplied destination.
    /// Used by the timeline "Recent visits" rows that jump to another day.
    func navigate(toDay day: Date, tab: DrawerTab = .timeline, focusing focus: MapFocusItem? = nil) async {
        navigationStack.append(NavigationSnapshot(day: selectedDay, drawerTab: drawerTab, focusedItem: focusedItem))
        drawerTab = tab
        focusedItem = focus
        await selectDay(day)
        // Re-apply focus after selectDay clears it (selectDay clears on purpose, but here we
        // explicitly want a follow-up focus).
        focusedItem = focus
    }

    /// Sets the map's focused item without changing the day or pushing history.
    /// Used when tapping a timeline row in the current day's list.
    func focus(_ item: MapFocusItem) {
        focusedItem = item
    }

    /// When true, the next `clearFocus()` is swallowed and resets the flag. Set right before
    /// dismissing a sheet that has *intentionally* set a new focus (e.g. PlaceDetailView's
    /// "jump to visit" / photo-strip tap), so the sheet's `onDismiss` clearFocus doesn't race
    /// it and wipe the focus the user just asked for (M24).
    private var suppressFocusClearOnce = false

    func suppressNextFocusClear() {
        suppressFocusClearOnce = true
    }

    func clearFocus() {
        if suppressFocusClearOnce {
            suppressFocusClearOnce = false
            return
        }
        focusedItem = nil
    }

    /// Pops the top frame of the navigation stack and restores its state.
    func goBack() async {
        guard let previous = navigationStack.popLast() else { return }
        drawerTab = previous.drawerTab
        focusedItem = previous.focusedItem
        if !calendar.isDate(previous.day, inSameDayAs: selectedDay) {
            selectedDay = calendar.startOfDay(for: previous.day)
            await loadDay()
            focusedItem = previous.focusedItem
        }
    }

    private var calendar: Calendar {
        Calendar.current
    }

    /// Date range currently in scope. Width depends on `selectedRange`:
    ///   - `.day`   → the single day starting at `selectedDay`
    ///   - `.week`  → the calendar week containing `selectedDay`
    ///   - `.month` → the calendar month containing `selectedDay`
    var dayRange: Range<Date> {
        let start: Date
        let end: Date
        switch selectedRange {
        case .day:
            start = calendar.startOfDay(for: selectedDay)
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        case .week:
            let weekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDay)
            ) ?? calendar.startOfDay(for: selectedDay)
            start = weekStart
            end = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart.addingTimeInterval(7 * 86400)
        case .month:
            let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: selectedDay)
            ) ?? calendar.startOfDay(for: selectedDay)
            start = monthStart
            end = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart.addingTimeInterval(30 * 86400)
        }
        return start ..< end
    }

    func selectRange(_ kind: DateRangeKind) async {
        selectedRange = kind
        await loadDay()
    }

    /// Steps the anchor day forward / backward by one range unit.
    func stepRange(by direction: Int) async {
        let component: Calendar.Component = switch selectedRange {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        if let next = calendar.date(byAdding: component, value: direction, to: selectedDay) {
            await selectDay(next)
        }
    }

    // MARK: - Import

    /// Removes the document picker's `asCopy` temporary file once we're done reading it. Only
    /// touches files the picker dropped under the app's temporary directory (multi-hundred-MB
    /// Takeout copies otherwise linger until iOS's tmp cleanup) — never the user's original.
    private func cleanUpPickerCopy(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(tmp) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Decodes a Google Takeout `location-history.json` at `url` and writes everything into the DB.
    /// The heavy lifting happens off the main actor.
    ///
    /// `cutoff` implements the free tier's import window: events that *end* before it are
    /// counted but not written (callers pass `now - 14 days` when Premium isn't owned, `nil`
    /// when it is). Re-importing the same file after upgrading is safe — event IDs are
    /// deterministic and the writer dedupes, so only the older records are added.
    func importTakeout(from url: URL, cutoff: Date? = nil) async {
        await ensureOpen()
        guard let database else { return }

        importStatus = .running(stage: "Reading file…")

        // The file picker hands us a security-scoped URL — we must open the scope before reading.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        // Drop the picker's tmp copy once we've finished reading it (runs after the scope stop).
        defer { cleanUpPickerCopy(url) }

        do {
            importStatus = .running(stage: "Decoding…")
            let writer = EventWriter(database: database)
            // Stream the file: map the raw bytes (so they stay clean/paged out instead of
            // fully resident) and decode record-by-record, flushing each batch to the writer.
            // Peak memory is one record slice + one batch, not file + [Wire] + [Event] — large
            // multi-hundred-MB Takeout files no longer get jetsam-killed (M28).
            let (skippedCount, skippedOlderCount) = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                var skippedOlder = 0
                let skipped = try GoogleTakeoutDecoder().decodeStreaming(data) { batch in
                    if let cutoff {
                        let kept = batch.filter { $0.end.date >= cutoff }
                        skippedOlder += batch.count - kept.count
                        if !kept.isEmpty { try writer.write(kept) }
                    } else {
                        try writer.write(batch)
                    }
                }
                return (skipped.count, skippedOlder)
            }.value

            await refresh()
            importStatus = .completed(counts, skipped: skippedCount, skippedOlder: skippedOlderCount)

            // Once new visits land, start filling in names in the background.
            geocoder?.start()
        } catch {
            importStatus = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Encrypted export / import

    enum ExportStatus: Equatable, Sendable {
        case idle
        case running(stage: String)
        case completed(url: URL, eventCount: Int)
        case failed(message: String)
    }

    var exportStatus: ExportStatus = .idle

    /// Dumps the DB, seals it under `passphrase`, and writes the result to a
    /// `.rmex` file in the app's tmp directory. Returns the file URL on success so the
    /// caller can present a ShareSheet. The file is short-lived — once shared, the
    /// caller (or iOS's tmp cleanup) can drop it.
    @discardableResult
    func exportEncrypted(passphrase: String) async -> URL? {
        await ensureOpen()
        guard let database else {
            exportStatus = .failed(message: "Database is not open.")
            return nil
        }
        exportStatus = .running(stage: "Collecting…")
        do {
            // fetchExportPayload walks the whole DB; keep it off the main actor so large
            // histories don't freeze the UI (watchdog risk). Same detached pattern as
            // importEncrypted's restore.
            let payload = try await Task.detached(priority: .userInitiated) { [database] in
                try Persistence.fetchExportPayload(in: database)
            }.value
            let eventCount = payload.events.count
            exportStatus = .running(stage: "Encrypting \(eventCount) events…")

            // Argon2id is CPU-heavy; do the encrypt off-main.
            let envelopeData = try await Task.detached(priority: .userInitiated) {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                let payloadJSON = try encoder.encode(payload)
                return try ExportEnvelope.seal(payload: payloadJSON, passphrase: passphrase)
            }.value

            let filename = exportFilename(for: payload.exportedAt)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try envelopeData.write(to: url, options: [.atomic, .completeFileProtection])

            exportStatus = .completed(url: url, eventCount: eventCount)
            return url
        } catch {
            exportStatus = .failed(message: error.localizedDescription)
            return nil
        }
    }

    /// Opens an `.rmex` file at `url`, derives the key from `passphrase`, decodes the
    /// payload, and restores it additively (OR IGNORE on primary keys). Returns the
    /// number of new event rows that landed.
    @discardableResult
    func importEncrypted(from url: URL, passphrase: String) async -> Int {
        await ensureOpen()
        guard let database else {
            exportStatus = .failed(message: "Database is not open.")
            return 0
        }
        exportStatus = .running(stage: "Reading file…")

        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        // Drop the picker's tmp copy once we've finished reading it (runs after the scope stop).
        defer { cleanUpPickerCopy(url) }

        do {
            let data = try Data(contentsOf: url)
            exportStatus = .running(stage: "Decrypting…")
            let payload = try await Task.detached(priority: .userInitiated) {
                let payloadJSON = try ExportEnvelope.open(envelope: data, passphrase: passphrase)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(ExportPayload.self, from: payloadJSON)
            }.value

            exportStatus = .running(stage: "Restoring \(payload.events.count) events…")
            let written = try await Task.detached(priority: .userInitiated) { [database] in
                try Persistence.restore(payload: payload, in: database)
            }.value

            await refresh()
            let exportURL = url
            exportStatus = .completed(url: exportURL, eventCount: written)
            geocoder?.start()
            return written
        } catch ExportEnvelope.Failure.decryptionFailed {
            exportStatus = .failed(message: "Wrong passphrase or the file has been modified.")
            return 0
        } catch ExportEnvelope.Failure.badMagic {
            exportStatus = .failed(message: "This isn't a RememberMe export file.")
            return 0
        } catch ExportEnvelope.Failure.unsupportedVersion(let v) {
            exportStatus = .failed(message: "Unsupported export version: \(v)")
            return 0
        } catch {
            exportStatus = .failed(message: error.localizedDescription)
            return 0
        }
    }

    private func exportFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "RememberMe-\(formatter.string(from: date)).rmex"
    }

    // MARK: - Place detail support

    /// Fetches the visit history for the selected place. Caller refreshes when needed.
    func visitHistory(for placeID: String) -> [VisitHistoryItem] {
        guard let database else { return [] }
        return (try? Persistence.fetchVisitHistory(in: database, placeID: placeID)) ?? []
    }

    // MARK: - Phase 9: orphan recovery

    /// Finds path events from the live tracker that were never paired with an
    /// activity event (meaning the trip didn't finish cleanly — app crash, OS
    /// kill mid-trip, etc.) and writes a placeholder `unknown`-mode activity
    /// so each trip is fully finalised. Orphans with zero path points carry no
    /// usable data and are deleted outright (writing a placeholder for them is
    /// what created the bogus "0 m trip at (0,0)" timeline rows). Called once
    /// per launch right after `ensureOpen`. Returns the number of orphans
    /// handled; quiet when there are none.
    @discardableResult
    private func recoverOrphanedLiveTrips(writer: LiveTripWriter) async -> Int {
        let recoveryLog = Logger(subsystem: "com.tibo.rememberme", category: "recovery")
        let orphans: [LiveTripWriter.OrphanedPath]
        do {
            orphans = try writer.findOrphanedLivePaths()
        } catch {
            recoveryLog.error("findOrphanedLivePaths failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        guard !orphans.isEmpty else { return 0 }
        recoveryLog.notice("found \(orphans.count, privacy: .public) orphaned live trip(s); finalising")

        var handled = 0
        for orphan in orphans {
            do {
                let endpoints = try writer.fetchTripEndpointsAndDistance(eventID: orphan.id)
                if let (start, end, distance) = endpoints {
                    try writer.writeActivity(
                        eventID: UUID(),
                        start: orphan.start,
                        end: orphan.end,
                        tzOffsetMinutes: orphan.startTZOffsetMinutes,
                        startCoord: start,
                        endCoord: end,
                        distanceMeters: distance,
                        mode: "unknown",
                        probability: 0
                    )
                    recoveryLog.notice("recovered orphan id=\(orphan.id.uuidString, privacy: .public) dist=\(Int(distance), privacy: .public)m")
                } else {
                    // Path event with zero path_points — the trip opened but no
                    // fix landed. There's nothing to show; drop the event.
                    try writer.deleteEvents(ids: [orphan.id])
                    recoveryLog.notice("deleted empty orphan id=\(orphan.id.uuidString, privacy: .public) (no fixes)")
                }
                handled += 1
            } catch {
                recoveryLog.error("failed to recover orphan id=\(orphan.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return handled
    }

    /// Sets (or clears) the user-chosen label for a place. Empty/whitespace clears.
    /// Refreshes markers + timeline so the new name appears everywhere immediately.
    func setUserLabel(for marker: VisitMarker, label: String?) async {
        guard let database else { return }
        do {
            try Persistence.setUserLabel(
                in: database,
                placeID: marker.placeID,
                coordinate: marker.coordinate,
                userLabel: label
            )
            await refresh()
        } catch {
            importStatus = .failed(message: "Couldn't save label: \(error.localizedDescription)")
        }
    }

    /// Updates an activity's transport mode without touching anything else (coordinates,
    /// distance, timestamps stay as recorded). Wired to the timeline's "Change mode"
    /// context menu — TripStyle picks the new icon + friendly label automatically.
    func setMode(for trip: TripSummary, to newMode: String) async {
        guard let database else { return }
        do {
            try Persistence.updateActivityMode(in: database, eventID: trip.id, mode: newMode)
            await loadDay()
        } catch {
            importStatus = .failed(message: "Couldn't change mode: \(error.localizedDescription)")
        }
    }

    /// Triggers a one-off reverse-geocode for a place, refreshes markers when done.
    func resolveLabel(for marker: VisitMarker) async -> String? {
        let label = await geocoder?.resolveOnDemand(placeID: marker.placeID, coordinate: marker.coordinate)
        // Refresh markers so the cached label updates everywhere.
        await refresh()
        return label
    }

    /// Builds a map from every activity id to its multi-leg journey (if any), so the
    /// timeline context menu can look up "is this part of a journey?" in O(1). Same
    /// detector logic as before, just memoized — avoids the SwiftUI closure-evaluation
    /// lag that intermittently hid the "Refine whole journey" menu item.
    private func precomputeJourneys(
        trips: [TripSummary],
        timeline: [TimelineEntry]
    ) -> [UUID: Journey] {
        var byAnchor: [UUID: Journey] = [:]
        for trip in trips {
            guard byAnchor[trip.id] == nil else { continue }
            if let journey = JourneyDetector.detect(around: trip, in: timeline, dayTrips: trips),
               journey.isMultiLeg
            {
                // Every leg of the same journey points at the same Journey instance, so
                // long-pressing A, B, or C surfaces an identical menu.
                for memberTrip in journey.trips {
                    byAnchor[memberTrip.id] = journey
                }
            }
        }
        return byAnchor
    }

    /// Recorded GPS samples for `trip`, aggregated from the day's `path` events by time
    /// overlap. Delegates to `TripRenderPlan.slicedSamples` — the same single source of truth
    /// that draws the trip line on the map — so the refinement scoring and the rendered
    /// polyline never drift apart.
    func recordedSamples(forTrip trip: TripSummary) -> [Coordinate] {
        TripRenderPlan.slicedSamples(for: trip, paths: dayPathTraces)
    }

    /// Mismatch threshold for the heal heuristic. When Google's recorded
    /// `startCoordinate` / `endCoordinate` is more than this far from the covering
    /// path event's first/last in-window sample, we treat Google's metadata as broken
    /// and substitute the path samples. Single source of truth — also referenced by
    /// `PathRefinementController` so the heal and the scoring-fallback stay in sync (L39).
    static let healMismatchThresholdMeters: Double = 1_500

    /// True when `googleEnd` lies plausibly further along the path's direction of
    /// travel than `pathEnd`. Used to decide whether to keep Google's stored end
    /// (sparse GPS samples stop partway) or heal it (Google's metadata is broken).
    ///
    /// Two checks:
    ///   1. Google's end is at least 10% further from path start than the last sample.
    ///   2. The bearing from path start to Google's end is within 60° of the bearing
    ///      from path start to path end.
    /// Short paths (under 100 m of sample span) default to trusting Google's end.
    private static func googleEndIsPlausiblyFurther(
        googleEnd: Coordinate,
        pathStart: Coordinate,
        pathEnd: Coordinate
    ) -> Bool {
        let firstToLast = PolylineDirection.haversineMeters(pathStart, pathEnd)
        let firstToGoogle = PolylineDirection.haversineMeters(pathStart, googleEnd)
        guard firstToLast >= 100 else { return true }
        guard firstToGoogle > firstToLast * 1.1 else { return false }

        let pathBearing = PolylineDirection.bearingDegrees(from: pathStart, to: pathEnd)
        let endBearing = PolylineDirection.bearingDegrees(from: pathStart, to: googleEnd)
        let rawDiff = abs(pathBearing - endBearing).truncatingRemainder(dividingBy: 360)
        let shortest = min(rawDiff, 360 - rawDiff)
        return shortest < 60
    }

    /// Returns a TripSummary patched in-memory when Google's stored start/end/distance
    /// don't agree with the covering path event's GPS samples. Render-time only — the
    /// DB row is unchanged, so a fresh re-import re-heals from the same source data.
    ///
    /// Each endpoint is healed *independently* — only the start or only the end may be
    /// off, so we never replace a good endpoint with a sparse last-sample value just
    /// because the *other* endpoint was bad. Distance becomes the max of Google's
    /// stored distance, the polyline sample-sum, and the crow-flies between the
    /// (possibly partly-healed) endpoints.
    static func heal(trip: TripSummary, withPaths paths: [PathTrace]) -> TripSummary {
        // Find a covering path event by time overlap.
        guard let coveringPath = paths.first(where: { covering in
            let latestStart = max(covering.start.date, trip.start.date)
            let earliestEnd = min(covering.end.date, trip.end.date)
            return earliestEnd > latestStart
        }) else {
            return trip
        }

        // Slice the path's samples to the trip's time window.
        let activityStartOffsetSec = trip.start.date.timeIntervalSince(coveringPath.start.date)
        let activityEndOffsetSec = trip.end.date.timeIntervalSince(coveringPath.start.date)
        let sliced = coveringPath.samples.filter { sample in
            let offsetSec = TimeInterval(sample.offsetMinutes * 60)
            return offsetSec >= activityStartOffsetSec && offsetSec <= activityEndOffsetSec
        }
        guard let first = sliced.first?.coordinate, let last = sliced.last?.coordinate else {
            return trip
        }

        let startMismatch = PolylineDirection.haversineMeters(trip.startCoordinate, first)
        let endMismatch = PolylineDirection.haversineMeters(trip.endCoordinate, last)
        let healStart = startMismatch > Self.healMismatchThresholdMeters
        // For the end: even when it's far from the last sample, Google's stored end may
        // still be the real destination — the GPS samples are often sparse and stop
        // partway. Only heal it when Google's end is NOT plausibly further along the
        // path's direction of travel.
        let healEnd: Bool = {
            guard endMismatch > Self.healMismatchThresholdMeters else { return false }
            return !Self.googleEndIsPlausiblyFurther(
                googleEnd: trip.endCoordinate,
                pathStart: first,
                pathEnd: last
            )
        }()
        guard healStart || healEnd else { return trip }

        let newStart = healStart ? first : trip.startCoordinate
        let newEnd = healEnd ? last : trip.endCoordinate

        // Distance: largest of (Google's stored value, sample-polyline sum, crow-flies
        // between the resulting endpoints). For the canonical broken case (start healed,
        // end kept), the crow-flies term recovers most of the real journey length even
        // though the polyline only covers the sampled portion.
        var polylineDistance: Double = 0
        var prev = first
        for sample in sliced.dropFirst() {
            polylineDistance += PolylineDirection.haversineMeters(prev, sample.coordinate)
            prev = sample.coordinate
        }
        let crowFlies = PolylineDirection.haversineMeters(newStart, newEnd)
        let healedDistance = max(trip.distanceMeters, polylineDistance, crowFlies)

        return TripSummary(
            id: trip.id,
            start: trip.start,
            end: trip.end,
            startCoordinate: newStart,
            endCoordinate: newEnd,
            distanceMeters: healedDistance,
            mode: trip.mode
        )
    }

    /// Internal escape hatch for in-process feature controllers that need to do their own
    /// DB writes (e.g. `PathRefinementController`). Returns nil if the DB isn't open yet.
    func openDatabase() -> SQLCipherDatabase? { database }

    // MARK: - Debug-only auto-import

    #if DEBUG
    /// If the app's own Documents folder contains `location-history.json` AND the database is
    /// currently empty, kicks off an import. Lets us drive the full flow from `xcrun simctl`
    /// without manually steering the file picker.
    ///
    /// This entire method is omitted from Release builds.
    func autoImportSampleIfPresent() async {
        guard counts.total == 0 else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let candidate = docs?.appendingPathComponent("location-history.json"),
              FileManager.default.fileExists(atPath: candidate.path)
        else {
            return
        }
        await importTakeout(from: candidate)
    }
    #endif

    // MARK: - Helpers

    private static func defaultDatabasePath() -> String {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = appSupport.appendingPathComponent("RememberMe", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("db.sqlite")
        // .completeUntilFirstUserAuthentication so background location callbacks can write
        // after the user has unlocked the device at least once since boot. Required for the
        // live tracker; existing users get migrated on first launch after this change.
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: file.path
        )
        return file.path
    }
}

extension Persistence.EventCounts {
    static let empty = Persistence.EventCounts(total: 0, activities: 0, visits: 0, paths: 0)
}
