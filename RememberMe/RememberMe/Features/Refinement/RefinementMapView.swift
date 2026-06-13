import Core
import MapKit
import Persistence
import SwiftUI

/// Full-screen comparison map for one trip's refinement choices. Draws the recorded GPS
/// samples (when present) plus **all** candidate routes returned by the routing service,
/// each in a distinct color. The user can switch which candidate is selected; Apply commits it.
struct RefinementMapView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let trip: TripSummary
    /// When non-nil, the apply path runs as a journey-level refinement (supersedes every
    /// member of the journey) instead of a single-trip swap.
    let journey: Journey?
    let candidates: [ScoredCandidate]
    let onApplied: () -> Void

    @State private var selectedIndex: Int
    @State private var position: MapCameraPosition = .automatic
    @State private var applying = false
    /// Recorded GPS samples for the trip/journey. Populated once in `onAppear` so the full
    /// path-sample scan doesn't re-run on every body evaluation.
    @State private var recordedSamples: [Coordinate] = []

    init(
        trip: TripSummary,
        journey: Journey? = nil,
        candidates: [ScoredCandidate],
        selectedIndex: Int,
        onApplied: @escaping () -> Void
    ) {
        self.trip = trip
        self.journey = journey
        self.candidates = candidates
        self.onApplied = onApplied
        _selectedIndex = State(initialValue: selectedIndex)
    }

    /// Loads the recorded GPS samples to compare against. For a single trip, just that
    /// trip's time-sliced samples. For a journey, concatenate every leg's samples so the
    /// "Recorded" line covers the whole A→B span.
    private func loadRecordedSamples() -> [Coordinate] {
        if let journey {
            return journey.trips.flatMap { environment.recordedSamples(forTrip: $0) }
        }
        return environment.recordedSamples(forTrip: trip)
    }

    /// The journey's A coordinate, or the trip's start when not in journey mode.
    private var startCoordinate: Coordinate {
        journey?.startCoordinate ?? trip.startCoordinate
    }

    /// The journey's B coordinate, or the trip's end when not in journey mode.
    private var endCoordinate: Coordinate {
        journey?.endCoordinate ?? trip.endCoordinate
    }

    private var selectedCandidate: ScoredCandidate { candidates[selectedIndex] }

    var body: some View {
        VStack(spacing: 0) {
            mapBody
            bottomBar
        }
        .navigationTitle("Compare routes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recordedSamples = loadRecordedSamples()
            position = fitPosition
        }
    }

    // MARK: - Map

    @ViewBuilder
    private var mapBody: some View {
        Map(position: $position) {
            // Candidates first (background layer). Non-selected drawn translucently so the
            // selected one and the recorded line both stand out on top.
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, scored in
                if index != selectedIndex, scored.candidate.coordinates.count >= 2 {
                    MapPolyline(coordinates: scored.candidate.coordinates.map(clCoordinate))
                        .stroke(color(for: index).opacity(0.75),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            if selectedCandidate.candidate.coordinates.count >= 2 {
                MapPolyline(coordinates: selectedCandidate.candidate.coordinates.map(clCoordinate))
                    .stroke(color(for: selectedIndex),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            // Recorded line is drawn LAST so the dashed accent line stays visible on top
            // of any candidate that overlaps it. Without this order the candidate stroke
            // buries it. Uses the app's accent color so the recorded path matches what
            // the main map shows for this trip.
            if recordedSamples.count >= 2 {
                MapPolyline(coordinates: recordedSamples.map(clCoordinate))
                    .stroke(settings.accent.color,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            Marker("Start", coordinate: clCoordinate(startCoordinate))
                .tint(.green)
            Marker("End", coordinate: clCoordinate(endCoordinate))
                .tint(.red)
        }
        .overlay(alignment: .topTrailing) {
            legend
                .padding(.trailing, 12)
                .padding(.top, 8)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recordedSamples.count >= 2 {
                legendRow(
                    color: settings.accent.color,
                    label: "Recorded",
                    rating: nil,
                    isBold: false,
                    action: nil
                )
            }
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, scored in
                legendRow(
                    color: color(for: index),
                    label: legendLabel(for: scored, index: index),
                    rating: scored.score.map { score in
                        SimilarityRating.from(
                            composite: score.composite,
                            referenceDistanceMeters: referenceDistance(for: scored.candidate),
                            lenientForDriving: scored.candidate.transportType == .automobile
                        )
                    },
                    isBold: index == selectedIndex,
                    action: { selectedIndex = index }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func legendRow(
        color: Color,
        label: String,
        rating: SimilarityRating?,
        isBold: Bool,
        action: (() -> Void)?
    ) -> some View {
        let content = HStack(spacing: 6) {
            LegendLine(color: color, dashed: false)
            Text(label)
                .font(.caption2.weight(isBold ? .bold : .regular))
                .foregroundStyle(isBold ? Color.primary : .secondary)
            if let rating {
                Text(rating.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(rating.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(rating.color.opacity(0.22), in: Capsule())
            }
        }
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func legendLabel(for scored: ScoredCandidate, index: Int) -> String {
        var parts: [String] = ["Candidate \(index + 1)"]
        if let travel = scored.candidate.expectedTravelTime {
            parts.append(SimilarityRating.formatDuration(travel))
        }
        if let score = scored.score {
            parts.append(String(format: "%.0f m off", score.composite))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Color palette

    /// Pool of distinct hues for candidate routes. Names match `AppAccent.rawValue`
    /// (lowercased), which lets us filter out whichever color the user has chosen as
    /// their app accent — preventing collisions with the "Recorded" line on the map.
    private static let basePalette: [(name: String, color: Color)] = [
        ("purple", .purple),
        ("indigo", .indigo),
        ("pink", .pink),
        ("teal", .teal),
        ("brown", .brown),
        ("orange", .orange),
        ("cyan", .cyan),
        ("mint", .mint),
        ("yellow", .yellow),
        ("red", .red),
        ("green", .green),
        ("blue", .blue),
    ]

    /// Perceptual "neighbor" sets — palette entries that sit so close to the given accent
    /// on screen that users mistake them for the same color as the recorded line. Keyed by
    /// `AppAccent.rawValue` (lowercased). The accent itself is excluded separately, so
    /// these only need to list the *other* near-collisions. Conservatively scoped so we
    /// still have at least 6 distinct candidate hues left for any accent.
    private static let accentNeighbors: [String: Set<String>] = [
        "red": ["pink", "orange"],
        "pink": ["red", "purple"],
        "orange": ["red", "yellow", "brown"],
        "yellow": ["orange", "mint"],
        "green": ["mint", "teal"],
        "mint": ["green", "teal", "cyan"],
        "teal": ["mint", "cyan", "green"],
        "cyan": ["teal", "blue", "mint"],
        "blue": ["cyan", "indigo", "teal"],
        "indigo": ["blue", "purple"],
        "purple": ["indigo", "pink"],
        "brown": ["orange"],
    ]

    private func color(for index: Int) -> Color {
        let accentName = settings.accent.rawValue.lowercased()
        var excluded = Self.accentNeighbors[accentName] ?? []
        excluded.insert(accentName)
        let filtered = Self.basePalette.filter { !excluded.contains($0.name) }
        // Defensive: if a future accent value somehow excludes the whole palette, fall
        // back to the unfiltered list so we never crash on an empty modulo.
        let pool = filtered.isEmpty ? Self.basePalette : filtered
        return pool[index % pool.count].color
    }

    /// Reference distance for ratio-based similarity rating: prefer the candidate's
    /// `expectedDistanceMeters`, fall back to the straight-line A→B endpoint distance.
    private func referenceDistance(for candidate: RouteCandidate) -> Double {
        if let expected = candidate.expectedDistanceMeters, expected > 0 { return expected }
        return PolylineDirection.haversineMeters(startCoordinate, endCoordinate)
    }

    // MARK: - Bottom action bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let journey {
                Text("Refining a \(journey.legCount)-leg journey")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(selectedCandidate.candidate.name ?? "Candidate \(selectedIndex + 1)")
                .font(.headline)

            if let score = selectedCandidate.score {
                Text(String(format: "Mean %.0f m  ·  p95 %.0f m  ·  max %.0f m",
                            score.meanMeters, score.p95Meters, score.maxMeters))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No GPS samples to compare against — applying treats the suggested route as ground truth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    applyCandidate()
                } label: {
                    if applying {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Apply", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(applying)
            }
        }
        .padding(16)
        .liquidGlassPanel()
    }

    // MARK: - Apply logic

    private func applyCandidate() {
        applying = true
        Task {
            let ok: Bool
            if let journey {
                ok = await environment.pathRefinement.applyJourney(
                    candidate: selectedCandidate.candidate,
                    score: selectedCandidate.score,
                    journey: journey,
                    candidateCount: candidates.count,
                    chosenIndex: selectedIndex
                )
            } else {
                ok = await environment.pathRefinement.apply(
                    candidate: selectedCandidate.candidate,
                    score: selectedCandidate.score,
                    to: trip,
                    candidateCount: candidates.count,
                    chosenIndex: selectedIndex,
                    originalPointCount: recordedSamples.count
                )
            }
            applying = false
            if ok {
                onApplied()
                dismiss()
            }
        }
    }

    // MARK: - Geometry

    private var fitPosition: MapCameraPosition {
        let allCandidateCoords = candidates.flatMap { $0.candidate.coordinates }
        let allCoords = recordedSamples + allCandidateCoords
            + [startCoordinate, endCoordinate]
        guard !allCoords.isEmpty else { return .automatic }
        let lats = allCoords.map(\.latitude)
        let lons = allCoords.map(\.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.003, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.003, (maxLon - minLon) * 1.4)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    private func clCoordinate(_ c: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }
}
