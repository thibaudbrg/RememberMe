import Core
import Foundation

/// Aggregate stats shown in the Insights drawer tab — computed across ALL imported events
/// (not the selected day).
public struct InsightsSummary: Hashable, Sendable {
    public let totalEvents: Int
    public let dateRange: ClosedRange<Date>?
    public let activitiesByMode: [ActivityModeSummary]
    public let topPlaces: [TopPlace]
    public let busiestDay: BusiestDay?

    public init(
        totalEvents: Int,
        dateRange: ClosedRange<Date>?,
        activitiesByMode: [ActivityModeSummary],
        topPlaces: [TopPlace],
        busiestDay: BusiestDay?
    ) {
        self.totalEvents = totalEvents
        self.dateRange = dateRange
        self.activitiesByMode = activitiesByMode
        self.topPlaces = topPlaces
        self.busiestDay = busiestDay
    }

    public static let empty = Self(
        totalEvents: 0,
        dateRange: nil,
        activitiesByMode: [],
        topPlaces: [],
        busiestDay: nil
    )
}

public struct TopPlace: Hashable, Sendable, Identifiable {
    public var id: String { placeID }
    public let placeID: String
    public let visitCount: Int
    public let userLabel: String?
    public let resolvedLabel: String?

    public var displayLabel: String? { userLabel ?? resolvedLabel }

    public init(placeID: String, visitCount: Int, userLabel: String?, resolvedLabel: String?) {
        self.placeID = placeID
        self.visitCount = visitCount
        self.userLabel = userLabel
        self.resolvedLabel = resolvedLabel
    }
}

public struct BusiestDay: Hashable, Sendable {
    public let day: Date
    public let eventCount: Int

    public init(day: Date, eventCount: Int) {
        self.day = day
        self.eventCount = eventCount
    }
}

public extension Persistence {
    /// Computes the full insights summary in a single grouped fetch pass.
    static func fetchInsights(in database: SQLCipherDatabase, topPlaceLimit: Int = 8) throws -> InsightsSummary {
        let totalEvents = try scalarInt(database, "SELECT count(*) FROM events;")
        let dateRange = try fetchDateRange(in: database)
        let activitiesByMode = try fetchAllActivitiesByMode(in: database)
        let topPlaces = try fetchTopPlaces(in: database, limit: topPlaceLimit)
        let busiestDay = try fetchBusiestDay(in: database)
        return InsightsSummary(
            totalEvents: totalEvents,
            dateRange: dateRange,
            activitiesByMode: activitiesByMode,
            topPlaces: topPlaces,
            busiestDay: busiestDay
        )
    }

    private static func fetchDateRange(in database: SQLCipherDatabase) throws -> ClosedRange<Date>? {
        let stmt = try database.prepare("SELECT MIN(start_ts), MAX(end_ts) FROM events;")
        defer { stmt.finalize() }
        guard stmt.step() == .row else { return nil }
        let minEpoch = stmt.columnInt64(0)
        let maxEpoch = stmt.columnInt64(1)
        guard minEpoch > 0, maxEpoch > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(minEpoch))
            ... Date(timeIntervalSince1970: TimeInterval(maxEpoch))
    }

    private static func fetchAllActivitiesByMode(in database: SQLCipherDatabase) throws -> [ActivityModeSummary] {
        let stmt = try database.prepare("""
            SELECT
                a.mode,
                SUM(a.distance_m) AS total_distance,
                SUM(e.end_ts - e.start_ts) AS total_duration,
                COUNT(*) AS count
            FROM activities a
            JOIN events e ON e.id = a.event_id
            GROUP BY a.mode
            ORDER BY total_distance DESC;
        """)
        defer { stmt.finalize() }
        var modes: [ActivityModeSummary] = []
        while stmt.step() == .row {
            modes.append(ActivityModeSummary(
                mode: stmt.columnText(0) ?? "",
                distanceMeters: stmt.columnDouble(1),
                durationSeconds: TimeInterval(stmt.columnInt64(2)),
                count: stmt.columnInt(3)
            ))
        }
        return modes
    }

    private static func fetchTopPlaces(in database: SQLCipherDatabase, limit: Int) throws -> [TopPlace] {
        let stmt = try database.prepare("""
            SELECT
                v.place_id,
                COUNT(*) AS visit_count,
                p.user_label,
                p.resolved_label
            FROM visits v
            LEFT JOIN places p ON p.place_id = v.place_id
            GROUP BY v.place_id
            ORDER BY visit_count DESC
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int: limit)
        var output: [TopPlace] = []
        while stmt.step() == .row {
            guard let placeID = stmt.columnText(0) else { continue }
            output.append(TopPlace(
                placeID: placeID,
                visitCount: stmt.columnInt(1),
                userLabel: stmt.columnText(2),
                resolvedLabel: stmt.columnText(3)
            ))
        }
        return output
    }

    private static func fetchBusiestDay(in database: SQLCipherDatabase) throws -> BusiestDay? {
        let stmt = try database.prepare("""
            SELECT
                date(start_ts, 'unixepoch', 'localtime') AS day,
                COUNT(*) AS cnt
            FROM events
            GROUP BY day
            ORDER BY cnt DESC
            LIMIT 1;
        """)
        defer { stmt.finalize() }
        guard stmt.step() == .row,
              let dayString = stmt.columnText(0) else { return nil }
        let count = stmt.columnInt(1)

        let components = dayString.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else { return nil }
        var dateComponents = DateComponents()
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        dateComponents.timeZone = TimeZone.current
        guard let date = Calendar.current.date(from: dateComponents) else { return nil }
        return BusiestDay(day: date, eventCount: count)
    }

    private static func scalarInt(_ database: SQLCipherDatabase, _ sql: String) throws -> Int {
        let stmt = try database.prepare(sql)
        defer { stmt.finalize() }
        return stmt.step() == .row ? stmt.columnInt(0) : 0
    }
}
