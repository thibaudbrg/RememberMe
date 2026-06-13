import Core
import Foundation
import Persistence
import SwiftUI

/// Throttle policy for the history-wide refinement runner. The route proxy enforces its
/// own per-device rate limit (30/min), so the client paces itself just below it:
/// 100 ms inter-request, no batch pause, 5 s back-off on a throttle response.
struct ThrottlePolicy {
    let interRequestDelay: Duration
    /// nil = no batch pause needed.
    let batchSize: Int?
    let batchPauseSeconds: TimeInterval
    let backoffSeconds: TimeInterval

    static let google = ThrottlePolicy(
        interRequestDelay: .milliseconds(100),
        batchSize: nil,
        batchPauseSeconds: 0,
        backoffSeconds: 5
    )
}

/// Iterates the given list of days and runs the per-day refinement loop on each — picking
/// the best-scored candidate every time. Throttled per the chosen provider's policy.
/// `days` is the exact set to iterate (caller-supplied); callers pass `daysWithData` for the
/// settings "refine entire history" flow, or a filtered subset for week / month / single-day.
struct RefineHistoryProgressSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let days: [Date]
    let title: String

    init(days: [Date], title: String = "Refine history") {
        self.days = days
        self.title = title
    }

    enum Phase: Equatable {
        case preparing
        case processing(
            dayLabel: String,
            completedDays: Int,
            totalDays: Int,
            refinedTrips: Int,
            skippedTrips: Int,
            etaSeconds: TimeInterval?,
            pausing: Bool
        )
        case finished(refined: Int, skipped: Int)
        case cancelled(refined: Int, skipped: Int)
        case aborted(refined: Int, skipped: Int, message: String)

        var counts: (refined: Int, skipped: Int) {
            switch self {
            case .preparing: (0, 0)
            case let .processing(_, _, _, r, s, _, _): (r, s)
            case let .finished(r, s): (r, s)
            case let .cancelled(r, s): (r, s)
            case let .aborted(r, s, _): (r, s)
            }
        }
    }

    @State private var phase: Phase = .preparing
    @State private var task: Task<Void, Never>?
    /// Set to the user's original selectedDay on appear so we can restore it on exit
    /// — the runner mutates `environment.selectedDay` to scrub through days.
    @State private var originalSelectedDay: Date?
    /// The user's range granularity on appear. Forced to `.day` for the run (so each
    /// `selectDay`/`loadDay` loads exactly one day — otherwise a week/month range would do
    /// the whole span on the first iteration and make progress/ETA fiction) and restored
    /// on exit.
    @State private var originalRange: AppEnvironment.DateRangeKind?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusCard
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                Spacer(minLength: 0)
                bottomBar
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isRunning)
        }
        .onAppear {
            guard task == nil else { return }
            originalSelectedDay = environment.selectedDay
            originalRange = environment.selectedRange
            // Force per-day granularity so each loadDay loads exactly one day.
            environment.selectedRange = .day
            task = Task { await runHistory() }
        }
        .onDisappear {
            task?.cancel()
            task = nil
            environment.pathRefinement.state = .idle
            // Restore the user's original range first so the restoring loadDay uses it.
            if let range = originalRange {
                environment.selectedRange = range
            }
            // Restore the user's original day so they land back where they were.
            if let original = originalSelectedDay {
                Task { await environment.selectDay(original) }
            }
        }
    }

    // MARK: - UI

    private var isRunning: Bool {
        switch phase {
        case .preparing, .processing: true
        case .finished, .cancelled, .aborted: false
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 14) {
            switch phase {
            case .preparing:
                ProgressView().controlSize(.large)
                Text("Preparing…")
                    .font(.headline)

            case let .processing(label, completed, total, refined, skipped, etaSec, pausing):
                ProgressView(value: Double(completed), total: max(Double(total), 1))
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 4)
                Text("\(completed) of \(total) days · \(percent(completed, total))%")
                    .font(.headline)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if pausing {
                    Text("Pausing for routing rate limit…")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let etaSec {
                    Text("ETA \(SimilarityRating.formatDuration(etaSec))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("ETA --:--")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Refined \(refined) · Skipped \(skipped)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case let .finished(refined, skipped):
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.green)
                Text("History refined")
                    .font(.title3.weight(.semibold))
                Text("\(refined) trips refined · \(skipped) skipped")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case let .cancelled(refined, skipped):
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Stopped")
                    .font(.title3.weight(.semibold))
                Text("\(refined) refined · \(skipped) skipped before cancel")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case let .aborted(refined, skipped, message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Stopped early")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("\(refined) refined · \(skipped) skipped before stopping")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if isRunning {
                Button(role: .cancel) {
                    task?.cancel()
                    let c = phase.counts
                    phase = .cancelled(refined: c.refined, skipped: c.skipped)
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                Spacer()
            } else {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .liquidGlassPanel()
    }

    private func percent(_ done: Int, _ total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(done) / Double(total)) * 100)
    }

    private func dayLabel(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    // MARK: - Loop

    @MainActor
    private func runHistory() async {
        await environment.refresh()
        let allDays = days
        guard !allDays.isEmpty else {
            phase = .finished(refined: 0, skipped: 0)
            return
        }
        let policy = ThrottlePolicy.google
        var refined = 0
        var skipped = 0
        var dayDurations: [TimeInterval] = []
        var requestsSinceBatchPause = 0
        var consecutiveTransient = 0

        for (index, day) in allDays.enumerated() {
            if Task.isCancelled { break }
            let dayStartedAt = Date()
            await environment.selectDay(day)

            let remaining = allDays.count - index
            let eta = etaSeconds(durations: dayDurations, remainingDays: remaining)
            phase = .processing(
                dayLabel: dayLabel(day),
                completedDays: index,
                totalDays: allDays.count,
                refinedTrips: refined,
                skippedTrips: skipped,
                etaSeconds: eta,
                pausing: false
            )

            let outcome = await runOneDay(
                policy: policy,
                refinedSoFar: &refined,
                skippedSoFar: &skipped,
                completedDays: index,
                totalDays: allDays.count,
                dayLabel: dayLabel(day),
                etaSeconds: eta,
                requestsSinceBatchPause: &requestsSinceBatchPause,
                consecutiveTransient: &consecutiveTransient
            )
            refined = outcome.refined
            skipped = outcome.skipped
            if outcome.aborted {
                phase = .aborted(
                    refined: refined,
                    skipped: skipped,
                    message: abortMessage()
                )
                return
            }

            dayDurations.append(Date().timeIntervalSince(dayStartedAt))

            // Between-day spacer so even a single-request day doesn't hammer Apple.
            try? await Task.sleep(for: .seconds(2))
        }

        if Task.isCancelled {
            phase = .cancelled(refined: refined, skipped: skipped)
        } else {
            phase = .finished(refined: refined, skipped: skipped)
        }
    }

    /// User-facing reason the run stopped early, derived from the controller's last error.
    @MainActor
    private func abortMessage() -> String {
        switch environment.pathRefinement.lastError {
        case .attestationUnavailable:
            "This build can't reach the routing service. Reinstall from the App Store, then run again."
        case .network, .throttledGoogle:
            "Routing kept failing (no connection or rate-limited). Try again later."
        default:
            "Couldn't save a refinement. Nothing was skipped — run again to resume."
        }
    }

    /// Outcome of attempting to refine a single trip/journey in the runner.
    private enum TripOutcome {
        /// Candidate applied. Advance to the next trip.
        case refined
        /// Genuine no-route outcome — a skip row was written. Advance to the next trip.
        case skipped
        /// Transient failure (network / throttle). Back off and retry the same trip.
        case retry(RoutingError)
        /// Configuration or DB-write failure. Abort the whole run without writing a skip.
        case abort
    }

    /// Refines every refinable trip on the currently-loaded day. Mutates the outer
    /// `refined` / `skipped` counters so the UI updates incrementally between trips.
    /// Returns `aborted: true` when a fatal error (missing API key, DB write failure, or
    /// too many consecutive transient failures) should stop the entire history run.
    @MainActor
    private func runOneDay(
        policy: ThrottlePolicy,
        refinedSoFar: inout Int,
        skippedSoFar: inout Int,
        completedDays: Int,
        totalDays: Int,
        dayLabel: String,
        etaSeconds: TimeInterval?,
        requestsSinceBatchPause: inout Int,
        consecutiveTransient: inout Int
    ) async -> (refined: Int, skipped: Int, aborted: Bool) {
        // Each trip is fetched at most once per run even if a skip write fails — otherwise a
        // failed skip INSERT (e.g. disk full) would let `pickNextRefinable` return the same
        // trip forever and the runner would hammer the routing API in a loop.
        var attempted = Set<UUID>()

        while !Task.isCancelled {
            await environment.loadDay()
            guard let next = pickNextRefinable(attempted: attempted) else { break }
            let journey = environment.dayJourneysByAnchor[next.id]
            // Mark the anchor and every journey member attempted up front, so an unroutable
            // journey isn't re-fetched once per member leg.
            attempted.insert(next.id)
            if let journey {
                for member in journey.trips { attempted.insert(member.id) }
            }

            if let journey {
                await environment.pathRefinement.fetch(for: journey)
            } else {
                await environment.pathRefinement.fetch(for: next)
            }
            if Task.isCancelled { break }

            // Throttle: inter-request delay.
            try? await Task.sleep(for: policy.interRequestDelay)
            requestsSinceBatchPause += 1

            let outcome = await classifyAndApply(trip: next, journey: journey)
            switch outcome {
            case .refined:
                consecutiveTransient = 0
                refinedSoFar += 1
                attempted.remove(next.id)   // newly-refined; pickNext now excludes it via refined set
            case .skipped:
                consecutiveTransient = 0
                skippedSoFar += 1
            case let .retry(error):
                consecutiveTransient += 1
                // Give up after repeated transient failures rather than looping forever.
                if consecutiveTransient >= 5 {
                    return (refinedSoFar, skippedSoFar, true)
                }
                // Back off, then retry the SAME trip (don't keep it in `attempted`).
                attempted.remove(next.id)
                if let journey {
                    for member in journey.trips { attempted.remove(member.id) }
                }
                phase = .processing(
                    dayLabel: dayLabel,
                    completedDays: completedDays,
                    totalDays: totalDays,
                    refinedTrips: refinedSoFar,
                    skippedTrips: skippedSoFar,
                    etaSeconds: etaSeconds,
                    pausing: true
                )
                try? await Task.sleep(for: .seconds(backoffSeconds(for: error, policy: policy)))
                requestsSinceBatchPause = 0
                continue   // retry the same trip
            case .abort:
                return (refinedSoFar, skippedSoFar, true)
            }

            phase = .processing(
                dayLabel: dayLabel,
                completedDays: completedDays,
                totalDays: totalDays,
                refinedTrips: refinedSoFar,
                skippedTrips: skippedSoFar,
                etaSeconds: etaSeconds,
                pausing: false
            )

            // Apple batch pause: every N requests, sleep extra.
            if let batchSize = policy.batchSize, requestsSinceBatchPause >= batchSize {
                phase = .processing(
                    dayLabel: dayLabel,
                    completedDays: completedDays,
                    totalDays: totalDays,
                    refinedTrips: refinedSoFar,
                    skippedTrips: skippedSoFar,
                    etaSeconds: etaSeconds,
                    pausing: true
                )
                try? await Task.sleep(for: .seconds(policy.batchPauseSeconds))
                requestsSinceBatchPause = 0
            }
        }
        return (refinedSoFar, skippedSoFar, false)
    }

    /// Inspects the controller's post-fetch state and either applies the best candidate,
    /// records a skip for a genuine no-route outcome, or signals retry/abort for transient
    /// and fatal failures. Never writes a skip row for a failure that isn't the trip's fault.
    @MainActor
    private func classifyAndApply(trip: TripSummary, journey: Journey?) async -> TripOutcome {
        let controller = environment.pathRefinement

        // A typed failure from the fetch tells us whether this is the trip's fault.
        if let error = controller.lastError {
            if error.isTransient { return .retry(error) }
            switch error {
            case .attestationUnavailable:
                // Configuration problem — never burns trips; stop the run so the user can fix it.
                return .abort
            case .cancelled:
                return .abort
            default:
                // Genuine no-route outcome (tooClose / tooFar / noRoutes, or any other
                // per-trip rejection). Record an accurate skip reason.
                markSkipped(trip: trip, journey: journey, reason: skipReason(for: error))
                return .skipped
            }
        }

        guard case let .ready(scored) = controller.state, let best = scored.first else {
            // Ready with no candidates (or any non-failed, non-ready state) — genuine no-route.
            markSkipped(trip: trip, journey: journey, reason: .noCandidates)
            return .skipped
        }

        // Conservative gate: if this is a *car* trip with already-dense GPS samples, only
        // apply when the candidate matches very closely. The user's background GPS captured
        // the real route faithfully; refining would substitute Google's textbook road network
        // and may move the line off the streets actually driven. Manual refine from the trip
        // detail screen is unaffected.
        if shouldPreservePreciseCarTrip(trip: trip, journey: journey, best: best) {
            markSkipped(trip: trip, journey: journey, reason: .lowScore)
            return .skipped
        }

        let ok: Bool
        if let journey {
            ok = await controller.applyJourney(
                candidate: best.candidate,
                score: best.score,
                journey: journey,
                candidateCount: scored.count,
                chosenIndex: 0
            )
        } else {
            ok = await controller.apply(
                candidate: best.candidate,
                score: best.score,
                to: trip,
                candidateCount: scored.count,
                chosenIndex: 0,
                originalPointCount: environment.recordedSamples(forTrip: trip).count
            )
        }
        // Apply failed for a DB reason (not the trip's fault) — abort rather than burn it.
        return ok ? .refined : .abort
    }

    /// Marks the trip skipped, plus every member of a journey (so an unroutable journey
    /// isn't re-fetched once per member leg on the next run).
    @MainActor
    private func markSkipped(trip: TripSummary, journey: Journey?, reason: SkipReason) {
        let controller = environment.pathRefinement
        if let journey {
            for member in journey.trips {
                controller.markSkipped(trip: member, reason: reason)
            }
        } else {
            controller.markSkipped(trip: trip, reason: reason)
        }
    }

    /// Maps a routing failure to its proper skip reason so the skip ledger is accurate.
    private func skipReason(for error: RoutingError) -> SkipReason {
        switch error {
        case .tooClose: .tooShort
        case .tooFar: .tooLong
        default: .noCandidates
        }
    }

    /// Back-off duration for a transient error. Quota throttling recovers slower than a
    /// blip of lost connectivity, so wait longer for it.
    private func backoffSeconds(for error: RoutingError, policy: ThrottlePolicy) -> TimeInterval {
        switch error {
        case .throttledGoogle: max(policy.backoffSeconds, 30)
        default: policy.backoffSeconds
        }
    }

    /// True when the trip (or every leg of a journey) is car-mode AND has dense GPS
    /// samples AND the best candidate isn't a near-perfect match. In that case we leave
    /// the recorded line as-is — Google's route would replace high-fidelity GPS with a
    /// generic road-network reconstruction.
    @MainActor
    private func shouldPreservePreciseCarTrip(
        trip: TripSummary,
        journey: Journey?,
        best: ScoredCandidate
    ) -> Bool {
        let trips = journey?.trips ?? [trip]
        guard trips.allSatisfy({ TripPrecision.isCarMode($0.mode) }) else { return false }

        let samples = trips.flatMap { environment.recordedSamples(forTrip: $0) }
        let durationSeconds = trips.reduce(0.0) { sum, t in
            sum + t.end.date.timeIntervalSince(t.start.date)
        }
        guard TripPrecision.isPrecise(samples: samples, tripDurationSeconds: durationSeconds) else {
            return false
        }

        // Allow only Excellent / Very good matches through. Anything looser means the
        // candidate diverges from where the user actually drove.
        guard let score = best.score else { return true }
        // Fallback reference spans the whole journey (A→B), not just the anchor leg.
        let refStart = journey?.startCoordinate ?? trip.startCoordinate
        let refEnd = journey?.endCoordinate ?? trip.endCoordinate
        let refDist = best.candidate.expectedDistanceMeters
            ?? PolylineDirection.haversineMeters(refStart, refEnd)
        let rating = SimilarityRating.from(
            composite: score.composite,
            referenceDistanceMeters: refDist,
            lenientForDriving: true
        )
        switch rating {
        case .excellent, .veryGood: return false   // close enough to apply
        default: return true                        // preserve recorded
        }
    }

    private func pickNextRefinable(attempted: Set<UUID>) -> TripSummary? {
        guard let database = environment.openDatabase() else { return nil }
        for trip in environment.dayTrips {
            if attempted.contains(trip.id) { continue }
            if environment.dayRefinedActivityIDs.contains(trip.id) { continue }
            if RefinementMode.map(recordedMode: trip.mode) == nil { continue }
            if (try? Persistence.isSkipped(in: database, eventID: trip.id)) == true { continue }
            return trip
        }
        return nil
    }

    private func etaSeconds(
        durations: [TimeInterval],
        remainingDays: Int
    ) -> TimeInterval? {
        guard !durations.isEmpty, remainingDays > 0 else { return nil }
        let avg = durations.reduce(0, +) / Double(durations.count)
        return avg * Double(remainingDays)
    }
}
