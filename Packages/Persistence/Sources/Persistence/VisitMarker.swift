import Core
import Foundation

/// A point of interest to show on the map: one row per unique `place_id`, located at
/// the visit's coordinate, tagged with when the user was last there.
public struct VisitMarker: Hashable, Sendable, Identifiable {
    public var id: String { placeID }

    public let placeID: String
    public let coordinate: Coordinate
    public let mostRecentVisit: Date
    public let visitCount: Int

    public init(placeID: String, coordinate: Coordinate, mostRecentVisit: Date, visitCount: Int) {
        self.placeID = placeID
        self.coordinate = coordinate
        self.mostRecentVisit = mostRecentVisit
        self.visitCount = visitCount
    }
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
                COUNT(*)               AS visit_count
            FROM visits v
            JOIN events e ON e.id = v.event_id
            GROUP BY v.place_id
            ORDER BY most_recent DESC
            LIMIT ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, int: limit)

        var markers: [VisitMarker] = []
        while stmt.step() == .row {
            guard let placeID = stmt.columnText(0) else { continue }
            let lat = stmt.columnDouble(1)
            let lon = stmt.columnDouble(2)
            let mostRecentEpoch = stmt.columnInt64(3)
            let visitCount = stmt.columnInt(4)
            markers.append(VisitMarker(
                placeID: placeID,
                coordinate: Coordinate(latitude: lat, longitude: lon),
                mostRecentVisit: Date(timeIntervalSince1970: TimeInterval(mostRecentEpoch)),
                visitCount: visitCount
            ))
        }
        return markers
    }
}
