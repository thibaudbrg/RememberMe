import Foundation

public struct PathPoint: Hashable, Sendable, Codable {
    public let coordinate: Coordinate
    /// Minutes elapsed since the parent event's `start`.
    public let offsetMinutes: Int

    public init(coordinate: Coordinate, offsetMinutes: Int) {
        self.coordinate = coordinate
        self.offsetMinutes = offsetMinutes
    }
}
