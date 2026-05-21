import Foundation

public struct VisitDetails: Hashable, Sendable, Codable {
    /// Source-specific place identifier (Google `placeID` in the Takeout case). Stored as-is.
    public let placeID: String
    public let location: Coordinate
    /// Source-specific semantic label (e.g. `"Home"`, `"Work"`, `"Unknown"`).
    public let semanticType: String
    public let hierarchyLevel: Int
    public let probability: Double

    public init(
        placeID: String,
        location: Coordinate,
        semanticType: String,
        hierarchyLevel: Int,
        probability: Double
    ) {
        self.placeID = placeID
        self.location = location
        self.semanticType = semanticType
        self.hierarchyLevel = hierarchyLevel
        self.probability = probability
    }
}
