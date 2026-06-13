import Core
import Foundation

/// A point of interest to show on the map: one row per unique `place_id`, located at
/// the visit's coordinate, tagged with when the user was last there.
public struct VisitMarker: Hashable, Sendable, Identifiable {
    public var id: String {
        placeID
    }

    public let placeID: String
    public let coordinate: Coordinate
    public let mostRecentVisit: Date
    public let visitCount: Int
    /// User-chosen name for this place (e.g. "Home", "Mum's"). Takes precedence over `resolvedLabel`.
    public let userLabel: String?
    /// Cached label from `places.resolved_label`, or nil if geocoding hasn't run yet.
    public let resolvedLabel: String?

    public init(
        placeID: String,
        coordinate: Coordinate,
        mostRecentVisit: Date,
        visitCount: Int,
        userLabel: String? = nil,
        resolvedLabel: String? = nil
    ) {
        self.placeID = placeID
        self.coordinate = coordinate
        self.mostRecentVisit = mostRecentVisit
        self.visitCount = visitCount
        self.userLabel = userLabel
        self.resolvedLabel = resolvedLabel
    }

    /// Best name to show — user-chosen wins, then geocoded, then nil (caller decides fallback).
    public var displayLabel: String? { userLabel ?? resolvedLabel }
}

public extension Persistence {
    /// Returns at most `limit` unique-by-place visit markers, ordered by most recent visit first.
    /// Uses the visit's stored coordinate (we take the latest visit's lat/lon when a place appears
    /// at slightly different coordinates across visits — Google rounds these inconsistently).
    static func fetchVisitMarkers(in database: SQLCipherDatabase, limit: Int = 5000) throws -> [VisitMarker] {
        let stmt = try database.prepare("""
            SELECT
                v.place_id,
                v.lat,
                v.lon,
                MAX(e.start_ts)        AS most_recent,
                COUNT(*)               AS visit_count,
                p.user_label,
                p.resolved_label
            FROM visits v
            JOIN events e ON e.id = v.event_id
            LEFT JOIN places p ON p.place_id = v.place_id
            WHERE e.is_superseded = 0
            GROUP BY v.place_id
            ORDER BY most_recent DESC
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int: limit)

        var markers: [VisitMarker] = []
        while try stmt.step() == .row {
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
}
