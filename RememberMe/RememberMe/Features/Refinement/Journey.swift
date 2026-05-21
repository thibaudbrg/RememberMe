import Core
import Foundation
import Persistence

/// A contiguous run of timeline rows that constitute one logical trip from A to B —
/// typically several activities connected by short transit-stop visits, bookended by
/// real destinations. Detected purely from the day's `TimelineEntry` list; no DB writes.
struct Journey: Hashable {
    /// Every entry absorbed into the journey, in chronological order. Includes activities
    /// and short visits (e.g. a 9-minute station change). Excludes the destination visits
    /// that bound the journey on either side.
    let entries: [TimelineEntry]
    /// Subset of `entries` that are `activity` rows, in the same chronological order.
    let trips: [TripSummary]
    /// First trip's start coordinate — the journey's A.
    let startCoordinate: Coordinate
    /// Last trip's end coordinate — the journey's B.
    let endCoordinate: Coordinate
    let startTime: TimestampedLocal
    let endTime: TimestampedLocal

    var legCount: Int { trips.count }
    var isMultiLeg: Bool { trips.count >= 2 }

    var totalDistanceMeters: Double {
        trips.reduce(0) { $0 + $1.distanceMeters }
    }

    var totalDurationSeconds: TimeInterval {
        endTime.date.timeIntervalSince(startTime.date)
    }
}

enum JourneyDetector {
    /// Visits shorter than this are absorbed into the surrounding journey (transit stops).
    /// Longer visits terminate the journey — they're real destinations.
    static let visitAbsorptionThresholdSeconds: TimeInterval = 600

    /// Walks outward from `trip` through `timeline`, absorbing activities and short visits,
    /// stopping at real destination visits (≥ 10 min) or list bounds.
    ///
    /// Car activities only journey with other car activities. Non-car activities only with
    /// non-car activities. (A `walk → drive → walk` chain stays three separate trips.)
    ///
    /// Returns nil if no trips end up in the journey (defensive — shouldn't happen since
    /// the anchor itself is a trip).
    static func detect(
        around trip: TripSummary,
        in timeline: [TimelineEntry],
        dayTrips: [TripSummary]
    ) -> Journey? {
        let sorted = timeline.sorted { $0.start.date < $1.start.date }
        guard let anchor = sorted.firstIndex(where: { $0.id == trip.id }) else { return nil }
        let tripsByID = Dictionary(uniqueKeysWithValues: dayTrips.map { ($0.id, $0) })
        let anchorIsCar = isCarMode(trip.mode)

        var firstIdx = anchor
        while firstIdx > 0,
              shouldAbsorb(sorted[firstIdx - 1], anchorIsCar: anchorIsCar, tripsByID: tripsByID)
        {
            firstIdx -= 1
        }

        var lastIdx = anchor
        while lastIdx < sorted.count - 1,
              shouldAbsorb(sorted[lastIdx + 1], anchorIsCar: anchorIsCar, tripsByID: tripsByID)
        {
            lastIdx += 1
        }

        let entries = Array(sorted[firstIdx ... lastIdx])
        let trips: [TripSummary] = entries.compactMap { entry in
            entry.kind == "activity" ? tripsByID[entry.id] : nil
        }
        guard let first = trips.first, let last = trips.last else { return nil }

        return Journey(
            entries: entries,
            trips: trips,
            startCoordinate: first.startCoordinate,
            endCoordinate: last.endCoordinate,
            startTime: first.start,
            endTime: last.end
        )
    }

    /// True if `entry` belongs in a journey anchored at an activity whose `anchorIsCar`
    /// matches. Activities must match the anchor's car-ness; visits ride on duration alone.
    private static func shouldAbsorb(
        _ entry: TimelineEntry,
        anchorIsCar: Bool,
        tripsByID: [UUID: TripSummary]
    ) -> Bool {
        switch entry.kind {
        case "activity":
            guard let trip = tripsByID[entry.id] else { return false }
            return isCarMode(trip.mode) == anchorIsCar
        case "visit":
            return entry.duration < visitAbsorptionThresholdSeconds
        default:
            return false
        }
    }

    /// True for activities recorded as a passenger vehicle / car / motorcycle. Matches
    /// Google Takeout phrasing ("in passenger vehicle", "driving", "motorcycling") and
    /// the bare granular labels we emit from refinement legs ("driving").
    private static func isCarMode(_ mode: String) -> Bool {
        let lower = mode.lowercased()
        if lower.contains("motorcycl") { return true }
        if lower.contains("vehicle") { return true }
        if lower.contains("driving") { return true }
        if lower == "car" { return true }
        return false
    }
}
