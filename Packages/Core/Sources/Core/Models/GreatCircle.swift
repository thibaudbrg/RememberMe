import Foundation

/// Spherical math used to draw curved flight paths that follow the Earth's actual shortest path
/// between two coordinates (a great-circle arc) instead of a straight Mercator line.
public enum GreatCircle {
    /// Returns `steps + 1` coordinates that walk a great-circle arc from `start` to `end`,
    /// inclusive on both ends. `steps` controls smoothness — 32 looks good at typical zooms.
    ///
    /// For very close points (where the arc is indistinguishable from a straight line) the
    /// function bails out and just returns `[start, end]` — no point oversampling pixels.
    public static func arc(from start: Coordinate, to end: Coordinate, steps: Int = 32) -> [Coordinate] {
        precondition(steps >= 1, "GreatCircle.arc requires at least 1 step")

        let lat1 = start.latitude.degreesToRadians
        let lon1 = start.longitude.degreesToRadians
        let lat2 = end.latitude.degreesToRadians
        let lon2 = end.longitude.degreesToRadians

        // Central angle between the two points (haversine variant).
        let sinHalfDLat = sin((lat2 - lat1) / 2)
        let sinHalfDLon = sin((lon2 - lon1) / 2)
        let haversine = sinHalfDLat * sinHalfDLat
            + cos(lat1) * cos(lat2) * sinHalfDLon * sinHalfDLon
        let centralAngle = 2 * asin(min(1, sqrt(haversine)))

        // Below ~25 km, the curvature is invisible at any sane zoom — straight line.
        if centralAngle < 0.004 {
            // Keep the end continuous with the start across the dateline so MapPolyline
            // doesn't draw a world-spanning line when start/end straddle ±180°.
            return [start, Coordinate(latitude: end.latitude, longitude: unwrap(end.longitude, against: start.longitude))]
        }

        let sinAngle = sin(centralAngle)
        var coordinates: [Coordinate] = []
        coordinates.reserveCapacity(steps + 1)

        for index in 0 ... steps {
            let fraction = Double(index) / Double(steps)
            // Slerp weights.
            let weightA = sin((1 - fraction) * centralAngle) / sinAngle
            let weightB = sin(fraction * centralAngle) / sinAngle

            // Convert each endpoint to a 3D unit vector, blend, then convert back to lat/lon.
            let xPoint = weightA * cos(lat1) * cos(lon1) + weightB * cos(lat2) * cos(lon2)
            let yPoint = weightA * cos(lat1) * sin(lon1) + weightB * cos(lat2) * sin(lon2)
            let zPoint = weightA * sin(lat1) + weightB * sin(lat2)

            let interpolatedLat = atan2(zPoint, sqrt(xPoint * xPoint + yPoint * yPoint))
            let interpolatedLon = atan2(yPoint, xPoint)

            // atan2 always returns a longitude in (-180, 180], so consecutive points jump from
            // ~+179 to ~-179 across the dateline. Unwrap each one against the previous point so
            // the arc stays longitude-continuous for MapPolyline (it accepts out-of-range lon).
            var lonDegrees = interpolatedLon.radiansToDegrees
            if let prev = coordinates.last {
                lonDegrees = unwrap(lonDegrees, against: prev.longitude)
            }

            coordinates.append(Coordinate(
                latitude: interpolatedLat.radiansToDegrees,
                longitude: lonDegrees
            ))
        }
        return coordinates
    }

    /// Shifts `longitude` by whole turns of 360° so it lands within ±180° of `reference`,
    /// keeping a polyline continuous across the antimeridian.
    private static func unwrap(_ longitude: Double, against reference: Double) -> Double {
        var lon = longitude
        while lon - reference > 180 { lon -= 360 }
        while lon - reference < -180 { lon += 360 }
        return lon
    }
}

private extension Double {
    var degreesToRadians: Double {
        self * .pi / 180
    }

    var radiansToDegrees: Double {
        self * 180 / .pi
    }
}
