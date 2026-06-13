import Core
import Foundation
import OSLog

/// Persistence helpers for the live background tracker. Unlike the bulk
/// `EventWriter` path used by the Google Takeout importer, the live tracker
/// opens a single `path` event when a trip begins, then appends path points
/// incrementally as GPS fixes arrive, then finalises the event when the trip
/// ends. This keeps memory usage flat regardless of trip duration and means a
/// mid-trip crash leaves an "open" event that Phase 9 will recover.
///
/// `Sendable` (like `EventWriter`) so the tracker can hand it to a
/// `Task.detached` and write off the main actor. `SQLCipherDatabase` serialises
/// access through an internal recursive lock, so each call here owns the
/// connection for the duration of its statement(s) and can't interleave into
/// another thread's open transaction.
public final class LiveTripWriter: Sendable {
    /// Default source string for events produced by the live tracker on iOS.
    /// Distinct from `"google-takeout-ios-v1"` so the UI can filter by origin
    /// if it wants.
    public static let defaultSource = "live-ios-v1"

    private let database: SQLCipherDatabase
    private let source: String

    public init(database: SQLCipherDatabase, source: String = defaultSource) {
        self.database = database
        self.source = source
    }

    /// Inserts a new `path` event with `end_ts = start_ts` (placeholder; the
    /// caller updates it later via `updateEnd` or `finalise`). Throws if the
    /// event id already exists.
    public func openTrip(
        eventID: UUID,
        start: Date,
        tzOffsetMinutes: Int
    ) throws {
        let stmt = try database.prepare("""
            INSERT INTO events
                (id, kind, start_ts, start_tz_offset_min, end_ts, end_tz_offset_min, source, imported_at)
            VALUES (?, 'path', ?, ?, ?, ?, ?, ?);
        """)
        defer { stmt.finalize() }

        let ts = Int64(start.timeIntervalSince1970)
        try stmt.bind(1, text: eventID.uuidString)
        try stmt.bind(2, int64: ts)
        try stmt.bind(3, int: tzOffsetMinutes)
        try stmt.bind(4, int64: ts) // end_ts initially equal to start_ts
        try stmt.bind(5, int: tzOffsetMinutes)
        try stmt.bind(6, text: source)
        try stmt.bind(7, int64: Int64(Date().timeIntervalSince1970))
        try stmt.stepDone()
    }

    /// Appends a batch of path points to an existing path event. The caller is
    /// responsible for assigning sequence numbers (`startingSequence`,
    /// `startingSequence + 1`, ...) — the tracker tracks the next seq in memory.
    /// Wraps the inserts in a single transaction.
    public func appendPoints(
        eventID: UUID,
        startingSequence: Int,
        points: [PathPoint]
    ) throws {
        guard !points.isEmpty else { return }
        try database.transaction {
            let stmt = try database.prepare("""
                INSERT INTO path_points (event_id, seq, offset_min, lat, lon) VALUES (?, ?, ?, ?, ?);
            """)
            defer { stmt.finalize() }
            for (i, point) in points.enumerated() {
                try stmt.reset()
                try stmt.bind(1, text: eventID.uuidString)
                try stmt.bind(2, int: startingSequence + i)
                try stmt.bind(3, int: point.offsetMinutes)
                try stmt.bind(4, double: point.coordinate.latitude)
                try stmt.bind(5, double: point.coordinate.longitude)
                try stmt.stepDone()
            }
        }
    }

