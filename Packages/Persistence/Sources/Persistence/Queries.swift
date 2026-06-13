import Core
import Foundation

/// A single visit's row for the place-detail timeline. Joined view of `events` + `visits`.
public struct VisitHistoryItem: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let start: TimestampedLocal
    public let end: TimestampedLocal
    public let semanticType: String
    public let probability: Double

    public init(id: UUID, start: TimestampedLocal, end: TimestampedLocal, semanticType: String, probability: Double) {
        self.id = id
        self.start = start
        self.end = end
        self.semanticType = semanticType
        self.probability = probability
    }

    public var duration: TimeInterval {
        end.date.timeIntervalSince(start.date)
    }
}

/// An activity (movement) event with its endpoints, for trip polyline rendering.
public struct TripSummary: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let start: TimestampedLocal
    public let end: TimestampedLocal
    public let startCoordinate: Coordinate
    public let endCoordinate: Coordinate
    public let distanceMeters: Double
    public let mode: String

    public init(
        id: UUID,
        start: TimestampedLocal,
        end: TimestampedLocal,
        startCoordinate: Coordinate,
        endCoordinate: Coordinate,
        distanceMeters: Double,
        mode: String
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.distanceMeters = distanceMeters
        self.mode = mode
    }
}

/// One row of the timeline list (any event kind). Holds just enough to render a row.
public struct TimelineEntry: Hashable, Sendable, Identifiable {
    public enum Detail: Hashable, Sendable {
        case activity(distanceMeters: Double, mode: String)
        case visit(
            placeID: String,
            userLabel: String?,
            resolvedLabel: String?,
            semanticType: String,
            coordinate: Coordinate
        )
        case path(pointCount: Int)
    }

    public let id: UUID
    public let kind: String
    public let start: TimestampedLocal
    public let end: TimestampedLocal
    public let detail: Detail

    public init(id: UUID, kind: String, start: TimestampedLocal, end: TimestampedLocal, detail: Detail) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.detail = detail
    }

    public var duration: TimeInterval {
        end.date.timeIntervalSince(start.date)
    }
}

public extension Persistence {
    // MARK: - Places

    static func fetchPlace(in database: SQLCipherDatabase, placeID: String) throws -> Place? {
        let stmt = try database.prepare("""
            SELECT user_label, resolved_label, resolved_at, lat, lon
            FROM places
            WHERE place_id = ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: placeID)
        guard try stmt.step() == .row else { return nil }

        let userLabel = stmt.columnText(0)
        let resolvedLabel = stmt.columnText(1)
        let resolvedAtEpoch = stmt.columnInt64(2)
        let lat = stmt.columnDouble(3)
        let lon = stmt.columnDouble(4)

        return Place(
            placeID: placeID,
            userLabel: userLabel,
            resolvedLabel: resolvedLabel,
            resolvedAt: resolvedAtEpoch > 0 ? Date(timeIntervalSince1970: TimeInterval(resolvedAtEpoch)) : nil,
            coordinate: Coordinate(latitude: lat, longitude: lon)
        )
    }

    /// Sets (or clears) the user-chosen label for a place. Pass an empty/whitespace-only
    /// string to clear it. The reverse-geocoded label, if any, is preserved untouched.
    static func setUserLabel(
        in database: SQLCipherDatabase,
        placeID: String,
        coordinate: Coordinate,
        userLabel: String?
    ) throws {
        let trimmed = userLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let stmt = try database.prepare("""
            INSERT INTO places (place_id, user_label, resolved_label, resolved_at, lat, lon)
            VALUES (?, ?, NULL, 0, ?, ?)
            ON CONFLICT(place_id) DO UPDATE SET
                user_label = excluded.user_label;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: placeID)
        if let normalized {
            try stmt.bind(2, text: normalized)
        } else {
            try stmt.bindNull(2)
        }
        try stmt.bind(3, double: coordinate.latitude)
        try stmt.bind(4, double: coordinate.longitude)
        try stmt.stepDone()
    }

    /// Overwrites the `mode` column on an `activities` row. Used by the timeline's
    /// "Change mode" context menu so the user can correct a misclassified trip without
    /// touching its coordinates / distance / timestamps. Store the granular mode string
    /// (e.g. `"driving"`, `"bus"`, `"subway"`) — `TripStyle.symbol/friendlyLabel` already
    /// know how to render it.
    static func updateActivityMode(
        in database: SQLCipherDatabase,
        eventID: UUID,
        mode: String
    ) throws {
        let stmt = try database.prepare("UPDATE activities SET mode = ? WHERE event_id = ?;")
        defer { stmt.finalize() }
        try stmt.bind(1, text: mode)
        try stmt.bind(2, text: eventID.uuidString)
        try stmt.stepDone()
    }

