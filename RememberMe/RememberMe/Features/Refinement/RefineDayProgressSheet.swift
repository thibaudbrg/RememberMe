import Core
import Persistence
import SwiftUI

/// Sheet that automatically refines every un-refined activity on the selected day,
/// one trip (or one journey when applicable) at a time. Strictly sequential — every
/// iteration reloads `AppEnvironment` so derived sub-activities from the previous
/// journey-level apply are seen by the next pick. Picks the best-scored (sorted first)
/// candidate each time.
struct RefineDayProgressSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case preparing
        case processing(label: String, refined: Int, skipped: Int)
        case finished(refined: Int, skipped: Int)
        case cancelled(refined: Int, skipped: Int)

        var refined: Int {
            switch self {
            case .preparing: 0
            case let .processing(_, r, _): r
            case let .finished(r, _): r
            case let .cancelled(r, _): r
            }
        }
        var skipped: Int {
            switch self {
            case .preparing: 0
            case let .processing(_, _, s): s
            case let .finished(_, s): s
            case let .cancelled(_, s): s
            }
        }
    }

    /// One entry in the visible "what happened" list inside the sheet.
    struct LogEntry: Identifiable, Hashable {
        let id = UUID()
        let label: String
        let succeeded: Bool
    }

    @State private var phase: Phase = .preparing
    @State private var log: [LogEntry] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusCard
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                if !log.isEmpty {
                    Divider().padding(.top, 16)
                    logList
                }

                Spacer(minLength: 0)
                bottomBar
            }
            .navigationTitle("Refine whole day")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isRunning)
        }
        .onAppear {
            guard task == nil else { return }
            task = Task { await runLoop() }
        }
        .onDisappear {
            task?.cancel()
            task = nil
            environment.pathRefinement.state = .idle
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
            case let .processing(label, refined, skipped):
                ProgressView().controlSize(.large)
                Text(label)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Refined \(refined) · Skipped \(skipped)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .finished(refined, skipped):
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.green)
                Text("Day refined")
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
    private var logList: some View {
        List {
            ForEach(log.reversed()) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "arrow.uturn.right.circle")
                        .foregroundStyle(entry.succeeded ? .green : .secondary)
                    Text(entry.label)
                        .font(.callout)
                        .foregroundStyle(entry.succeeded ? .primary : .secondary)
                    Spacer()
                    if !entry.succeeded {
                        Text("skipped")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if isRunning {
                Button(role: .cancel) {
                    task?.cancel()
                    phase = .cancelled(refined: phase.refined, skipped: phase.skipped)
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

    // MARK: - Loop

    @MainActor
    private func runLoop() async {
        await environment.loadDay()

        var refined = 0
        var skipped = 0

        while !Task.isCancelled {
            await environment.loadDay()

            guard let next = pickNextRefinable() else {
                phase = .finished(refined: refined, skipped: skipped)
                return
            }

            phase = .processing(
                label: describe(next),
                refined: refined,
                skipped: skipped
            )
            let journey = environment.dayJourneysByAnchor[next.id]

            if let journey {
                await environment.pathRefinement.fetch(for: journey)
            } else {
                await environment.pathRefinement.fetch(for: next)
            }

            if Task.isCancelled { break }

            let outcome = await applyBestOrSkip(trip: next, journey: journey)
            switch outcome {
            case .refined:
                refined += 1
                log.append(LogEntry(label: describe(next), succeeded: true))
            case .skipped:
                skipped += 1
                log.append(LogEntry(label: describe(next), succeeded: false))
            }
        }

        if Task.isCancelled {
            phase = .cancelled(refined: refined, skipped: skipped)
        }
    }

    private enum Outcome { case refined, skipped }

    private func applyBestOrSkip(trip: TripSummary, journey: Journey?) async -> Outcome {
        let controller = environment.pathRefinement
        if case let .ready(scored) = controller.state, let best = scored.first {
            let success: Bool
            if let journey {
                success = await controller.applyJourney(
                    candidate: best.candidate,
                    score: best.score,
                    journey: journey,
                    candidateCount: scored.count,
                    chosenIndex: 0
                )
            } else {
                success = await controller.apply(
                    candidate: best.candidate,
                    score: best.score,
                    to: trip,
                    candidateCount: scored.count,
                    chosenIndex: 0,
                    originalPointCount: environment.recordedSamples(forTrip: trip).count
                )
            }
            if success { return .refined }
        }
        controller.markSkipped(trip: trip, reason: .noCandidates)
        return .skipped
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

    private func describe(_ trip: TripSummary) -> String {
        let mode = TripStyle.friendlyLabel(for: trip.mode)
        let time = trip.start.date.formatted(date: .omitted, time: .shortened)
        return "\(mode) · \(time)"
    }
}