    /// Updates `end_ts` on an open path event. Called by the tracker either
    /// periodically (a "checkpoint" so a crash mid-trip preserves a sensible
    /// end time) or once at trip close. There's no separate "finalise"
    /// semantics at the SQL level — the last write wins.
    public func updateEnd(
        eventID: UUID,
        end: Date,
        tzOffsetMinutes: Int
    ) throws {
        let stmt = try database.prepare("""
            UPDATE events SET end_ts = ?, end_tz_offset_min = ? WHERE id = ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int64: Int64(end.timeIntervalSince1970))
        try stmt.bind(2, int: tzOffsetMinutes)
        try stmt.bind(3, text: eventID.uuidString)
        try stmt.stepDone()
        // A zero-row UPDATE means the target event doesn't exist yet — e.g. a departure
        // ran before its arrival INSERT — and would otherwise pass silently.
        if stmt.changes != 1 {
            Self.log.error("updateEnd matched \(stmt.changes) rows for event \(eventID.uuidString, privacy: .public); expected 1")
        }
    }

    private static let log = Logger(subsystem: "RememberMe.Persistence", category: "LiveTripWriter")

    // MARK: - Phase 7: sibling activity event

    /// Writes the sibling `activity` event for a finished path. Uses the same
    /// time window as the path so a future Phase-9 recovery query knows the
    /// path is fully finalised. `start` and `end` are the trip's actual
    /// timestamps; `startCoord`/`endCoord` come from the first and last
    /// buffered fixes; `distanceMeters` is the trip's total ground distance.
    public func writeActivity(
        eventID: UUID,
        start: Date,
        end: Date,
        tzOffsetMinutes: Int,
        startCoord: Coordinate,
        endCoord: Coordinate,
        distanceMeters: Double,
        mode: String,
        probability: Double
    ) throws {
        try database.transaction {
            let eventStmt = try database.prepare("""
                INSERT INTO events
                    (id, kind, start_ts, start_tz_offset_min, end_ts, end_tz_offset_min, source, imported_at)
                VALUES (?, 'activity', ?, ?, ?, ?, ?, ?);
            """)
            defer { eventStmt.finalize() }
            try eventStmt.bind(1, text: eventID.uuidString)
            try eventStmt.bind(2, int64: Int64(start.timeIntervalSince1970))
            try eventStmt.bind(3, int: tzOffsetMinutes)
            try eventStmt.bind(4, int64: Int64(end.timeIntervalSince1970))
            try eventStmt.bind(5, int: tzOffsetMinutes)
            try eventStmt.bind(6, text: source)
            try eventStmt.bind(7, int64: Int64(Date().timeIntervalSince1970))
            try eventStmt.stepDone()

            let activityStmt = try database.prepare("""
                INSERT INTO activities
                    (event_id, start_lat, start_lon, end_lat, end_lon, distance_m, mode, probability)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { activityStmt.finalize() }
            try activityStmt.bind(1, text: eventID.uuidString)
            try activityStmt.bind(2, double: startCoord.latitude)
            try activityStmt.bind(3, double: startCoord.longitude)
            try activityStmt.bind(4, double: endCoord.latitude)
            try activityStmt.bind(5, double: endCoord.longitude)
            try activityStmt.bind(6, double: distanceMeters)
            try activityStmt.bind(7, text: mode)
            try activityStmt.bind(8, double: probability)
            try activityStmt.stepDone()
        }
    }

    // MARK: - Phase 8: visits

