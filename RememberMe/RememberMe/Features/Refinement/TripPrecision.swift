import Core
import Foundation
import Persistence

/// Detects when a trip's GPS samples are dense enough that the recorded route is
/// already trustworthy — used by the auto-runners (Refine whole day / Refine entire
/// history) to skip car trips that Google's background tracking already captured
/// faithfully. Manual refinement from the trip detail screen is unaffected; this is
/// only a gate on the automatic apply.
enum TripPrecision {
    /// At least this many samples must be present to even consider the trip "precise".
    /// Below this, density math is too noisy to be meaningful.
    static let minimumSampleCount: Int = 30

    /// Required sample-per-minute density. Calibrated from real data:
    ///   - Lausanne→Bologna drive (251 samples, 5h27m): 0.77 / min → precise
    ///   - 5-sample bug trip: 0.03 / min → not precise
    ///   - 1h walk with 5 samples: 0.08 / min → not precise (auto-refine it)
    static let minSamplesPerMinute: Double = 0.3

    static func isPrecise(samples: [Coordinate], tripDurationSeconds: TimeInterval) -> Bool {
        guard samples.count >= minimumSampleCount else { return false }
        guard tripDurationSeconds > 0 else { return false }
        let perMinute = Double(samples.count) / (tripDurationSeconds / 60)
        return perMinute >= minSamplesPerMinute
    }

    /// True for activity modes that represent driving a car (or motorcycle). Matches
    /// Google Takeout phrasing ("in passenger vehicle", "motorcycling") and the bare
    /// granular labels we emit from refinement legs ("driving").
    static func isCarMode(_ mode: String) -> Bool {
        let lower = mode.lowercased()
        if lower.contains("motorcycl") { return true }
        if lower.contains("vehicle") { return true }
        if lower.contains("driving") { return true }
        if lower == "car" { return true }
        return false
    }
}
