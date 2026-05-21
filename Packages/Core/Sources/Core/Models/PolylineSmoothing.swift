import Foundation

/// Gentle corner-rounding for polylines, used to soften the angular look of GPS breadcrumbs
/// when drawn as a `MapPolyline`.
///
/// Uses **Chaikin's corner-cutting algorithm**: for each line segment from P to Q, two new
/// points are inserted at 1/4 and 3/4 of the way from P to Q. The polyline is then rebuilt
/// from those new points. Repeated 2–3 times this converges to a smooth quadratic B-spline
/// that stays inside the original polyline — no overshoot, no spiky inversions at sharp
/// corners. It's the same shape commercial vector editors use for their "round corners" tool.
public enum PolylineSmoothing {
    /// Returns a corner-cut version of `coordinates`. The first and last points are preserved
    /// exactly; everything in between is replaced by interpolated samples that round the
    /// corners off. Polylines of fewer than 3 points are returned unchanged.
    ///
    /// - Parameters:
    ///   - coordinates: The original control polyline.
    ///   - iterations: How many times to apply Chaikin's pass. 2 is a good default — visible
    ///     rounding without ballooning the point count too much (each pass roughly doubles
    ///     the number of points).
    public static func chaikin(
        coordinates: [Coordinate],
        iterations: Int = 2
    ) -> [Coordinate] {
        guard coordinates.count >= 3, iterations >= 1 else { return coordinates }

        var current = coordinates
        for _ in 0 ..< iterations {
            var next: [Coordinate] = []
            next.reserveCapacity(current.count * 2)

            // Preserve the first point exactly so the line still starts where it should.
            next.append(current[0])

            for index in 0 ..< current.count - 1 {
                let leading = current[index]
                let trailing = current[index + 1]
                next.append(interpolate(leading, trailing, t: 0.25))
                next.append(interpolate(leading, trailing, t: 0.75))
            }

            // Preserve the last point exactly.
            next.append(current[current.count - 1])
            current = next
        }
        return current
    }

    private static func interpolate(_ a: Coordinate, _ b: Coordinate, t: Double) -> Coordinate {
        Coordinate(
            latitude: a.latitude * (1 - t) + b.latitude * t,
            longitude: a.longitude * (1 - t) + b.longitude * t
        )
    }
}
