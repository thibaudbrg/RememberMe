import Core
import MapKit
import Persistence
import SwiftUI

/// Detail page for one trip: facts, fetch button, candidate list, current state.
struct PathRefinementTripDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Settings.self) private var settings
    let trip: TripSummary
    /// When non-nil, the screen drives a *journey-level* refinement: fetch is A→B for
    /// the whole journey, apply supersedes every member. Nil = single-trip refinement.
    let journey: Journey?

    init(trip: TripSummary, journey: Journey? = nil) {
        self.trip = trip
        self.journey = journey
    }

    private var accentColor: Color { settings.accent.color }
    private var isJourneyMode: Bool { journey != nil }

    @State private var existingRefinement: RefinementRecord?
    /// When set, triggers `.navigationDestination` to push Compare routes. Cleared on
    /// disappear so re-entering this view doesn't auto-re-open the same comparison.
    @State private var pendingCandidates: [ScoredCandidate]?

    private var controller: PathRefinementController { environment.pathRefinement }
    private var recordedSamples: [Coordinate] {
        if let journey {
            return journey.trips.flatMap { environment.recordedSamples(forTrip: $0) }
        }
        return environment.recordedSamples(forTrip: trip)
    }
    /// Refined polyline for the current view: for single-trip mode, the activity's own
    /// `path_points` refinement (if any). For journey mode, concatenated derived-leg
    /// polylines. Empty when nothing's been applied yet.
    private var refinedPolyline: [Coordinate] {
        if let journey {
            return journey.trips.flatMap { environment.dayRefinedPolylines[$0.id] ?? [] }
        }
        return environment.dayRefinedPolylines[trip.id] ?? []
    }
    private var isRefined: Bool {
        if let journey {
            return journey.trips.contains { environment.dayRefinedActivityIDs.contains($0.id) }
        }
        return environment.dayRefinedActivityIDs.contains(trip.id)
    }
    private var refinementMode: RefinementMode? { RefinementMode.map(recordedMode: trip.mode) }
    private var isCycling: Bool { RefinementMode.isCycling(recordedMode: trip.mode) }

    var body: some View {
        List {
            Section {
                MiniMapView(
                    recordedLine: recordedSamples.isEmpty
                        ? [journey?.startCoordinate ?? trip.startCoordinate,
                           journey?.endCoordinate ?? trip.endCoordinate]
                        : recordedSamples,
                    refinedLine: refinedPolyline.count >= 2 ? refinedPolyline : nil,
                    startCoordinate: journey?.startCoordinate ?? trip.startCoordinate,
                    endCoordinate: journey?.endCoordinate ?? trip.endCoordinate,
                    accentColor: accentColor
                )
                .listRowInsets(EdgeInsets())
                .frame(height: 220)
            }

            if let journey {
                journeySummarySection(journey)
            } else {
                singleTripSection
            }

            currentStateSection

            actionSection
        }
        .navigationTitle(isJourneyMode ? "Refine journey" : "Refine path")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            controller.activeTripID = trip.id
            existingRefinement = controller.refinement(for: trip)
            // If we're returning from a pushed Compare routes view, reset state so the
            // Fetch button reappears instead of the "Opening comparison…" placeholder.
            // SwiftUI auto-clears `pendingCandidates` on pop, so we don't touch it here.
            if case .ready = controller.state {
                controller.state = .idle
            }
        }
        .onChange(of: controllerStateID) { _, _ in
            // When the fetch finishes with candidates, push directly into Compare routes
            // instead of showing an interstitial candidate list in this view.
            if case let .ready(scored) = controller.state, !scored.isEmpty {
                pendingCandidates = scored
            }
        }
        .navigationDestination(item: $pendingCandidates) { candidates in
            RefinementMapView(
                trip: trip,
                journey: journey,
                candidates: candidates,
                selectedIndex: 0,
                onApplied: {
                    existingRefinement = controller.refinement(for: trip)
                }
            )
        }
    }

    /// Stable identifier for the controller's current state — used as the value
    /// `.onChange` watches. The raw `FetchState` is Equatable but switch-matching on
    /// it inside `.onChange` is awkward; this collapses it to a string discriminator.
    private var controllerStateID: String {
        switch controller.state {
        case .idle: "idle"
        case .fetching: "fetching"
        case let .ready(scored): "ready:\(scored.count)"
        case let .failed(msg): "failed:\(msg)"
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var singleTripSection: some View {
        Section("Trip") {
            LabeledContent("Mode", value: TripStyle.friendlyLabel(for: trip.mode))
            LabeledContent("Time", value: trip.start.date.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Distance", value: distanceLabel)
            LabeledContent("Samples", value: "\(recordedSamples.count)")
            if isCycling {
                Text("Routed as walking — Apple Maps doesn't model cycling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func journeySummarySection(_ journey: Journey) -> some View {
        Section("Journey") {
            LabeledContent("Legs", value: "\(journey.legCount)")
            LabeledContent(
                "Time",
                value: "\(journey.startTime.date.formatted(date: .omitted, time: .shortened)) → \(journey.endTime.date.formatted(date: .omitted, time: .shortened))"
            )
            LabeledContent("Total duration", value: SimilarityRating.formatDuration(journey.totalDurationSeconds))
            LabeledContent("Total distance", value: formattedDistance(journey.totalDistanceMeters))
            LabeledContent("Samples", value: "\(recordedSamples.count)")
        }
    }

    @ViewBuilder
    private var currentStateSection: some View {
        Section("Current state") {
            if isRefined {
                Label("Refined", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let record = existingRefinement {
                    Text(String(format: "Mean %.0f m · p95 %.0f m", record.similarityMeanMeters, record.similarityP95Meters))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    Task {
                        if await controller.revert(trip: trip) {
                            existingRefinement = nil
                        }
                    }
                } label: {
                    Label("Revert to recorded", systemImage: "arrow.uturn.backward")
                }
            } else {
                Label("Recorded", systemImage: "waveform.path")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            switch controller.state {
            case .idle:
                Button {
                    Task {
                        if let journey {
                            await controller.fetch(for: journey)
                        } else {
                            await controller.fetch(for: trip)
                        }
                    }
                } label: {
                    Label(
                        isJourneyMode
                            ? "Fetch journey routes from \(settings.refinementProvider.label)"
                            : "Fetch routes from \(settings.refinementProvider.label)",
                        systemImage: "arrow.down.circle"
                    )
                }
            case .fetching:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Fetching routes…")
                }
            case let .ready(scored):
                if scored.isEmpty {
                    Text("No candidate routes returned.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            if let journey {
                                await controller.fetch(for: journey)
                            } else {
                                await controller.fetch(for: trip)
                            }
                        }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                } else {
                    // Ready state pushes straight to Compare routes via .navigationDestination.
                    // The row below is a transient state shown for one frame before navigation.
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Opening comparison…")
                    }
                }
            case let .failed(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                Button {
                    Task { await controller.fetch(for: trip) }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var distanceLabel: String {
        let meters = trip.distanceMeters
        if meters < 1_000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1_000)
    }

    private func formattedDistance(_ meters: Double) -> String {
        meters < 1_000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1_000)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        SimilarityRating.formatDuration(seconds)
    }
}

/// Tiny non-interactive map used to preview the trip path on the detail screen. After a
/// refinement, draws both the original samples (dashed orange) and the current refined
/// polyline (solid purple) so the user can see the before/after diff at a glance.
private struct MiniMapView: View {
    /// GPS-recorded polyline (or A→B fallback). Always rendered in `accentColor`.
    let recordedLine: [Coordinate]
    /// Optional refined polyline. When non-nil and ≥ 2 points, rendered in purple on
    /// top of the recorded line so the user sees both at once.
    let refinedLine: [Coordinate]?
    let startCoordinate: Coordinate
    let endCoordinate: Coordinate
    let accentColor: Color

    private var isRefined: Bool { (refinedLine?.count ?? 0) >= 2 }

    var body: some View {
        Map(initialPosition: position) {
            if recordedLine.count >= 2 {
                MapPolyline(coordinates: recordedLine.map(clCoordinate))
                    .stroke(accentColor, lineWidth: 3)
            }
            // Refined is drawn LAST so it sits on top of the recorded line.
            if let refined = refinedLine, refined.count >= 2 {
                MapPolyline(coordinates: refined.map(clCoordinate))
                    .stroke(Color.purple, lineWidth: 4)
            }
            Marker("Start", coordinate: clCoordinate(startCoordinate))
                .tint(.green)
            Marker("End", coordinate: clCoordinate(endCoordinate))
                .tint(.red)
        }
        .mapControls {}
        .allowsHitTesting(false)
        .overlay(alignment: .bottomLeading) {
            if isRefined {
                legend
                    .padding(8)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            LegendDot(color: accentColor, label: "Recorded")
            LegendDot(color: .purple, label: "Refined")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlassPanel(in: Capsule())
    }

    private var position: MapCameraPosition {
        let all = recordedLine + (refinedLine ?? []) + [startCoordinate, endCoordinate]
        guard !all.isEmpty else { return .automatic }
        let lats = all.map(\.latitude)
        let lons = all.map(\.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.005, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.005, (maxLon - minLon) * 1.4)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    private func clCoordinate(_ c: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            LegendLine(color: color, dashed: false)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
        }
    }
}
