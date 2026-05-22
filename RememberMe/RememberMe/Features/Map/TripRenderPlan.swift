import Core
import Foundation
import Persistence

/// Decides what to draw on the map for a given day.
///
/// **Round 11 model: activity-driven.** One polyline per `activity` event, with the polyline's
/// coordinates sliced from any covering `path` event's GPS samples whose timestamps fall
/// inside the activity's time window. If no samples land in the window (e.g. a 3-minute walk
/// inside a 2-hour path that only carries 10 samples), we still render the activity with at
/// least its A→B coordinates — so the mode-specific style (dashed walking, curved flying)
/// always shows.
///
/// Path events without any covering activity are dropped — they're noise relative to the
/// activity timeline.
enum TripRenderPlan {
    /// A single polyline to draw on the map.
    struct PolylineRender: Identifiable, Equatable {
        let id: String
        let coordinates: [Coordinate]
        let mode: String
    }

    /// Decides which polylines to render for the given day. `refinedByActivity` maps an
    /// activity's id to its refined polyline (one row per activity that has been refined,
    /// including derived sub-activities from a multi-leg split). When present it takes
    /// precedence over the time-sliced GPS samples.
    static func renders(
        paths: [PathTrace],
        activities: [TripSummary],
        refinedByActivity: [UUID: [Coordinate]] = [:]
    ) -> [PolylineRender] {
        activities.map { activity in
            PolylineRender(
                id: "trip-\(activity.id.uuidString)",
                coordinates: coordinates(for: activity, paths: paths, refinedByActivity: refinedByActivity),
                mode: activity.mode
            )
        }
    }

    /// Returns the coordinates that should be drawn for `activity`:
    ///   - If a refinement polyline exists for this activity (single-leg refinement, or
    ///     a derived leg of a multi-leg split), return it — that's the user's chosen line.
    ///   - Else if a path overlaps the activity's window, return the path's GPS samples
    ///     whose **actual** `offsetMinutes`-derived timestamp falls inside the activity
    ///     window, bookended by the activity's own start/end so transitions are clean.
    ///   - Otherwise fall back to the activity's straight A→B (or a great-circle arc for flights).
    static func coordinates(
        for activity: TripSummary,
        paths: [PathTrace],
        refinedByActivity: [UUID: [Coordinate]] = [:]
    ) -> [Coordinate] {
        if let refined = refinedByActivity[activity.id], refined.count >= 2 {
            return refined
        }
        // Aggregate samples from EVERY path event that overlaps the activity. Google's
        // Takeout chunks GPS samples into 2-hour blocks, so a long drive spans multiple
        // `path` events — picking just `.first` drops 3/4 of the samples for a 5-hour
        // trip. We collect samples (sample-time, coordinate), filter to the activity's
        // window, and sort chronologically across all paths.
        var collected: [(time: Date, coordinate: Coordinate)] = []
        for path in paths where overlapSeconds(path: path, activity: activity) > 0 {
            for sample in path.samples {
                let sampleTime = path.start.date.addingTimeInterval(TimeInterval(sample.offsetMinutes * 60))
                if sampleTime >= activity.start.date && sampleTime <= activity.end.date {
                    collected.append((sampleTime, sample.coordinate))
                }
            }
        }
        if !collected.isEmpty {
            collected.sort { $0.time < $1.time }
            // Bookend with the activity's own coordinates so:
            //   1. The polyline connects smoothly to the previous/next activity's polyline
            //   2. Very short activities that catch no samples still produce a usable line
            //      at the right location (and aren't accidentally drawn somewhere else).
            var line: [Coordinate] = [activity.startCoordinate]
            line.append(contentsOf: collected.map(\.coordinate))
            line.append(activity.endCoordinate)
            return line
        }

        return TripStyle.polylineCoordinates(
            for: activity.mode,
            startCoordinate: activity.startCoordinate,
            endCoordinate: activity.endCoordinate,
            recordedPathPoints: []
        )
    }

    /// Single-source-of-truth for "what does focus on this activity zoom to" — same coordinates
    /// we'd draw on the map, so the camera and the line always agree.
    static func focusCoordinates(
        for activity: TripSummary,
        paths: [PathTrace],
        refinedByActivity: [UUID: [Coordinate]] = [:]
    ) -> [Coordinate] {
        coordinates(for: activity, paths: paths, refinedByActivity: refinedByActivity)
    }

    /// Still used by the timeline-tap handler to decide whether a path row is redundant
    /// with an activity row.
    static func isCoveredByAnyPath(_ activity: TripSummary, paths: [PathTrace]) -> Bool {
        paths.contains { overlapSeconds(path: $0, activity: activity) > 0 }
    }

    // MARK: - Internals

    private static func overlapSeconds(path: PathTrace, activity: TripSummary) -> TimeInterval {
        let latestStart = max(path.start.date, activity.start.date)
        let earliestEnd = min(path.end.date, activity.end.date)
        return max(0, earliestEnd.timeIntervalSince(latestStart))
    }
}
