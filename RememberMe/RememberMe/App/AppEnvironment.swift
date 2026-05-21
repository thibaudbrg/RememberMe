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
public final class AppEnvironment {
    public enum ImportStatus: Equatable, Sendable {
        case idle
        case running(stage: String)
        case completed(Persistence.EventCounts, skipped: Int)
        case failed(message: String)
    }

    private let keyStore: any KeyStore
    private let databasePath: String
    private var database: SQLCipherDatabase?
    public private(set) var geocoder: GeocodingService?

    public var counts: Persistence.EventCounts = .empty
    public var insights: InsightsSummary = .empty
    public var visitMarkers: [VisitMarker] = []
    public var recentTrips: [TripSummary] = []
    public var timeline: [TimelineEntry] = []
    public var selectedPlace: VisitMarker?
    public var importStatus: ImportStatus = .idle

    // MARK: - Day filter (round 5)

    /// Currently selected calendar day (anchor) in the user's local timezone, at midnight.
    /// Combined with `selectedRange` this drives the visible date range on the map + timeline.
    public var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// How wide a date range the user is viewing.
    public enum DateRangeKind: String, Equatable, Sendable, CaseIterable, Identifiable {
        case day, week, month
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .day: "Day"
            case .week: "Week"
            case .month: "Month"
            }
        }
    }

    public var selectedRange: DateRangeKind = .day

    /// Days that have at least one event. Used by the calendar UI to mark them with a dot
    /// and to pick a sensible default day when "today" is empty.
    public var daysWithData: [Date] = []

    public var dayMarkers: [VisitMarker] = []
    public var dayTrips: [TripSummary] = []
    public var dayPathTraces: [PathTrace] = []
    public var dayTimeline: [TimelineEntry] = []
    public var daySummary: DaySummary = .empty

    /// Photos taken on the selected day (only populated when the user enabled the toggle and
    /// granted Photos library access). Empty otherwise.
    public var dayPhotos: [GeoPhoto] = []
    public let photoLibrary = PhotoLibraryService()

    // MARK: - Navigation (round 6)

    /// One frame of the navigation history. Capturing what the drawer should restore on "Back".
    public struct NavigationSnapshot: Equatable, Sendable {
        public let day: Date
        public let drawerTab: DrawerTab
        public let focusedItem: MapFocusItem?
        public init(day: Date, drawerTab: DrawerTab, focusedItem: MapFocusItem?) {
            self.day = day
            self.drawerTab = drawerTab
            self.focusedItem = focusedItem
        }
    }

    public enum DrawerTab: String, Equatable, Sendable, CaseIterable {
        case timeline
        case photos
        case insights
    }

    /// What the map should currently focus on. Set when the user taps a timeline row;
    /// cleared on day change or back-navigation.
    public enum MapFocusItem: Equatable, Sendable {
        case visit(placeID: String, coordinate: Coordinate)
        case trip(id: UUID)
        case path(id: UUID)
        case photo(id: String, coordinate: Coordinate)
    }

    public var drawerTab: DrawerTab = .timeline
    public var focusedItem: MapFocusItem?
    public private(set) var navigationStack: [NavigationSnapshot] = []

    /// Coarse drawer state — small (peek), medium, large.
    public enum DrawerSize: String, Equatable, Sendable, CaseIterable {
        case small, medium, large

        /// Approximate drawer height in points for a given screen height.
        /// `small` is the fixed peek detent we use in RootView (`.height(180)`).
        public func heightInPoints(screenHeight: CGFloat) -> CGFloat {
            switch self {
            case .small: 180
            case .medium: screenHeight * 0.5
            case .large: screenHeight * 0.92
            }
        }
    }

    public var drawerSize: DrawerSize = .small

    /// Session-only filter applied to the timeline list (does not affect the map).
    public enum TimelineFilter: String, Equatable, Sendable, CaseIterable, Identifiable {
        case all, trips, visits, walking, vehicle, transit
        public var id: String { rawValue }

        public var label: String {
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
        public func matches(_ entry: TimelineEntry) -> Bool {
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

    public var timelineFilter: TimelineFilter = .all

    /// `dayTimeline` filtered by `timelineFilter`. Computed so callers can subscribe to changes
    /// in either the source list or the filter without manual refresh code.
    public var filteredDayTimeline: [TimelineEntry] {
        guard timelineFilter != .all else { return dayTimeline }
        return dayTimeline.filter(timelineFilter.matches)
    }

    /// Visible events in the day timeline list. Path rows are hidden because the map already
    /// draws them as the trip line.
    public var visibleDayEvents: [TimelineEntry] {
        filteredDayTimeline.filter { $0.kind != "path" }
    }

    /// `dayMarkers` collapsed so repeated visits to the same named place within a short
    /// window only show one dot on the map. Trips, paths, and timeline rows are unaffected —
    /// only the visible point markers.
    public var dedupedDayMarkers: [VisitMarker] {
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
    public func hasNearbyPhoto(for entry: TimelineEntry, closeBySeconds: TimeInterval = 1_800, closeByMeters: Double = 300) -> Bool {
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

    public var canGoBack: Bool {
        !navigationStack.isEmpty
    }

    // MARK: - Init

    public init(keyStore: any KeyStore, databasePath: String) {
        self.keyStore = keyStore
        self.databasePath = databasePath
    }

    /// The production environment: real Keychain, real on-disk database under Application Support.
    public static func live() -> AppEnvironment {
        AppEnvironment(
            keyStore: KeychainKeyStore(),
            databasePath: defaultDatabasePath()
        )
    }

    /// Preview / unit-test environment: in-memory key, in-memory database.
    public static func preview() -> AppEnvironment {
        AppEnvironment(
            keyStore: InMemoryKeyStore(),
            databasePath: SQLCipherDatabase.inMemoryPath
        )
    }

    // MARK: - Database lifecycle

    /// Opens (or creates) the encrypted database and refreshes published state.
    /// Idempotent — safe to call multiple times.
    public func ensureOpen() async {
        if database != nil { return }
        do {
            let opened = try DatabaseFactory.open(
                at: databasePath,
                keyStore: keyStore,
                excludeFromBackup: databasePath != SQLCipherDatabase.inMemoryPath
            )
            database = opened
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
        } catch {
            importStatus = .failed(message: "Couldn't open database: \(error.localizedDescription)")
        }
    }

    /// Re-reads everything from the database — counts, markers, trips, timeline, day filter.
    /// Use after big writes (initial open, import). For granular updates after a single
    /// geocoded name lands, prefer `refreshDayTimeline()` so the SwiftUI `Map` doesn't
    /// reassign its markers array (which triggers a tile reload flash).
    public func refresh() async {
        guard let database else { return }
        do {
            counts = try Persistence.eventCounts(in: database)
            insights = (try? Persistence.fetchInsights(in: database)) ?? .empty
            visitMarkers = try Persistence.fetchVisitMarkers(in: database)
            recentTrips = try Persistence.fetchRecentTrips(in: database)
            timeline = try Persistence.fetchTimeline(in: database)
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
    public func refreshDayTimeline() async {
        guard let database else { return }
        dayTimeline = (try? Persistence.fetchTimeline(in: database, dayRange: dayRange)) ?? dayTimeline
    }

    /// Re-fetches all per-day data (markers/trips/paths/timeline/summary) for the current
    /// `selectedDay`. Called on selection changes.
    public func loadDay() async {
        guard let database else { return }
        let range = dayRange
        dayMarkers = (try? Persistence.fetchVisitMarkers(in: database, dayRange: range)) ?? []
        dayTrips = (try? Persistence.fetchTrips(in: database, dayRange: range)) ?? []
        dayPathTraces = (try? Persistence.fetchPathTraces(in: database, dayRange: range)) ?? []
        dayTimeline = (try? Persistence.fetchTimeline(in: database, dayRange: range)) ?? []
        daySummary = (try? Persistence.fetchDaySummary(in: database, dayRange: range)) ?? .empty
        // dayPhotos is loaded separately by MapScreen when its toggle is on (we don't want
        // to ask for Photos access from this layer; the view decides when).
    }

    private static let photosLog = Logger(subsystem: "com.tibo.rememberme", category: "photos")

    /// Fetches day photos when the user has the toggle on and granted access. Safe to call
    /// even when the toggle is off — it just clears the array.
    public func loadDayPhotos(enabled: Bool) async {
        guard enabled else {
            dayPhotos = []
            return
        }
        let status = await photoLibrary.ensureAuthorized()
        let range = dayRange
        Self.photosLog.notice("loadDayPhotos enabled=\(enabled, privacy: .public) auth=\(String(describing: status), privacy: .public) start=\(range.lowerBound, privacy: .public) end=\(range.upperBound, privacy: .public)")
        guard status == .authorized || status == .limited else {
            dayPhotos = []
            return
        }
        let photos = await photoLibrary.photos(in: range)
        Self.photosLog.notice("fetched \(photos.count, privacy: .public) photos for selectedDay=\(self.selectedDay, privacy: .public)")
        dayPhotos = photos
    }

    /// Sets the selected day and re-fetches day data. Clears any focused map item
    /// (the map will fit to the new day's overall data).
    public func selectDay(_ date: Date) async {
        selectedDay = calendar.startOfDay(for: date)
        focusedItem = nil
        await loadDay()
    }

    // MARK: - Navigation

    /// Pushes the current state on the stack and applies the supplied destination.
    /// Used by the timeline "Recent visits" rows that jump to another day.
    public func navigate(toDay day: Date, tab: DrawerTab = .timeline, focusing focus: MapFocusItem? = nil) async {
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
    public func focus(_ item: MapFocusItem) {
        focusedItem = item
    }

    public func clearFocus() {
        focusedItem = nil
    }

    /// Pops the top frame of the navigation stack and restores its state.
    public func goBack() async {
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
    public var dayRange: Range<Date> {
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

    public func selectRange(_ kind: DateRangeKind) async {
        selectedRange = kind
        await loadDay()
    }

    /// Steps the anchor day forward / backward by one range unit.
    public func stepRange(by direction: Int) async {
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

    /// Decodes a Google Takeout `location-history.json` at `url` and writes everything into the DB.
    /// The heavy lifting happens off the main actor.
    public func importTakeout(from url: URL) async {
        await ensureOpen()
        guard let database else { return }

        importStatus = .running(stage: "Reading file…")

        // The file picker hands us a security-scoped URL — we must open the scope before reading.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            importStatus = .running(stage: "Decoding…")
            let decoded = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                return try GoogleTakeoutDecoder().decode(data)
            }.value

            importStatus = .running(stage: "Writing \(decoded.events.count) events…")
            let writer = EventWriter(database: database)
            let written = try await Task.detached(priority: .userInitiated) {
                try writer.write(decoded.events)
            }.value

            await refresh()
            importStatus = .completed(counts, skipped: decoded.skipped.count)
            _ = written

            // Once new visits land, start filling in names in the background.
            geocoder?.start()
        } catch {
            importStatus = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Encrypted export / import

    public enum ExportStatus: Equatable, Sendable {
        case idle
        case running(stage: String)
        case completed(url: URL, eventCount: Int)
        case failed(message: String)
    }

    public var exportStatus: ExportStatus = .idle

    /// Dumps the DB, seals it under `passphrase`, and writes the result to a
    /// `.rmex` file in the app's tmp directory. Returns the file URL on success so the
    /// caller can present a ShareSheet. The file is short-lived — once shared, the
    /// caller (or iOS's tmp cleanup) can drop it.
    @discardableResult
    public func exportEncrypted(passphrase: String) async -> URL? {
        await ensureOpen()
        guard let database else {
            exportStatus = .failed(message: "Database is not open.")
            return nil
        }
        exportStatus = .running(stage: "Collecting…")
        do {
            let payload = try Persistence.fetchExportPayload(in: database)
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
    public func importEncrypted(from url: URL, passphrase: String) async -> Int {
        await ensureOpen()
        guard let database else {
            exportStatus = .failed(message: "Database is not open.")
            return 0
        }
        exportStatus = .running(stage: "Reading file…")

        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

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
    public func visitHistory(for placeID: String) -> [VisitHistoryItem] {
        guard let database else { return [] }
        return (try? Persistence.fetchVisitHistory(in: database, placeID: placeID)) ?? []
    }

    /// Sets (or clears) the user-chosen label for a place. Empty/whitespace clears.
    /// Refreshes markers + timeline so the new name appears everywhere immediately.
    public func setUserLabel(for marker: VisitMarker, label: String?) async {
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

    /// Triggers a one-off reverse-geocode for a place, refreshes markers when done.
    public func resolveLabel(for marker: VisitMarker) async -> String? {
        let label = await geocoder?.resolveOnDemand(placeID: marker.placeID, coordinate: marker.coordinate)
        // Refresh markers so the cached label updates everywhere.
        await refresh()
        return label
    }

    /// Returns path-point coordinates for a trip's matching `path` event if one exists.
    /// Falls back to the trip's start+end if no path is recorded.
    public func polyline(for trip: TripSummary) -> [Coordinate] {
        guard let database else { return [trip.startCoordinate, trip.endCoordinate] }
        let points = (try? Persistence.fetchPathPoints(in: database, eventID: trip.id)) ?? []
        return points.isEmpty ? [trip.startCoordinate, trip.endCoordinate] : points
    }

    // MARK: - Debug-only auto-import

    #if DEBUG
    /// If the app's own Documents folder contains `location-history.json` AND the database is
    /// currently empty, kicks off an import. Lets us drive the full flow from `xcrun simctl`
    /// without manually steering the file picker.
    ///
    /// This entire method is omitted from Release builds.
    public func autoImportSampleIfPresent() async {
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
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        return file.path
    }
}

public extension Persistence.EventCounts {
    static let empty = Persistence.EventCounts(total: 0, activities: 0, visits: 0, paths: 0)
}
