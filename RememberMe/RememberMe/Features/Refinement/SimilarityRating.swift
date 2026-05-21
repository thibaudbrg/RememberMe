import Core
import Foundation
import SwiftUI

/// Maps a `SimilarityScore.composite` (mean + 0.5·p95, in meters) to a finer-grained
/// quality bucket than the original 3-tier Good/Fair/Poor split. The rating now scales
/// with the route's length — `15 m off` on a 100 m walk is "Very poor", on a 50 km drive
/// it's "Excellent". Driving routes get an extra 2× leniency because cars freely take
/// alternate streets, so a recorded GPS trace easily diverges from a fresh route lookup
/// without the trip being genuinely "wrong".
enum SimilarityRating: String {
    case excellent
    case veryGood
    case good
    case fair
    case marginal
    case poor
    case veryPoor

    /// - Parameters:
    ///   - composite: `SimilarityScore.composite` — mean + 0.5·p95 in meters.
    ///   - referenceDistanceMeters: the candidate route's `expectedDistanceMeters` (or
    ///     the trip's straight-line A→B distance as a fallback). Used to compute a
    ///     relative ratio.
    ///   - lenientForDriving: doubles the effective tolerance when the candidate is a
    ///     car route. Pass `candidate.transportType == .automobile`.
    static func from(
        composite: Double,
        referenceDistanceMeters: Double,
        lenientForDriving: Bool
    ) -> SimilarityRating {
        // Floor the reference distance so very short trips don't divide near zero. 100 m
        // matches our minimum eligible trip distance.
        let base = max(referenceDistanceMeters, 100)
        let scale = lenientForDriving ? 2.0 : 1.0
        let ratio = (composite / base) / scale
        switch ratio {
        case ..<0.003: return .excellent
        case ..<0.008: return .veryGood
        case ..<0.015: return .good
        case ..<0.030: return .fair
        case ..<0.060: return .marginal
        case ..<0.120: return .poor
        default:        return .veryPoor
        }
    }

    var label: String {
        switch self {
        case .excellent: "Excellent"
        case .veryGood: "Very good"
        case .good: "Good"
        case .fair: "Fair"
        case .marginal: "Marginal"
        case .poor: "Poor"
        case .veryPoor: "Very poor"
        }
    }

    /// Continuous green→red shading: green at "excellent", red at "very poor".
    var color: Color {
        switch self {
        case .excellent: Color(red: 0.10, green: 0.65, blue: 0.30)
        case .veryGood:  Color(red: 0.30, green: 0.70, blue: 0.30)
        case .good:      Color(red: 0.55, green: 0.70, blue: 0.20)
        case .fair:      Color(red: 0.80, green: 0.65, blue: 0.10)
        case .marginal:  Color(red: 0.85, green: 0.50, blue: 0.10)
        case .poor:      Color(red: 0.85, green: 0.35, blue: 0.20)
        case .veryPoor:  Color(red: 0.80, green: 0.20, blue: 0.20)
        }
    }

    /// "12 min", "1 h 23 min", "0 min" — used wherever a duration is rendered in the
    /// refinement flow so the format stays consistent.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded() / 60))
        if total < 60 { return "\(total) min" }
        let h = total / 60
        let m = total % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
