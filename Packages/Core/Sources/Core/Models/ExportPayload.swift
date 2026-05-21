import Foundation

/// JSON payload sealed inside an `RMEX` envelope. Mirrors the SQLite schema with a tiny
/// metadata wrapper so future versions can diverge without breaking decoders.
///
/// Format reference: `docs/data-formats/rememberme-export-v1.md`.
public struct ExportPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let exportedAt: Date
    public let events: [ExportedEvent]
    public let places: [ExportedPlace]

    public init(version: Int = 1, exportedAt: Date, events: [ExportedEvent], places: [ExportedPlace]) {
        self.version = version
        self.exportedAt = exportedAt
        self.events = events
        self.places = places
    }

    enum CodingKeys: String, CodingKey {
        case version
        case exportedAt = "exported_at"
        case events
        case places
    }
}

/// One row from the `events` table, plus the kind-specific child row inlined.
public struct ExportedEvent: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String                 // "activity" | "visit" | "path"
    public let startTs: Int64
    public let startTzOffsetMin: Int
    public let endTs: Int64
    public let endTzOffsetMin: Int
    public let source: String
    public let importedAt: Int64

    public let activity: ExportedActivity?
    public let visit: ExportedVisit?
    public let pathPoints: [ExportedPathPoint]?

    public init(
        id: String,
        kind: String,
        startTs: Int64,
        startTzOffsetMin: Int,
        endTs: Int64,
        endTzOffsetMin: Int,
        source: String,
        importedAt: Int64,
        activity: ExportedActivity? = nil,
        visit: ExportedVisit? = nil,
        pathPoints: [ExportedPathPoint]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startTs = startTs
        self.startTzOffsetMin = startTzOffsetMin
        self.endTs = endTs
        self.endTzOffsetMin = endTzOffsetMin
        self.source = source
        self.importedAt = importedAt
        self.activity = activity
        self.visit = visit
        self.pathPoints = pathPoints
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case startTs = "start_ts"
        case startTzOffsetMin = "start_tz_offset_min"
        case endTs = "end_ts"
        case endTzOffsetMin = "end_tz_offset_min"
        case source
        case importedAt = "imported_at"
        case activity
        case visit
        case pathPoints = "path_points"
    }
}

public struct ExportedActivity: Codable, Equatable, Sendable {
    public let startLat: Double
    public let startLon: Double
    public let endLat: Double
    public let endLon: Double
    public let distanceM: Double
    public let mode: String
    public let probability: Double

    public init(startLat: Double, startLon: Double, endLat: Double, endLon: Double, distanceM: Double, mode: String, probability: Double) {
        self.startLat = startLat
        self.startLon = startLon
        self.endLat = endLat
        self.endLon = endLon
        self.distanceM = distanceM
        self.mode = mode
        self.probability = probability
    }

    enum CodingKeys: String, CodingKey {
        case startLat = "start_lat"
        case startLon = "start_lon"
        case endLat = "end_lat"
        case endLon = "end_lon"
        case distanceM = "distance_m"
        case mode
        case probability
    }
}

public struct ExportedVisit: Codable, Equatable, Sendable {
    public let placeID: String
    public let lat: Double
    public let lon: Double
    public let semanticType: String
    public let hierarchyLevel: Int
    public let probability: Double

    public init(placeID: String, lat: Double, lon: Double, semanticType: String, hierarchyLevel: Int, probability: Double) {
        self.placeID = placeID
        self.lat = lat
        self.lon = lon
        self.semanticType = semanticType
        self.hierarchyLevel = hierarchyLevel
        self.probability = probability
    }

    enum CodingKeys: String, CodingKey {
        case placeID = "place_id"
        case lat
        case lon
        case semanticType = "semantic_type"
        case hierarchyLevel = "hierarchy_level"
        case probability
    }
}

public struct ExportedPathPoint: Codable, Equatable, Sendable {
    public let seq: Int
    public let offsetMin: Int
    public let lat: Double
    public let lon: Double

    public init(seq: Int, offsetMin: Int, lat: Double, lon: Double) {
        self.seq = seq
        self.offsetMin = offsetMin
        self.lat = lat
        self.lon = lon
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case offsetMin = "offset_min"
        case lat
        case lon
    }
}

public struct ExportedPlace: Codable, Equatable, Sendable {
    public let placeID: String
    public let userLabel: String?
    public let resolvedLabel: String?
    public let resolvedAt: Int64?
    public let lat: Double
    public let lon: Double

    public init(placeID: String, userLabel: String?, resolvedLabel: String?, resolvedAt: Int64?, lat: Double, lon: Double) {
        self.placeID = placeID
        self.userLabel = userLabel
        self.resolvedLabel = resolvedLabel
        self.resolvedAt = resolvedAt
        self.lat = lat
        self.lon = lon
    }

    enum CodingKeys: String, CodingKey {
        case placeID = "place_id"
        case userLabel = "user_label"
        case resolvedLabel = "resolved_label"
        case resolvedAt = "resolved_at"
        case lat
        case lon
    }
}
