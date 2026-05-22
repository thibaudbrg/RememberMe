import Core
import Foundation
import Persistence
import SwiftUI

/// Provider-specific throttle policy for the history-wide refinement runner.
/// Numbers come from rate-limit research:
///   - Google Directions: ~3 000 QPM cap. 100 ms inter-request keeps us at 10 QPS,
///     well below quota; no batch pause needed at that pace.
///   - Apple MKDirections: undocumented but community-reported ~50 calls in a short
///     window before `MKError.loadingThrottled`. 400 ms inter-request + 60 s batch
///     pause every 40 calls + 60 s back-off on a thrown throttle.
struct ThrottlePolicy {
    let interRequestDelay: Duration
    /// nil = no batch pause needed.
    let batchSize: Int?
    let batchPauseSeconds: TimeInterval
    let backoffSeconds: TimeInterval

    static func forProvider(_ provider: RefinementProvider) -> ThrottlePolicy {
        switch provider {
        case .google:
            ThrottlePolicy(
                interRequestDelay: .milliseconds(100),
                batchSize: nil,
                batchPauseSeconds: 0,
                backoffSeconds: 5
            )
        case .apple:
            ThrottlePolicy(
                interRequestDelay: .milliseconds(400),
                batchSize: 40,
                batchPauseSeconds: 60,
                backoffSeconds: 60
            )
        }
    }
}

/// Iterates the given list of days and runs the per-day refinement loop on each — picking
/// the best-scored candidate every time. Throttled per the chosen provider's policy.
/// `days` is the exact set to iterate (caller-supplied); callers pass `daysWithData` for the
/// settings "refine entire history" flow, or a filtered subset for week / month / single-day.
struct RefineHistoryProgressSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Settings.self) private var settings
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

        var counts: (refined: Int, skipped: Int) {
            switch self {
            case .preparing: (0, 0)
            case let .processing(_, _, _, r, s, _, _): (r, s)
            case let .finished(r, s): (r, s)
            case let .cancelled(r, s): (r, s)
            }
        }
    }

    @State private var phase: Phase = .preparing
    @State private var task: Task<Void, Never>?
    /// Set to the user's original selectedDay on appear so we can restore it on exit
    /// — the runner mutates `environment.selectedDay` to scrub through days.
    @State private var originalSelectedDay: Date?

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
            task = Task { await runHistory() }
        }
        .onDisappear {
            task?.cancel()
            task = nil
            environment.pathRefinement.state = .idle
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
        case .finished, .cancelled: false
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
                    Text("Pausing for Apple Maps rate limit…")
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
        let policy = ThrottlePolicy.forProvider(settings.refinementProvider)
        var refined = 0
        var skipped = 0
        var dayDurations: [TimeInterval] = []
        var requestsSinceBatchPause = 0

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
                requestsSinceBatchPause: &requestsSinceBatchPause
            )
            refined = outcome.refined
            skipped = outcome.skipped

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

    /// Refines every refinable trip on the currently-loaded day. Mutates the outer
    /// `refined` / `skipped` counters so the UI updates incrementally between trips.
    @MainActor
    private func runOneDay(
        policy: ThrottlePolicy,
        refinedSoFar: inout Int,
        skippedSoFar: inout Int,
        completedDays: Int,
        totalDays: Int,
        dayLabel: String,
        etaSeconds: TimeInterval?,
        requestsSinceBatchPause: inout Int
    ) async -> (refined: Int, skipped: Int) {
        while !Task.isCancelled {
            await environment.loadDay()
            guard let next = pickNextRefinable() else { break }
            let journey = environment.dayJourneysByAnchor[next.id]

            if let journey {
                await environment.pathRefinement.fetch(for: journey)
            } else {
                await environment.pathRefinement.fetch(for: next)
            }
            if Task.isCancelled { break }

            // Throttle: inter-request delay.
            try? await Task.sleep(for: policy.interRequestDelay)
            requestsSinceBatchPause += 1

            // If the controller surfaced an Apple-throttled error, back off and retry
            // the same trip without marking it skipped.
            if case let .failed(msg) = environment.pathRefinement.state,
               msg.contains(RoutingError.throttledSentinel)
            {
                phase = .processing(
                    dayLabel: dayLabel,
                    completedDays: completedDays,
                    totalDays: totalDays,
                    refinedTrips: refinedSoFar,
                    skippedTrips: skippedSoFar,
                    etaSeconds: etaSeconds,
                    pausing: true
                )
                try? await Task.sleep(for: .seconds(policy.backoffSeconds))
                requestsSinceBatchPause = 0
                continue   // retry the same trip
            }

            // Apply best candidate or skip.
            let success = await applyBestOrSkip(trip: next, journey: journey)
            if success { refinedSoFar += 1 } else { skippedSoFar += 1 }
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
        return (refinedSoFar, skippedSoFar)
    }

    /// True on a successful apply, false on skip (no candidates, fetch failed, etc.).
    @MainActor
    private func applyBestOrSkip(trip: TripSummary, journey: Journey?) async -> Bool {
        let controller = environment.pathRefinement
        if case let .ready(scored) = controller.state, let best = scored.first {
            // Conservative gate: if this is a *car* trip with already-dense GPS samples,
            // only apply when the candidate matches very closely. The user's background
            // GPS captured the real route faithfully; refining would substitute Google's
            // textbook road network and may move the line off the streets actually
            // driven. Manual refine from the trip detail screen is unaffected.
            if shouldPreservePreciseCarTrip(trip: trip, journey: journey, best: best) {
                controller.markSkipped(trip: trip, reason: .lowScore)
                return false
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
            if ok { return true }
        }
        controller.markSkipped(trip: trip, reason: .noCandidates)
        return false
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
        let refDist = best.candidate.expectedDistanceMeters
            ?? PolylineDirection.haversineMeters(trip.startCoordinate, trip.endCoordinate)
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

    private func pickNextRefinable() -> TripSummary? {
        guard let database = environment.openDatabase() else { return nil }
        for trip in environment.dayTrips {
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
