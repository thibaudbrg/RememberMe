import Foundation

/// How closely a candidate route matches the recorded GPS samples.
/// Lower is better. `composite` is `meanMeters + 0.5 * p95Meters` plus a tiny length term.
public struct SimilarityScore: Hashable, Sendable {
    public let meanMeters: Double
    public let p95Meters: Double
    public let maxMeters: Double
    public let sampleCount: Int
    /// Total length of the candidate route in meters. Used only as a tie-breaker so that, when
    /// two candidates fit the samples about equally well, the shorter one wins — a detour through
    /// unsampled areas (which sample-to-candidate distance alone can't penalize) ranks worse.
    public let candidateLengthMeters: Double

    public init(
        meanMeters: Double,
        p95Meters: Double,
        maxMeters: Double,
        sampleCount: Int,
        candidateLengthMeters: Double = 0
    ) {
        self.meanMeters = meanMeters
        self.p95Meters = p95Meters
        self.maxMeters = maxMeters
        self.sampleCount = sampleCount
        self.candidateLengthMeters = candidateLengthMeters
    }

    /// The length term is weighted at 0.01, so 1 km of extra route only outranks a candidate whose
    /// fit is better by more than ~10 m — it breaks ties without overriding a genuinely closer fit.
    public var composite: Double { meanMeters + 0.5 * p95Meters + 0.01 * candidateLengthMeters }
}
