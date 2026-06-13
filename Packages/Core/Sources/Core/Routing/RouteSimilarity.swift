import Foundation

/// Pure-Swift similarity scorer. For each recorded sample, finds the nearest point on any
/// segment of the candidate polyline and aggregates the distances.
public enum RouteSimilarity {
    /// Returns `nil` when there are no samples to compare against (caller treats this as
    /// "no GPS samples, accept candidate as-is").
    public static func score(samples: [Coordinate], candidate: [Coordinate]) -> SimilarityScore? {
        guard !samples.isEmpty else { return nil }
        guard candidate.count >= 2 else {
            // Degenerate candidate — return very large distance so the caller picks something else.
            return SimilarityScore(meanMeters: .infinity, p95Meters: .infinity, maxMeters: .infinity, sampleCount: samples.count)
        }

        var distances: [Double] = []
        distances.reserveCapacity(samples.count)
        for sample in samples {
            var best = Double.infinity
            for segmentIndex in 0 ..< (candidate.count - 1) {
                let d = nearestPointDistance(
                    point: sample,
                    segmentStart: candidate[segmentIndex],
                    segmentEnd: candidate[segmentIndex + 1]
                )
                if d < best { best = d }
            }
            distances.append(best)
        }

        let total = distances.reduce(0, +)
        let mean = total / Double(distances.count)
        let max = distances.max() ?? 0
        let p95 = percentile(distances, p: 0.95)

        // Candidate route length — used only as a tie-breaker (see SimilarityScore.composite).
        var length = 0.0
        for index in 1 ..< candidate.count {
            length += PolylineDirection.haversineMeters(candidate[index - 1], candidate[index])
        }

        return SimilarityScore(
            meanMeters: mean,
            p95Meters: p95,
            maxMeters: max,
            sampleCount: distances.count,
            candidateLengthMeters: length
        )
    }

    /// Distance in meters from `point` to the nearest point on the line segment defined by
    /// `segmentStart`–`segmentEnd`. Uses an equirectangular projection local to the segment
    /// (valid for the short segments we deal with — a few meters to a few hundred meters).
    public static func nearestPointDistance(
        point: Coordinate,
        segmentStart: Coordinate,
        segmentEnd: Coordinate
    ) -> Double {
        // Project to a flat (x, y) plane centered on segmentStart. Meters per degree of
        // longitude depends on latitude; latitude meters are ~constant.
        let latRef = segmentStart.latitude * .pi / 180
        let mPerDegLat = 111_132.0
        let mPerDegLon = 111_320.0 * cos(latRef)

        func project(_ c: Coordinate) -> (x: Double, y: Double) {
            // Normalize the longitude delta into [-180, 180] so a point and segment on opposite
            // sides of the antimeridian (e.g. 179.99 vs -179.99) project a few km apart, not ~40,000 km.
            var dLon = c.longitude - segmentStart.longitude
            while dLon > 180 { dLon -= 360 }
            while dLon < -180 { dLon += 360 }
            let x = dLon * mPerDegLon
            let y = (c.latitude - segmentStart.latitude) * mPerDegLat
            return (x, y)
        }

        let p = project(point)
        let a = (x: 0.0, y: 0.0)
        let b = project(segmentEnd)

        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSquared = dx * dx + dy * dy
        if lenSquared == 0 {
            // Zero-length segment — fall back to haversine for accuracy at long distances.
            return PolylineDirection.haversineMeters(point, segmentStart)
        }

        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSquared
        t = max(0, min(1, t))
        let closest = (x: a.x + t * dx, y: a.y + t * dy)
        let ex = p.x - closest.x
        let ey = p.y - closest.y
        return (ex * ex + ey * ey).squareRoot()
    }

    /// Linear-interpolated percentile of `values`, where `p` is in `[0, 1]`.
    static func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let frac = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
    }
}
