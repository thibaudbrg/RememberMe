import Core

/// Visual treatment for activity (trip) polylines and the matching timeline rows.
///
/// Trip lines are drawn in the user's accent color (see `MapScreen`); this type only decides
/// geometry (flights get a great-circle arc) and the timeline symbol/label per mode.
enum TripStyle {
    /// True if the trip should be drawn as a curved great-circle arc rather than a straight line.
    static func isFlight(_ mode: String) -> Bool {
        let normalized = mode.lowercased()
        return normalized.contains("flying") || normalized.contains("flight") || normalized.contains("plane")
    }

    /// Returns the polyline coordinates for an activity. Flights get a great-circle arc;
    /// everything else is the straight start→end (or the supplied path-point fallback).
    static func polylineCoordinates(
        for mode: String,
        startCoordinate: Coordinate,
        endCoordinate: Coordinate,
        recordedPathPoints: [Coordinate]
    ) -> [Coordinate] {
        if isFlight(mode) {
            return GreatCircle.arc(from: startCoordinate, to: endCoordinate)
        }
        if !recordedPathPoints.isEmpty {
            return recordedPathPoints
        }
        return [startCoordinate, endCoordinate]
    }

    /// SF Symbol shown in the timeline row for an activity in this mode.
    static func symbol(for mode: String) -> String {
        let normalized = mode.lowercased()
        // Bare granular modes (from Google refinement segments) — checked first so
        // strings like "cable car" don't fall into the loose "car" → car.fill rule.
        if normalized == "cable car" { return "cablecar.fill" }
        if normalized == "tram" { return "tram" }
        if normalized == "driving" { return "car.fill" }

        if normalized.contains("walk") { return "figure.walk" }
        if normalized.contains("running") { return "figure.run" }
        if normalized.contains("cycl") || normalized.contains("bicycle") { return "bicycle" }
        if normalized.contains("motorcycl") { return "scooter" }
        if normalized.contains("subway") { return "tram.fill" }
        if normalized.contains("train") { return "tram" }
        if normalized.contains("bus") { return "bus" }
        if normalized.contains("transit") { return "tram" }
        if normalized.contains("flying") || normalized.contains("flight") || normalized.contains("plane") {
            return "airplane"
        }
        if normalized.contains("ferry") || normalized.contains("boat") || normalized.contains("ship") {
            return "ferry"
        }
        if normalized.contains("vehicle") || normalized.contains("car") { return "car.fill" }
        if normalized.contains("still") { return "pause.circle" }
        return "arrow.triangle.swap" // unknown trip
    }

    /// Human-readable mode label for chips and rows. Capitalizes Google's verbose strings
    /// and our own granular mode strings from refinement legs.
    static func friendlyLabel(for mode: String) -> String {
        let normalized = mode.lowercased()
        if normalized.contains("in passenger vehicle") { return "Driving" }
        if normalized.contains("in subway") { return "Subway" }
        if normalized.contains("in train") { return "Train" }
        if normalized.contains("in bus") { return "Bus" }
        if normalized.contains("in ferry") { return "Ferry" }
        if normalized.contains("on foot") || normalized.contains("walking") { return "Walking" }
        if normalized.contains("running") { return "Running" }
        if normalized.contains("cycling") { return "Cycling" }
        if normalized.contains("motorcycling") { return "Motorcycling" }
        if normalized.contains("flying") { return "Flight" }
        // Bare granular modes from refinement (no "in " prefix). Capitalized rendering
        // keeps things consistent ("Bus", "Train", "Subway", "Tram", "Ferry", …).
        if normalized == "driving" { return "Driving" }
        if normalized == "transit" { return "Transit" }
        if mode.isEmpty { return "Trip" }
        return mode.capitalized
    }
}
