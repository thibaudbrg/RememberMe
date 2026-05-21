import Foundation

/// How closely a candidate route matches the recorded GPS samples.
/// Lower is better. `composite` is `meanMeters + 0.5 * p95Meters`.
public struct SimilarityScore: Hashable, Sendable {
    public let meanMeters: Double
    public let p95Meters: Double
    public let maxMeters: Double
    public let sampleCount: Int

    public init(meanMeters: Double, p95Meters: Double, maxMeters: Double, sampleCount: Int) {
        self.meanMeters = meanMeters
        self.p95Meters = p95Meters
        self.maxMeters = maxMeters
        self.sampleCount = sampleCount
    }

    public var composite: Double { meanMeters + 0.5 * p95Meters }
}
