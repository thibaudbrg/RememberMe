import Foundation

/// A place the user has visited, identified by its source-specific id.
/// The user may set their own label; the reverse-geocoded label is optionally cached.
public struct Place: Hashable, Sendable, Codable, Identifiable {
    public var id: String {
        placeID
    }

    public let placeID: String
    public var userLabel: String?
    public var resolvedLabel: String?
    public var resolvedAt: Date?
    public let coordinate: Coordinate

    public init(
        placeID: String,
        userLabel: String? = nil,
        resolvedLabel: String? = nil,
        resolvedAt: Date? = nil,
        coordinate: Coordinate
    ) {
        self.placeID = placeID
        self.userLabel = userLabel
        self.resolvedLabel = resolvedLabel
        self.resolvedAt = resolvedAt
        self.coordinate = coordinate
    }
}
