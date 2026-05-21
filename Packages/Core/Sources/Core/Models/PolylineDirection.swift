import Foundation

/// One direction-of-travel marker we'll place along a polyline on the map.
/// SwiftUI rotates the chevron by `bearingDegrees` so the symbol points the way the user moved.
public struct DirectionMarker: Hashable, Sendable, Identifiable {
    public let id: String
    public let coordinate: Coordinate
    /// Compass bearing in degrees from north, clockwise (0 = north, 90 = east).
    public let bearingDegrees: Double

    public init(id: String, coordinate: Coordinate, bearingDegrees: Double) {
        self.id = id
        self.coordinate = coordinate
        self.bearingDegrees = bearingDegrees
    }
}

/// Pure geometry helper: samples a polyline at evenly-distributed positions and computes
/// the local direction of travel at each, returning lightweight markers we can use to
/// draw "way indicator" chevrons on the map.
public enum PolylineDirection {
    public static let earthRadiusMeters: Double = 6_371_000

    /// Returns up to `maxMarkers` direction markers evenly spaced along the polyline.
    ///
    /// - Skips polylines shorter than `minimumTotalMeters` (no point sprinkling arrows on a
    ///   line you can barely see).
    /// - Scales the marker count with the line's length so a 100 m walk gets 1–2 arrows and
    ///   a 100 km train ride gets the cap.
    public static func markers(
        for coordinates: [Coordinate],
        polylineID: String,
        maxMarkers: Int = 6,
        minimumTotalMeters: Double = 250
    ) -> [DirectionMarker] {
        guard coordinates.count >= 2 else { return [] }

        // Cumulative distances along the polyline.
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(coordinates.count)
        for index in 1 ..< coordinates.count {
            let distance = haversineMeters(coordinates[index - 1], coordinates[index])
            cumulative.append(cumulative[index - 1] + distance)
        }
        let totalLength = cumulative.last ?? 0
        guard totalLength >= minimumTotalMeters else { return [] }

        // Pick marker count: ~1 per km, capped between 1 and maxMarkers.
        let approximate = Int((totalLength / 1_000).rounded(.up))
        let count = max(1, min(maxMarkers, approximate))

        // Place markers at evenly-spaced positions in (0, totalLength), skipping the very
        // start and end so they don't crowd the line endpoints.
        let step = totalLength / Double(count + 1)
        var markers: [DirectionMarker] = []
        markers.reserveCapacity(count)
        for slot in 1 ... count {
            let targetDistance = step * Double(slot)
            guard let placement = interpolate(
                target: targetDistance,
                cumulative: cumulative,
                coordinates: coordinates
            ) else { continue }
            markers.append(DirectionMarker(
                id: "\(polylineID)-arrow-\(slot)",
                coordinate: placement.coordinate,
                bearingDegrees: placement.bearing
            ))
        }
        return markers
    }

    // MARK: - Internals

    private struct Placement {
        let coordinate: Coordinate
        let bearing: Double
    }

    /// Finds the line segment containing `target` meters from the start, interpolates the
    /// coordinate, and returns the bearing from that segment's endpoints.
    private static func interpolate(
        target: Double,
        cumulative: [Double],
        coordinates: [Coordinate]
    ) -> Placement? {
        guard let segmentEnd = cumulative.firstIndex(where: { $0 >= target }),
              segmentEnd > 0
        else {
            return nil
        }
        let segmentStart = segmentEnd - 1
        let startCoord = coordinates[segmentStart]
        let endCoord = coordinates[segmentEnd]
        let segmentLength = cumulative[segmentEnd] - cumulative[segmentStart]
        let fraction = segmentLength > 0
            ? (target - cumulative[segmentStart]) / segmentLength
            : 0

        let coord = Coordinate(
            latitude: startCoord.latitude + (endCoord.latitude - startCoord.latitude) * fraction,
            longitude: startCoord.longitude + (endCoord.longitude - startCoord.longitude) * fraction
        )
        let bearing = bearingDegrees(from: startCoord, to: endCoord)
        return Placement(coordinate: coord, bearing: bearing)
    }

    /// Great-circle distance in meters using the haversine formula.
    public static func haversineMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let sinHalfDLat = sin(dLat / 2)
        let sinHalfDLon = sin(dLon / 2)
        let central = sinHalfDLat * sinHalfDLat
            + cos(lat1) * cos(lat2) * sinHalfDLon * sinHalfDLon
        let angular = 2 * atan2(sqrt(central), sqrt(1 - central))
        return earthRadiusMeters * angular
    }

    /// Initial bearing from `a` to `b`, in degrees clockwise from north (0–360).
    public static func bearingDegrees(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let yComponent = sin(dLon) * cos(lat2)
        let xComponent = cos(lat1) * sin(lat2)
            - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(yComponent, xComponent)
        let degrees = radians * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