    /// Inserts or updates the row in `places` for this `placeID`. `resolved_at` is set to now.
    static func upsertPlace(
        in database: SQLCipherDatabase,
        placeID: String,
        coordinate: Coordinate,
        resolvedLabel: String?,
        userLabel: String? = nil,
        resolvedAt: Date = Date()
    ) throws {
        let stmt = try database.prepare("""
            INSERT INTO places (place_id, user_label, resolved_label, resolved_at, lat, lon)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(place_id) DO UPDATE SET
                resolved_label = COALESCE(excluded.resolved_label, places.resolved_label),
                resolved_at    = excluded.resolved_at,
                user_label     = COALESCE(excluded.user_label, places.user_label),
                lat            = excluded.lat,
                lon            = excluded.lon;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: placeID)
        if let userLabel { try stmt.bind(2, text: userLabel) } else { try stmt.bindNull(2) }
        if let resolvedLabel { try stmt.bind(3, text: resolvedLabel) } else { try stmt.bindNull(3) }
        try stmt.bind(4, int64: Int64(resolvedAt.timeIntervalSince1970))
        try stmt.bind(5, double: coordinate.latitude)
        try stmt.bind(6, double: coordinate.longitude)
        try stmt.stepDone()
    }

    // MARK: - Visit history (place detail)

    static func fetchVisitHistory(
        in database: SQLCipherDatabase,
        placeID: String,
        limit: Int = 200
    ) throws -> [VisitHistoryItem] {
        let stmt = try database.prepare("""
            SELECT
                e.id,
                e.start_ts, e.start_tz_offset_min,
                e.end_ts,   e.end_tz_offset_min,
                v.semantic_type, v.probability
            FROM visits v
            JOIN events e ON e.id = v.event_id
            WHERE v.place_id = ? AND e.is_superseded = 0
            ORDER BY e.start_ts DESC
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: placeID)
        try stmt.bind(2, int: limit)

        var items: [VisitHistoryItem] = []
        while try stmt.step() == .row {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString) else { continue }
            let start = TimestampedLocal(
                date: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(1))),
                tzOffsetMinutes: stmt.columnInt(2)
            )
            let end = TimestampedLocal(
                date: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(3))),
                tzOffsetMinutes: stmt.columnInt(4)
            )
            items.append(VisitHistoryItem(
                id: id,
                start: start,
                end: end,
                semanticType: stmt.columnText(5) ?? "Unknown",
                probability: stmt.columnDouble(6)
            ))
        }
        return items
    }

    // MARK: - Trips (activity polylines)

    static func fetchRecentTrips(in database: SQLCipherDatabase, limit: Int = 200) throws -> [TripSummary] {
        let stmt = try database.prepare("""
            SELECT
                e.id,
                e.start_ts, e.start_tz_offset_min,
                e.end_ts,   e.end_tz_offset_min,
                a.start_lat, a.start_lon, a.end_lat, a.end_lon,
                a.distance_m, a.mode
            FROM activities a
            JOIN events e ON e.id = a.event_id
            WHERE e.is_superseded = 0
            ORDER BY e.start_ts DESC
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int: limit)

        var trips: [TripSummary] = []
        while try stmt.step() == .row {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString) else { continue }
            trips.append(TripSummary(
                id: id,
                start: TimestampedLocal(
                    date: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(1))),
                    tzOffsetMinutes: stmt.columnInt(2)
                ),
                end: TimestampedLocal(
                    date: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(3))),
                    tzOffsetMinutes: stmt.columnInt(4)
                ),
                startCoordinate: Coordinate(latitude: stmt.columnDouble(5), longitude: stmt.columnDouble(6)),
                endCoordinate: Coordinate(latitude: stmt.columnDouble(7), longitude: stmt.columnDouble(8)),
                distanceMeters: stmt.columnDouble(9),
                mode: stmt.columnText(10) ?? ""
            ))
        }
        return trips
    }

    /// Returns the path point coordinates for an event, in sequence order.
    static func fetchPathPoints(in database: SQLCipherDatabase, eventID: UUID) throws -> [Coordinate] {
        let stmt = try database.prepare("""
            SELECT lat, lon
            FROM path_points
            WHERE event_id = ?
            ORDER BY seq ASC;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: eventID.uuidString)

        var points: [Coordinate] = []
        while try stmt.step() == .row {
            points.append(Coordinate(latitude: stmt.columnDouble(0), longitude: stmt.columnDouble(1)))
        }
        return points
    }

    // MARK: - Timeline

    /// Returns recent events of any kind, newest first, joined with whichever payload table applies.
    /// `places.resolved_label` is left-joined for visit entries so the timeline shows a name when we have one.
    static func fetchTimeline(in database: SQLCipherDatabase, limit: Int = 500) throws -> [TimelineEntry] {
        let stmt = try database.prepare("""
            SELECT
                e.id, e.kind,
                e.start_ts, e.start_tz_offset_min,
                e.end_ts,   e.end_tz_offset_min,
                a.distance_m, a.mode,
                v.place_id, v.lat, v.lon, v.semantic_type,
                p.user_label, p.resolved_label,
                (SELECT count(*) FROM path_points pp WHERE pp.event_id = e.id) AS path_count
            FROM events e
            LEFT JOIN activities a ON a.event_id = e.id
            LEFT JOIN visits     v ON v.event_id = e.id
            LEFT JOIN places     p ON p.place_id = v.place_id
            WHERE e.is_superseded = 0
            ORDER BY e.start_ts DESC
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int: limit)

        var entries: [TimelineEntry] = []
        while try stmt.step() == .row {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString),
                  let kind = stmt.columnText(1) else { continue }

            let start = TimestampedLocal(
                date: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(2))),
                tzOffsetMinutes: stmt.columnInt(3)
            )
            let end = TimestampedLocal(
                date: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(4))),
                tzOffsetMinutes: stmt.columnInt(5)
            )

            let detail: TimelineEntry.Detail
            switch kind {
            case "activity":
                detail = .activity(distanceMeters: stmt.columnDouble(6), mode: stmt.columnText(7) ?? "")
            case "visit":
                let placeID = stmt.columnText(8) ?? ""
                let coordinate = Coordinate(latitude: stmt.columnDouble(9), longitude: stmt.columnDouble(10))
                detail = .visit(
                    placeID: placeID,
                    userLabel: stmt.columnText(12),
                    resolvedLabel: stmt.columnText(13),
                    semanticType: stmt.columnText(11) ?? "Unknown",
                    coordinate: coordinate
                )
            case "path":
                detail = .path(pointCount: stmt.columnInt(14))
            default:
                continue
            }

            entries.append(TimelineEntry(id: id, kind: kind, start: start, end: end, detail: detail))
        }
        return entries
    }

    /// Snapshot of geocoding progress. `total` is the count of distinct
    /// `place_id`s across all visit rows; `resolved` is the count that already
    /// have a non-null `resolved_label` in the `places` table. Used by the
    /// Settings UI to display a "how far along is the geocoder" percentage.
    /// Once a place is resolved its row stays in `places` forever — the
    /// geocoder skips it on future runs because `fetchUnresolvedPlaceIDs`
    /// excludes anything with a non-null `resolved_label`.
    static func fetchPlaceResolutionProgress(in database: SQLCipherDatabase) throws -> (total: Int, resolved: Int) {
        let totalStmt = try database.prepare("SELECT COUNT(DISTINCT place_id) FROM visits;")
        defer { totalStmt.finalize() }
        var total: Int32 = 0
        if try totalStmt.step() == .row { total = totalStmt.columnInt32(0) }

        let resolvedStmt = try database.prepare("""
            SELECT COUNT(DISTINCT v.place_id)
            FROM visits v
            INNER JOIN places p ON p.place_id = v.place_id
            WHERE p.resolved_label IS NOT NULL;
        """)
        defer { resolvedStmt.finalize() }
        var resolved: Int32 = 0
        if try resolvedStmt.step() == .row { resolved = resolvedStmt.columnInt32(0) }

        return (total: Int(total), resolved: Int(resolved))
    }

    /// Place IDs that don't yet have a resolved label. Used by the geocoding service to drive its queue.
    static func fetchUnresolvedPlaceIDs(in database: SQLCipherDatabase, limit: Int = 500) throws -> [String] {
        let stmt = try database.prepare("""
            SELECT DISTINCT v.place_id
            FROM visits v
            LEFT JOIN places p ON p.place_id = v.place_id
            WHERE p.resolved_label IS NULL
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int: limit)

        var ids: [String] = []
        while try stmt.step() == .row {
            if let id = stmt.columnText(0) { ids.append(id) }
        }
        return ids
    }

    /// Returns one representative coordinate per place_id, used by the geocoder.
    static func fetchPlaceCoordinates(
        in database: SQLCipherDatabase,
        placeIDs: [String]
    ) throws -> [String: Coordinate] {
        guard !placeIDs.isEmpty else { return [:] }
        // Build a parameterized IN clause.
        let placeholders = Array(repeating: "?", count: placeIDs.count).joined(separator: ", ")
        let stmt = try database.prepare("""
            SELECT v.place_id, v.lat, v.lon
            FROM visits v
            WHERE v.place_id IN (\(placeholders))
            GROUP BY v.place_id;
        """)
        defer { stmt.finalize() }
        for (index, id) in placeIDs.enumerated() {
            try stmt.bind(Int32(index + 1), text: id)
        }
        var result: [String: Coordinate] = [:]
        while try stmt.step() == .row {
            guard let id = stmt.columnText(0) else { continue }
            result[id] = Coordinate(latitude: stmt.columnDouble(1), longitude: stmt.columnDouble(2))
        }
        return result
    }
}
