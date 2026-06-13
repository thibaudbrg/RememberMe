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

        // Granular transit modes that must be caught before the vehicle block: "cable car" /
        // "IN_CABLE_CAR" would otherwise match the "car" substring → automobile, and "ferry"
        // would fall through to the walking default. These are leg displayModes/raw strings
        // applyJourney persists, so they get fed back through map().
        if needle.contains("cable car") || needle.contains("cable_car")
            || needle.contains("ferry")
            || needle.contains("tram")
        {
            return .transit
        }

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
