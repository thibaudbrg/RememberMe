import Foundation

/// One leg of a multi-modal route. A pure walking or driving route produces a single
/// segment; a Google transit route may produce many (walk → bus → walk → subway → walk).
public struct RouteSegment: Hashable, Sendable {
    public let mode: RefinementMode
    /// Granular mode string suitable for the `activities.mode` column ("bus", "train",
    /// "subway", "walking", "driving", "cycling", "tram", "ferry", "cable car"). Falls
    /// back to the coarse mode's rawValue when the routing source doesn't expose finer
    /// detail (e.g. Apple Maps always emits the coarse value).
    public let displayMode: String
    public let coordinates: [Coordinate]
    public let travelTime: TimeInterval?
    public let distanceMeters: Double?
    /// Human-readable description ("Bus 38", "Line 14", "Walk"). Optional — currently
    /// unused by the persistence layer (granular `displayMode` covers the timeline icon
    /// + label), but kept so the routing layer can surface line names in future UI.
    public let label: String?

    public init(
        mode: RefinementMode,
        displayMode: String? = nil,
        coordinates: [Coordinate],
        travelTime: TimeInterval?,
        distanceMeters: Double?,
        label: String?
    ) {
        self.mode = mode
        self.displayMode = displayMode ?? mode.rawValue
        self.coordinates = coordinates
        self.travelTime = travelTime
        self.distanceMeters = distanceMeters
        self.label = label
    }
}

/// A single route returned by the routing source (Apple Maps or Google Directions).
/// Plain DTO so it can be passed across actors and stored in @Observable state without
/// pulling MapKit into the Core package.
public struct RouteCandidate: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Concatenated polyline for the entire route. Convenience for callers that just
    /// want one line to draw — for multi-modal routes use `segments` to render each
    /// leg with its own style.
    public let coordinates: [Coordinate]
    public let expectedTravelTime: TimeInterval?
    public let expectedDistanceMeters: Double?
    public let name: String?
    public let advisoryNotices: [String]
    /// Coarse mode of the whole route. For multi-modal routes this is the "primary"
    /// mode (typically the longest leg by duration); use `segments` for the breakdown.
    public let transportType: RefinementMode
    /// Per-leg breakdown. Always has at least one entry; for single-mode routes the
    /// single segment covers the whole `coordinates` polyline.
    public let segments: [RouteSegment]

    public init(
        id: UUID = UUID(),
        coordinates: [Coordinate],
        expectedTravelTime: TimeInterval?,
        expectedDistanceMeters: Double?,
        name: String?,
        advisoryNotices: [String],
        transportType: RefinementMode,
        segments: [RouteSegment]
    ) {
        self.id = id
        self.coordinates = coordinates
        self.expectedTravelTime = expectedTravelTime
        self.expectedDistanceMeters = expectedDistanceMeters
        self.name = name
        self.advisoryNotices = advisoryNotices
        self.transportType = transportType
        self.segments = segments
    }

    /// True when this candidate decomposes into more than one leg with distinct modes.
    public var isMultiModal: Bool {
        guard segments.count > 1 else { return false }
        let firstMode = segments[0].mode
        return segments.dropFirst().contains { $0.mode != firstMode }
    }
}
