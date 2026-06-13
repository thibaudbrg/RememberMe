import Core
import Foundation
import Observation
import Persistence

/// Scored route candidate pair shown in the debug-mode candidate list.
struct ScoredCandidate: Hashable, Identifiable {
    let candidate: RouteCandidate
    /// `nil` when the trip has no recorded samples to score against.
    let score: SimilarityScore?

    var id: UUID { candidate.id }
}

/// Drives the path-refinement screen. Holds transient fetch state for one trip
/// at a time. Calls into `RouteProxyRouter` + `Persistence` + refreshes the live `AppEnvironment`
/// so the rest of the app sees the refined polyline immediately.
@MainActor
@Observable
final class PathRefinementController {
    enum FetchState: Equatable {
        case idle
        case fetching
        case ready(scored: [ScoredCandidate])
        case failed(String)

        static func == (lhs: FetchState, rhs: FetchState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.fetching, .fetching): return true
            case let (.ready(a), .ready(b)): return a == b
            case let (.failed(a), .failed(b)): return a == b
            default: return false
            }
        }
    }

    private let router: RouteProxyRouter
    private weak var environment: AppEnvironment?

    var state: FetchState = .idle
    /// The trip currently being inspected. Cleared when the user navigates away.
    var activeTripID: UUID?
    /// Typed failure from the most recent fetch, cleared on success. Lets the history
    /// runner distinguish genuine no-route outcomes (persist a skip) from transient
    /// network / throttle failures (back off and retry) and config failures (abort).
    private(set) var lastError: RoutingError?
    /// Bumped at the start of every fetch. A fetch only writes its terminal state if its
    /// captured generation still matches — so a stale fetch completing late can't clobber
    /// the state (or candidates) of a newer fetch for a different trip.
    private var fetchGeneration = 0

    init(
        router: RouteProxyRouter = RouteProxyRouter(),
        environment: AppEnvironment? = nil
    ) {
        self.router = router
        self.environment = environment
    }

    func bind(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Fetches candidate routes for `trip` and scores them against the recorded samples.
    func fetch(for trip: TripSummary) async {
        fetchGeneration += 1
        let gen = fetchGeneration
        activeTripID = trip.id
        lastError = nil
        state = .fetching

        guard let mode = RefinementMode.map(recordedMode: trip.mode) else {
            state = .failed("This trip's transport mode isn't supported (e.g. flight).")
            return
        }

        let samples = environment.map { Self.scoringSamples(forTrip: trip, environment: $0) } ?? []

        do {
            let candidates = try await router.fetchCandidates(
                start: trip.startCoordinate,
                end: trip.endCoordinate,
                mode: mode
            )
            let scored = candidates.map { candidate in
                ScoredCandidate(
                    candidate: candidate,
                    score: RouteSimilarity.score(samples: samples, candidate: candidate.coordinates)
                )
            }
            // Sort by composite score (best first). Candidates with `nil` score (no samples)
            // keep the order the routing service returned them in.
            let sorted = scored.sorted { a, b in
                switch (a.score, b.score) {
                case let (.some(lhs), .some(rhs)): lhs.composite < rhs.composite
                case (.some, .none): true
                case (.none, .some): false
                case (.none, .none): false
                }
            }
            guard gen == fetchGeneration else { return }
            state = .ready(scored: sorted)
        } catch {
            guard gen == fetchGeneration else { return }
            lastError = error as? RoutingError ?? .other(error.localizedDescription)
            state = .failed(error.localizedDescription)
        }
    }

    /// Replaces the recorded path with `candidate`'s coordinates and refreshes the map.
    /// For multi-modal candidates (e.g. Google's bus → walk → bus) splits the original
    /// activity into N derived activities, one per leg, and marks the original superseded.
    /// Returns true on success.
    @discardableResult
    func apply(
        candidate: RouteCandidate,
        score: SimilarityScore?,
        to trip: TripSummary,
        candidateCount: Int,
        chosenIndex: Int,
        originalPointCount: Int
    ) async -> Bool {
        guard let environment, let database = environment.openDatabase() else { return false }
        let source = "google_maps"
        let originalSamples = environment.recordedSamples(forTrip: trip)
        let record = RefinementRecord(
            eventID: trip.id,
            refinedAt: Date(),
            source: source,
            routeName: candidate.name,
            transportType: candidate.transportType.rawValue,
            similarityMeanMeters: score?.meanMeters ?? 0,
            similarityP95Meters: score?.p95Meters ?? 0,
            similarityMaxMeters: score?.maxMeters ?? 0,
            expectedTravelTimeSeconds: candidate.expectedTravelTime,
            expectedDistanceMeters: candidate.expectedDistanceMeters,
            candidateCount: candidateCount,
            chosenIndex: chosenIndex,
            originalPointCount: originalPointCount,
            refinedPointCount: candidate.coordinates.count
        )
        do {
            if candidate.isMultiModal {
                let legs = candidate.segments.map { segment in
                    LegInput(
                        mode: segment.displayMode,
                        label: segment.label,
                        coordinates: segment.coordinates,
                        distanceMeters: segment.distanceMeters ?? 0,
                        travelTimeSeconds: segment.travelTime ?? 0,
                        probability: 1.0
                    )
                }
                try Persistence.applyMultiLegRefinement(
                    in: database,
                    originalEventID: trip.id,
                    originalSamples: originalSamples,
                    legs: legs,
                    record: record
                )
            } else {
                try Persistence.applyRefinement(
                    in: database,
                    eventID: trip.id,
                    originalSamples: originalSamples,
                    refinedPoints: candidate.coordinates,
                    record: record
                )
            }
            await environment.loadDay()
            return true
        } catch {
            state = .failed("Couldn't save refinement: \(error.localizedDescription)")
            return false
        }
    }

    /// Restores the original GPS samples for the trip. If `trip` is a derived sub-activity
    /// from a multi-leg refinement, reverts the whole journey via the parent.
    @discardableResult
    func revert(trip: TripSummary) async -> Bool {
        guard let environment, let database = environment.openDatabase() else { return false }
        do {
            let targetID = (try Persistence.parentEventID(in: database, eventID: trip.id)) ?? trip.id
            try Persistence.revertRefinement(in: database, eventID: targetID)
            await environment.loadDay()
            return true
        } catch {
            state = .failed("Couldn't revert: \(error.localizedDescription)")
            return false
        }
    }

    /// Journey-level fetch. Runs one routing request for the whole A→B span (first trip's
    /// start → last trip's end) using the provider-appropriate mode. Scoring concatenates
    /// every recorded leg's GPS samples for a holistic similarity score.
    func fetch(for journey: Journey) async {
        fetchGeneration += 1
        let gen = fetchGeneration
        activeTripID = journey.trips.first?.id
        lastError = nil
        state = .fetching

        // Mode selection: any transit leg → transit; else first mappable mode; fallback walking.
        let modes = journey.trips.compactMap { RefinementMode.map(recordedMode: $0.mode) }
        let mode: RefinementMode = modes.contains(.transit) ? .transit : (modes.first ?? .walking)

        let samples = journey.trips.flatMap { trip in
            environment.map { Self.scoringSamples(forTrip: trip, environment: $0) } ?? []
        }

        do {
            let candidates = try await router.fetchCandidates(
                start: journey.startCoordinate,
                end: journey.endCoordinate,
                mode: mode
            )
            let scored = candidates.map { candidate in
                ScoredCandidate(
                    candidate: candidate,
                    score: RouteSimilarity.score(samples: samples, candidate: candidate.coordinates)
                )
            }
            let sorted = scored.sorted { a, b in
                switch (a.score, b.score) {
                case let (.some(lhs), .some(rhs)): lhs.composite < rhs.composite
                case (.some, .none): true
                case (.none, .some): false
                case (.none, .none): false
                }
            }
            guard gen == fetchGeneration else { return }
            state = .ready(scored: sorted)
        } catch {
            guard gen == fetchGeneration else { return }
            lastError = error as? RoutingError ?? .other(error.localizedDescription)
            state = .failed(error.localizedDescription)
        }
    }

    /// Applies a candidate as a journey-level refinement: supersedes every member of the
    /// journey and writes N derived activities for the candidate's segments. If the
    /// candidate is single-modal, the journey still becomes one derived activity (the
    /// whole route).
    @discardableResult
    func applyJourney(
        candidate: RouteCandidate,
        score: SimilarityScore?,
        journey: Journey,
        candidateCount: Int,
        chosenIndex: Int
    ) async -> Bool {
        guard let environment,
              let database = environment.openDatabase(),
              let primaryTrip = journey.trips.first
        else { return false }

        let source = "google_maps"
        let originalSamples = journey.trips.flatMap { environment.recordedSamples(forTrip: $0) }

        let legs: [LegInput] = candidate.segments.map { segment in
            LegInput(
                mode: segment.displayMode,
                label: segment.label,
                coordinates: segment.coordinates,
                distanceMeters: segment.distanceMeters ?? 0,
                travelTimeSeconds: segment.travelTime ?? 0,
                probability: 1.0
            )
        }

        let record = RefinementRecord(
            eventID: primaryTrip.id,
            refinedAt: Date(),
            source: source,
            routeName: candidate.name,
            transportType: candidate.transportType.rawValue,
            similarityMeanMeters: score?.meanMeters ?? 0,
            similarityP95Meters: score?.p95Meters ?? 0,
            similarityMaxMeters: score?.maxMeters ?? 0,
            expectedTravelTimeSeconds: candidate.expectedTravelTime,
            expectedDistanceMeters: candidate.expectedDistanceMeters,
            candidateCount: candidateCount,
            chosenIndex: chosenIndex,
            originalPointCount: originalSamples.count,
            refinedPointCount: candidate.coordinates.count,
            journeyMemberIDs: journey.entries.map(\.id)
        )

        do {
            try Persistence.applyJourneyRefinement(
                in: database,
                primaryEventID: primaryTrip.id,
                supersededEventIDs: journey.entries.map(\.id),
                journeyStartTs: Int64(journey.startTime.date.timeIntervalSince1970),
                journeyEndTs: Int64(journey.endTime.date.timeIntervalSince1970),
                timezoneOffsetMin: journey.startTime.tzOffsetMinutes,
                source: source,
                originalSamples: originalSamples,
                legs: legs,
                record: record
            )
            await environment.loadDay()
            return true
        } catch {
            state = .failed("Couldn't save journey refinement: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns the sample set to use for similarity scoring. When the trip's endpoints
    /// were healed (i.e. Google's metadata disagreed sharply with the GPS samples), the
    /// recorded samples only cover a fraction of the real journey, so per-sample scoring
    /// is misleading. Fall back to the healed endpoint coordinates as the only anchors —
    /// the score then reflects "does the candidate go from A to B?" which is the only
    /// meaningful signal available for these trips.
    private static func scoringSamples(
        forTrip trip: TripSummary,
        environment: AppEnvironment
    ) -> [Coordinate] {
        let recorded = environment.recordedSamples(forTrip: trip)
        guard let first = recorded.first, let last = recorded.last else {
            // No samples at all — use endpoints.
            return [trip.startCoordinate, trip.endCoordinate]
        }
        let startMismatch = PolylineDirection.haversineMeters(trip.startCoordinate, first)
        let endMismatch = PolylineDirection.haversineMeters(trip.endCoordinate, last)
        // Same threshold as AppEnvironment's heal — single source of truth (L39). If a heal
        // happened on this trip, the recorded samples are unreliable (sparse, partial);
        // endpoint-only scoring is the right signal.
        let threshold = AppEnvironment.healMismatchThresholdMeters
        if startMismatch > threshold || endMismatch > threshold {
            return [trip.startCoordinate, trip.endCoordinate]
        }
        return recorded
    }

    /// Records that the user skipped this trip.
    func markSkipped(trip: TripSummary, reason: SkipReason) {
        guard let environment, let database = environment.openDatabase() else { return }
        try? Persistence.markSkipped(in: database, eventID: trip.id, reason: reason)
    }

    /// Reads the audit row for `trip`, if any.
    func refinement(for trip: TripSummary) -> RefinementRecord? {
        guard let environment, let database = environment.openDatabase() else { return nil }
        return (try? Persistence.refinement(in: database, eventID: trip.id))
    }
}
