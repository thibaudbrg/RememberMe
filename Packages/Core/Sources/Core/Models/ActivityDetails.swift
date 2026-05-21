import Foundation

public struct ActivityDetails: Hashable, Sendable, Codable {
    public let start: Coordinate
    public let end: Coordinate
    public let distanceMeters: Double
    /// Free-form transport mode string from the source (e.g. `"walking"`, `"in passenger vehicle"`).
    public let mode: String
    /// Confidence the source assigns to the chosen `mode`, in `[0, 1]`. Often `0` in Google Takeout.
    public let probability: Double

    public init(start: Coordinate, end: Coordinate, distanceMeters: Double, mode: String, probability: Double) {
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        self.mode = mode
        self.probability = probability
    }
}
