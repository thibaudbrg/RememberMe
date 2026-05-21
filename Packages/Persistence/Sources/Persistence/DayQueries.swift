import Core
import Foundation

/// A continuous GPS breadcrumb segment, used to draw colored traces on the map for a given day.
public struct PathTrace: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let start: TimestampedLocal
    public let end: TimestampedLocal
    /// GPS samples with their real `offsetMinutes` from `start`. We need the offset (not just
    /// an even-distribution guess) to correctly slice samples into each overlapping activity's
    /// time window — otherwise short activities pick up stray samples from elsewhere along
    /// the path and the rendered polyline jumps across the map.
    public let samples: [PathPoint]

    public init(id: UUID, start: TimestampedLocal, end: TimestampedLocal, samples: [PathPoint]) {
        self.id = id
        self.start = start
        self.end = end
        self.samples = samples
    }

    /// Convenience: the bare coordinates in order. Used by callers that don't need timestamps.
    public var points: [Coordinate] { samples.map(\.coordinate) }
}

/// Aggregate per-day stats shown as chips at the top of the timeline. One row per `mode`
/// (walking, cycling, driving, train, …) plus a separate visit count.
public struct DaySummary: Hashable, Sendable {
    /// Breakdown of activities by transport mode for the day. Empty when the day has no trips.
    public let activitySummaries: [ActivityModeSummary]
    public let visitCount: Int

    public init(activitySummaries: [ActivityModeSummary], visitCount: Int) {
        self.activitySummaries = activitySummaries
        self.visitCount = visitCount
    }

    public static let empty = Self(activitySummaries: [], visitCount: 0)

    // Convenience totals — kept so existing callers (tests, older UI code) don't have to roll
    // their own sums.
    public var activityCount: Int { activitySummaries.reduce(0) { $0 + $1.count } }
    public var totalDistanceMeters: Double { activitySummaries.reduce(0) { $0 + $1.distanceMeters } }
    public var activityDuration: TimeInterval { activitySummaries.reduce(0) { $0 + $1.durationSeconds } }
}

/// One row of the per-day activity breakdown — all trips of a given mode rolled up.
public struct ActivityModeSummary: Hashable, Sendable, Identifiable {
    public var id: String { mode }

    public let mode: String
    public let distanceMeters: Double
    public let durationSeconds: TimeInterval
    public let count: Int

    public init(mode: String, distanceMeters: Double, durationSeconds: TimeInterval, count: Int) {
        self.mode = mode
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.count = count
    }
}

public extension Persistence {
    // MARK: - Day-bounded variants of the existing queries

