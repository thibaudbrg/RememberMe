import Foundation

public struct Coordinate: Hashable, Sendable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public extension Coordinate {
    /// Parse a Google Takeout-style `"geo:lat,lon"` URI.
    /// Returns `nil` on any malformed input — the caller decides how to handle skipped records.
    static func parse(geoURI: String) -> Coordinate? {
        guard geoURI.hasPrefix("geo:") else { return nil }
        let body = geoURI.dropFirst(4)
        let parts = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lat = Double(parts[0]),
              let lon = Double(parts[1]),
              lat.isFinite, lon.isFinite,
              (-90 ... 90).contains(lat),
              (-180 ... 180).contains(lon)
        else {
            return nil
        }
        return Coordinate(latitude: lat, longitude: lon)
    }
}
