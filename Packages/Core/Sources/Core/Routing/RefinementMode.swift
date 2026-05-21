import Foundation

/// Coarse transport bucket used when asking Apple Maps for an alternative route.
/// Maps the free-form recorded `mode` string onto something `MKDirections` understands.
public enum RefinementMode: String, Hashable, Sendable, CaseIterable {
    case walking
    case automobile
    case transit
}

public extension RefinementMode {
    /// True if the recorded trip was logged as a bicycle. Apple Maps doesn't model cycling,
    /// so we still route the trip as walking but the UI shows a note explaining why.
    static func isCycling(recordedMode: String) -> Bool {
        let needle = recordedMode.lowercased()
        return needle.contains("cycl") || needle.contains("bicycle")
    }

    /// Maps the recorded free-form mode string onto a coarse routing bucket.
    /// Returns `nil` for modes that Apple Maps can't help with (flight, unknown).
    static func map(recordedMode: String) -> RefinementMode? {
        let needle = recordedMode.lowercased()

        // Flight: skip entirely.
        if needle.contains("flight") { return nil }

        // Vehicles — checked before walk-family so "motorcycling" doesn't fall into cycling.
        if needle.contains("motorcycl")
            || needle.contains("vehicle")
            || needle.contains("driving")
            || needle.contains("car")
        {
            return .automobile
        }

        // Walking-family (includes cycling — see `isCycling`).
        if needle.contains("walk")
            || needle.contains("running")
            || needle.contains("on foot")
            || needle.contains("cycl")
            || needle.contains("bicycle")
        {
            return .walking
        }

        // Transit.
        if needle.contains("subway")
            || needle.contains("train")
            || needle.contains("bus")
            || needle.contains("tram")
            || needle.contains("transit")
            || needle.contains("public transport")
        {
            return .transit
        }

        // Empty / unknown — let Apple decide.
        if needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return .walking // best-effort default; debug-mode user can still reject.
    }
}