    static func fetchVisitMarkers(
        in database: SQLCipherDatabase,
        dayRange: Range<Date>,
        limit: Int = 5000
    ) throws -> [VisitMarker] {
        let (start, end) = epochs(dayRange)
        let stmt = try database.prepare("""
            SELECT
                v.place_id, v.lat, v.lon,
                MAX(e.start_ts) AS most_recent,
                COUNT(*) AS visit_count,
                p.user_label,
                p.resolved_label
            FROM visits v
            JOIN events e ON e.id = v.event_id
            LEFT JOIN places p ON p.place_id = v.place_id
            WHERE e.start_ts >= ? AND e.start_ts < ?
            GROUP BY v.place_id
            ORDER BY most_recent DESC
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int64: start)
        try stmt.bind(2, int64: end)
        try stmt.bind(3, int: limit)

        var markers: [VisitMarker] = []
        while stmt.step() == .row {
            guard let placeID = stmt.columnText(0) else { continue }
            markers.append(VisitMarker(
                placeID: placeID,
                coordinate: Coordinate(latitude: stmt.columnDouble(1), longitude: stmt.columnDouble(2)),
                mostRecentVisit: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(3))),
                visitCount: stmt.columnInt(4),
                userLabel: stmt.columnText(5),
                resolvedLabel: stmt.columnText(6)
            ))
        }
        return markers
    }

    static func fetchTrips(
        in database: SQLCipherDatabase,
        dayRange: Range<Date>,
        limit: Int = 500
    ) throws -> [TripSummary] {
        let (start, end) = epochs(dayRange)
        let stmt = try database.prepare("""
            SELECT
                e.id, e.start_ts, e.start_tz_offset_min, e.end_ts, e.end_tz_offset_min,
                a.start_lat, a.start_lon, a.end_lat, a.end_lon, a.distance_m, a.mode
            FROM activities a
            JOIN events e ON e.id = a.event_id
            WHERE e.start_ts >= ? AND e.start_ts < ?
            ORDER BY e.start_ts DESC
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int64: start)
        try stmt.bind(2, int64: end)
        try stmt.bind(3, int: limit)

        var trips: [TripSummary] = []
        while stmt.step() == .row {
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

    static func fetchTimeline(
        in database: SQLCipherDatabase,
        dayRange: Range<Date>,
        limit: Int = 1000
    ) throws -> [TimelineEntry] {
        let (start, end) = epochs(dayRange)
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
            WHERE e.start_ts >= ? AND e.start_ts < ?
            ORDER BY e.start_ts ASC
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int64: start)
        try stmt.bind(2, int64: end)
        try stmt.bind(3, int: limit)

        var entries: [TimelineEntry] = []
        while stmt.step() == .row {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString),
                  let kind = stmt.columnText(1) else { continue }

            let startTs = TimestampedLocal(
                date: Date(timeIntervalSince1970: TimeInterval(stmt.columnInt64(2))),
                tzOffsetMinutes: stmt.columnInt(3)
            )
            let endTs = TimestampedLocal(
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

            entries.append(TimelineEntry(id: id, kind: kind, start: startTs, end: endTs, detail: detail))
        }
        return entries
    }

    /// Returns a `PathTrace` for every `path` event in the day range, each carrying its full
    /// point sequence in order. Used to overlay colored GPS breadcrumbs on the map.
    static func fetchPathTraces(
        in database: SQLCipherDatabase,
        dayRange: Range<Date>,
        limit: Int = 200
    ) throws -> [PathTrace] {
        let (start, end) = epochs(dayRange)
        let pathEventsStmt = try database.prepare("""
            SELECT id, start_ts, start_tz_offset_min, end_ts, end_tz_offset_min
            FROM events
            WHERE kind = 'path'
              AND start_ts >= ? AND start_ts < ?
            ORDER BY start_ts ASC
            LIMIT ?;
        """)
        defer { pathEventsStmt.finalize() }
        try pathEventsStmt.bind(1, int64: start)
        try pathEventsStmt.bind(2, int64: end)
        try pathEventsStmt.bind(3, int: limit)

        struct Header { let id: UUID
            let start: TimestampedLocal
            let end: TimestampedLocal
        }
        var headers: [Header] = []
        while pathEventsStmt.step() == .row {
            guard let idString = pathEventsStmt.columnText(0),
                  let id = UUID(uuidString: idString) else { continue }
            headers.append(Header(
                id: id,
                start: TimestampedLocal(
                    date: Date(timeIntervalSince1970: TimeInterval(pathEventsStmt.columnInt64(1))),
                    tzOffsetMinutes: pathEventsStmt.columnInt(2)
                ),
                end: TimestampedLocal(
                    date: Date(timeIntervalSince1970: TimeInterval(pathEventsStmt.columnInt64(3))),
                    tzOffsetMinutes: pathEventsStmt.columnInt(4)
                )
            ))
        }
        guard !headers.isEmpty else { return [] }

        // One reusable prepared statement to fetch samples (coord + offset_min) per event.
        let pointsStmt = try database.prepare("""
            SELECT lat, lon, offset_min FROM path_points
            WHERE event_id = ?
            ORDER BY seq ASC;
        """)
        defer { pointsStmt.finalize() }

        var traces: [PathTrace] = []
        for header in headers {
            try pointsStmt.reset()
            try pointsStmt.clearBindings()
            try pointsStmt.bind(1, text: header.id.uuidString)

            var samples: [PathPoint] = []
            while pointsStmt.step() == .row {
                samples.append(PathPoint(
                    coordinate: Coordinate(
                        latitude: pointsStmt.columnDouble(0),
                        longitude: pointsStmt.columnDouble(1)
                    ),
                    offsetMinutes: pointsStmt.columnInt(2)
                ))
            }
            if !samples.isEmpty {
                traces.append(PathTrace(id: header.id, start: header.start, end: header.end, samples: samples))
            }
        }
        return traces
    }

    static func fetchDaySummary(in database: SQLCipherDatabase, dayRange: Range<Date>) throws -> DaySummary {
        let (start, end) = epochs(dayRange)

        // Visit count — single scalar.
        let visitStmt = try database.prepare("""
            SELECT count(*) FROM visits v
            JOIN events e ON e.id = v.event_id
            WHERE e.start_ts >= ? AND e.start_ts < ?;
        """)
        defer { visitStmt.finalize() }
        try visitStmt.bind(1, int64: start)
        try visitStmt.bind(2, int64: end)
        let visitCount: Int = visitStmt.step() == .row ? visitStmt.columnInt(0) : 0

        // Activity breakdown by mode.
        let activityStmt = try database.prepare("""
            SELECT
                a.mode,
                SUM(a.distance_m) AS total_distance,
                SUM(e.end_ts - e.start_ts) AS total_duration,
                COUNT(*) AS count
            FROM activities a
            JOIN events e ON e.id = a.event_id
            WHERE e.start_ts >= ? AND e.start_ts < ?
            GROUP BY a.mode
            ORDER BY total_distance DESC;
        """)
        defer { activityStmt.finalize() }
        try activityStmt.bind(1, int64: start)
        try activityStmt.bind(2, int64: end)

        var modes: [ActivityModeSummary] = []
        while activityStmt.step() == .row {
            let mode = activityStmt.columnText(0) ?? ""
            modes.append(ActivityModeSummary(
                mode: mode,
                distanceMeters: activityStmt.columnDouble(1),
                durationSeconds: TimeInterval(activityStmt.columnInt64(2)),
                count: activityStmt.columnInt(3)
            ))
        }

        return DaySummary(activitySummaries: modes, visitCount: visitCount)
    }

    /// Returns the start-of-day (in the device's local timezone) for every day that has at least one event.
    /// Used by the calendar UI to mark days with data, and to pick a sensible default day on first launch.
    static func fetchDaysWithData(in database: SQLCipherDatabase) throws -> [Date] {
        let stmt = try database.prepare("""
            SELECT DISTINCT date(start_ts, 'unixepoch', 'localtime') AS day
            FROM events
            ORDER BY day DESC;
        """)
        defer { stmt.finalize() }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone.current

        var days: [Date] = []
        while stmt.step() == .row {
            guard let dateString = stmt.columnText(0) else { continue }
            // SQLite returns "YYYY-MM-DD"; we interpret it at local midnight.
            if let parsed = parseLocalMidnight(dateString) {
                days.append(parsed)
            }
        }
        return days
    }

    // MARK: - Helpers

    private static func epochs(_ dayRange: Range<Date>) -> (start: Int64, end: Int64) {
        (
            Int64(dayRange.lowerBound.timeIntervalSince1970),
            Int64(dayRange.upperBound.timeIntervalSince1970)
        )
    }

    private static func parseLocalMidnight(_ yyyymmdd: String) -> Date? {
        let components = yyyymmdd.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else { return nil }
        var dateComponents = DateComponents()
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        dateComponents.timeZone = TimeZone.current
        return Calendar.current.date(from: dateComponents)
    }
}