    /// Inserts a new `visit` event + matching `visits` row. `end` defaults to
    /// `start` (placeholder) when the iOS `CLVisit` callback gave us an
    /// arrival without a departure yet — the tracker calls `closeVisit`
    /// later to update `end_ts`.
    public func openVisit(
        eventID: UUID,
        placeID: String,
        coordinate: Coordinate,
        start: Date,
        end: Date,
        tzOffsetMinutes: Int,
        semanticType: String = "Unknown",
        hierarchyLevel: Int = 0,
        probability: Double = 1.0
    ) throws {
        try database.transaction {
            let eventStmt = try database.prepare("""
                INSERT INTO events
                    (id, kind, start_ts, start_tz_offset_min, end_ts, end_tz_offset_min, source, imported_at)
                VALUES (?, 'visit', ?, ?, ?, ?, ?, ?);
            """)
            defer { eventStmt.finalize() }
            try eventStmt.bind(1, text: eventID.uuidString)
            try eventStmt.bind(2, int64: Int64(start.timeIntervalSince1970))
            try eventStmt.bind(3, int: tzOffsetMinutes)
            try eventStmt.bind(4, int64: Int64(end.timeIntervalSince1970))
            try eventStmt.bind(5, int: tzOffsetMinutes)
            try eventStmt.bind(6, text: source)
            try eventStmt.bind(7, int64: Int64(Date().timeIntervalSince1970))
            try eventStmt.stepDone()

            let visitStmt = try database.prepare("""
                INSERT INTO visits
                    (event_id, place_id, lat, lon, semantic_type, hierarchy_level, probability)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            defer { visitStmt.finalize() }
            try visitStmt.bind(1, text: eventID.uuidString)
            try visitStmt.bind(2, text: placeID)
            try visitStmt.bind(3, double: coordinate.latitude)
            try visitStmt.bind(4, double: coordinate.longitude)
            try visitStmt.bind(5, text: semanticType)
            try visitStmt.bind(6, int: hierarchyLevel)
            try visitStmt.bind(7, double: probability)
            try visitStmt.stepDone()
        }
    }

    /// Updates `end_ts` on a previously-opened visit. Used when iOS later
    /// delivers the departure for a visit we opened on arrival.
    public func closeVisit(
        eventID: UUID,
        end: Date,
        tzOffsetMinutes: Int
    ) throws {
        try updateEnd(eventID: eventID, end: end, tzOffsetMinutes: tzOffsetMinutes)
    }

    /// An existing live visit row matched by arrival timestamp + proximity.
    public struct LiveVisitMatch: Sendable, Equatable {
        public let eventID: UUID
        public let placeID: String
    }

    /// Finds an existing live-tracker visit with the same arrival timestamp and
    /// a coordinate within `withinMeters`. iOS delivers the same `CLVisit`
    /// multiple times (arrival callback, departure callback, re-deliveries
    /// across app relaunches) with an identical `arrivalDate` — that's the
    /// stable identity we dedupe on. Returns nil when no row matches.
    public func findLiveVisit(
        arrival: Date,
        near coordinate: Coordinate,
        withinMeters: Double = 300
    ) throws -> LiveVisitMatch? {
        let stmt = try database.prepare("""
            SELECT e.id, v.place_id, v.lat, v.lon
            FROM events e
            JOIN visits v ON v.event_id = e.id
            WHERE e.kind = 'visit' AND e.source = ? AND e.start_ts = ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: source)
        try stmt.bind(2, int64: Int64(arrival.timeIntervalSince1970))

        while try stmt.step() == .row {
            guard let idString = stmt.columnText(0), let id = UUID(uuidString: idString) else { continue }
            let rowCoord = Coordinate(latitude: stmt.columnDouble(2), longitude: stmt.columnDouble(3))
            if PolylineDirection.haversineMeters(rowCoord, coordinate) <= withinMeters {
                return LiveVisitMatch(eventID: id, placeID: stmt.columnText(1) ?? "")
            }
        }
        return nil
    }

    /// One-time hygiene for duplicates created by earlier builds: live visits
    /// sharing the same arrival timestamp and a coordinate within
    /// `withinMeters` are the same physical visit delivered multiple times.
    /// Keeps the row with the latest `end_ts` (the most complete one) and
    /// deletes the rest. Returns the number of rows removed.
    @discardableResult
    public func dedupeLiveVisits(withinMeters: Double = 300) throws -> Int {
        let stmt = try database.prepare("""
            SELECT e.id, e.start_ts, e.end_ts, v.lat, v.lon
            FROM events e
            JOIN visits v ON v.event_id = e.id
            WHERE e.kind = 'visit' AND e.source = ?
            ORDER BY e.start_ts ASC, e.end_ts DESC;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: source)

        struct Row { let id: UUID; let start: Int64; let coord: Coordinate }
        var kept: [Row] = []
        var toDelete: [UUID] = []
        while try stmt.step() == .row {
            guard let idString = stmt.columnText(0), let id = UUID(uuidString: idString) else { continue }
            let row = Row(
                id: id,
                start: stmt.columnInt64(1),
                coord: Coordinate(latitude: stmt.columnDouble(3), longitude: stmt.columnDouble(4))
            )
            // Ordered by end_ts DESC within a start_ts group, so the first row
            // we keep for a group is the longest one.
            let isDuplicate = kept.contains { keptRow in
                keptRow.start == row.start
                    && PolylineDirection.haversineMeters(keptRow.coord, row.coord) <= withinMeters
            }
            if isDuplicate {
                toDelete.append(row.id)
            } else {
                kept.append(row)
            }
        }

        try deleteEvents(ids: toDelete)
        return toDelete.count
    }

    /// One-time hygiene for the "(0,0) Unknown trip" bug: earlier builds wrote
    /// placeholder activities at Null Island when a crashed trip had no GPS
    /// fixes. Deletes them. Returns the number of rows removed.
    @discardableResult
    public func deleteNullIslandActivities() throws -> Int {
        let stmt = try database.prepare("""
            SELECT e.id
            FROM events e
            JOIN activities a ON a.event_id = e.id
            WHERE e.kind = 'activity' AND e.source = ? AND a.mode = 'unknown'
              AND a.start_lat = 0 AND a.start_lon = 0 AND a.end_lat = 0 AND a.end_lon = 0;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: source)

        var ids: [UUID] = []
        while try stmt.step() == .row {
            guard let idString = stmt.columnText(0), let id = UUID(uuidString: idString) else { continue }
            ids.append(id)
        }
        try deleteEvents(ids: ids)
        return ids.count
    }

    /// Deletes events plus their dependent rows (explicitly, so we don't rely
    /// on the connection having `PRAGMA foreign_keys` enabled).
    public func deleteEvents(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try database.transaction {
            for table in [
                "path_points", "path_points_original", "visits", "activities",
                "path_refinements", "path_refinement_skips",
            ] {
                let child = try database.prepare("DELETE FROM \(table) WHERE event_id = ?;")
                defer { child.finalize() }
                for id in ids {
                    try child.reset()
                    try child.bind(1, text: id.uuidString)
                    try child.stepDone()
                }
            }
            let events = try database.prepare("DELETE FROM events WHERE id = ?;")
            defer { events.finalize() }
            for id in ids {
                try events.reset()
                try events.bind(1, text: id.uuidString)
                try events.stepDone()
            }
        }
    }

    // MARK: - Phase 9: crash recovery

    /// Path events from the live tracker that have NO matching activity event
    /// (same start_ts/end_ts) — i.e., trips that were opened but never had
    /// their sibling activity written. Indicates either a mid-trip crash or a
    /// crash between the path's final `updateEnd` and the `writeActivity`
    /// call. Caller is expected to write the missing activity (mode=`unknown`,
    /// probability=0) from whatever path-point data survived. The path's id
    /// and the activity's id are DIFFERENT — they're linked by time window,
    /// not by id, because the events PK is `id` alone.
    public func findOrphanedLivePaths() throws -> [OrphanedPath] {
        // We share the source string so an orphan from a previous app version
        // still surfaces here.
        let stmt = try database.prepare("""
            SELECT p.id, p.start_ts, p.end_ts, p.start_tz_offset_min, p.end_tz_offset_min
            FROM events p
            WHERE p.kind = 'path' AND p.source = ?
              AND NOT EXISTS (
                SELECT 1 FROM events a
                WHERE a.kind = 'activity' AND a.source = ?
                  AND a.start_ts = p.start_ts AND a.end_ts = p.end_ts
              );
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: source)
        try stmt.bind(2, text: source)

        var orphans: [OrphanedPath] = []
        while try stmt.step() == .row {
            guard let idString = stmt.columnText(0), let id = UUID(uuidString: idString) else { continue }
            orphans.append(OrphanedPath(
                id: id,
                startTimestamp: stmt.columnInt64(1),
                endTimestamp: stmt.columnInt64(2),
                startTZOffsetMinutes: Int(stmt.columnInt32(3)),
                endTZOffsetMinutes: Int(stmt.columnInt32(4))
            ))
        }
        return orphans
    }

    public struct OrphanedPath: Sendable, Equatable {
        public let id: UUID
        public let startTimestamp: Int64
        public let endTimestamp: Int64
        public let startTZOffsetMinutes: Int
        public let endTZOffsetMinutes: Int

        public var start: Date { Date(timeIntervalSince1970: TimeInterval(startTimestamp)) }
        public var end: Date { Date(timeIntervalSince1970: TimeInterval(endTimestamp)) }
    }

    /// Returns first and last path point coordinates for `eventID`, or nil if
    /// the trip has none (e.g., it crashed before any fix landed). Used by
    /// the recovery pass to fill in the activity's `startCoord`/`endCoord`.
    public func fetchTripEndpointsAndDistance(eventID: UUID) throws -> (start: Coordinate, end: Coordinate, distanceMeters: Double)? {
        let stmt = try database.prepare("""
            SELECT lat, lon FROM path_points WHERE event_id = ? ORDER BY seq;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)

        var coords: [Coordinate] = []
        while try stmt.step() == .row {
            coords.append(Coordinate(latitude: stmt.columnDouble(0), longitude: stmt.columnDouble(1)))
        }
        guard let first = coords.first, let last = coords.last else { return nil }
        var distance: Double = 0
        for i in 1 ..< coords.count {
            distance += PolylineDirection.haversineMeters(coords[i - 1], coords[i])
        }
        return (first, last, distance)
    }
}
