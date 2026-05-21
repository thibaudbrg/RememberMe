import Core
import MapKit
import Persistence
import SwiftUI

/// Modal sheet shown when the user taps a visit dot on the map.
/// Header shows the resolved name (resolving on-demand if needed), followed by stats and history.
struct PlaceDetailView: View {
    let marker: VisitMarker

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var resolvedLabel: String?
    @State private var userLabel: String?
    @State private var isResolving = false
    @State private var history: [VisitHistoryItem] = []
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var nearbyPhotos: [GeoPhoto] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    stats
                    photoStrip
                    historyList
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            renameDraft = userLabel ?? ""
                            isRenaming = true
                        } label: {
                            Label(userLabel == nil ? "Rename" : "Edit name", systemImage: "pencil")
                        }
                        if userLabel != nil {
                            Button(role: .destructive) {
                                Task { await commitRename(to: nil) }
                            } label: {
                                Label("Clear custom name", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Place actions")
                }
            }
            .alert("Name this place", isPresented: $isRenaming) {
                TextField("Home, Mum's, …", text: $renameDraft)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) { isRenaming = false }
                Button("Save") {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await commitRename(to: trimmed.isEmpty ? nil : trimmed) }
                }
            } message: {
                Text("Your custom name shows everywhere this place appears.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            history = environment.visitHistory(for: marker.placeID)
            userLabel = marker.userLabel
            await ensureLabel()
            await loadNearbyPhotos()
        }
    }

    private func commitRename(to newLabel: String?) async {
        await environment.setUserLabel(for: marker, label: newLabel)
        userLabel = newLabel
        isRenaming = false
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.title2)
                Text(displayLabel)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                if isResolving {
                    ProgressView().controlSize(.small)
                }
            }
            Text(coordinateText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 16)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            StatCard(label: "Visits", value: "\(marker.visitCount)", symbol: "mappin.and.ellipse")
            StatCard(label: "Last seen", value: relativeMostRecent, symbol: "clock")
            StatCard(label: "Total time", value: totalTimeFormatted, symbol: "hourglass")
        }
    }

    /// Horizontal thumbnail strip of photos taken at this place — across ALL visits, not
    /// just the currently-loaded day. Populated by `loadNearbyPhotos()` on appear.
    @ViewBuilder
    private var photoStrip: some View {
        if !nearbyPhotos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Photos here")
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(nearbyPhotos) { photo in
                            PhotoStripItem(photo: photo, photoLibrary: environment.photoLibrary)
                                .onTapGesture {
                                    environment.focus(.photo(
                                        id: photo.id,
                                        coordinate: photo.coordinate
                                    ))
                                    dismiss()
                                }
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    /// Loads photos near this place's coordinate, then filters them to ones whose creation
    /// time falls inside a recorded visit window. Covers all visits to this place across all
    /// time, so the photo strip works even when the user is browsing a different day.
    private func loadNearbyPhotos() async {
        let library = environment.photoLibrary
        let allNearby = await library.photosNear(marker.coordinate, radiusMeters: 200)
        guard !history.isEmpty else {
            // No visit history loaded yet — just show every nearby photo as a fallback.
            nearbyPhotos = allNearby
            return
        }
        nearbyPhotos = allNearby.filter { photo in
            history.contains { visit in
                photo.creationDate >= visit.start.date.addingTimeInterval(-300)
                    && photo.creationDate <= visit.end.date.addingTimeInterval(300)
            }
        }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent visits")
                .font(.headline)
            if history.isEmpty {
                Text("No visit history recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(history.prefix(50)) { item in
                        VisitHistoryRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { jumpToVisit(item) }
                        if item.id != history.prefix(50).last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    /// Closes the sheet and jumps the rest of the app to the day of the tapped visit row.
    /// Pushes the current state onto the navigation stack so the user can come back.
    private func jumpToVisit(_ item: VisitHistoryItem) {
        let target = item.start.date
        let coordinate = marker.coordinate
        let placeID = marker.placeID
        dismiss()
        Task {
            await environment.navigate(
                toDay: target,
                tab: .timeline,
                focusing: .visit(placeID: placeID, coordinate: coordinate)
            )
        }
    }

    // MARK: - Derived

    /// Display name precedence: user-chosen > reverse-geocoded > placeholder.
    private var displayLabel: String {
        if let userLabel, !userLabel.isEmpty { return userLabel }
        return resolvedLabel ?? marker.resolvedLabel ?? "Resolving…"
    }

    private var coordinateText: String {
        String(
            format: "%.5f, %.5f",
            marker.coordinate.latitude,
            marker.coordinate.longitude
        )
    }

    private var relativeMostRecent: String {
        marker.mostRecentVisit.formatted(.relative(presentation: .named))
    }

    private var totalTimeFormatted: String {
        let total = history.reduce(0) { $0 + $1.duration }
        if total < 3600 {
            return "\(Int(total / 60))m"
        }
        return String(format: "%.1fh", total / 3600)
    }

    private func ensureLabel() async {
        if let cached = marker.resolvedLabel {
            resolvedLabel = cached
            return
        }
        isResolving = true
        resolvedLabel = await environment.resolveLabel(for: marker)
        isResolving = false
    }
}

/// One thumbnail in the PlaceDetailView's horizontal photo strip.
private struct PhotoStripItem: View {
    let photo: GeoPhoto
    let photoLibrary: PhotoLibraryService
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.thinMaterial)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                    }
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: photo.id) {
            image = await photoLibrary.thumbnail(
                for: photo.id,
                size: CGSize(width: 240, height: 240)
            )
        }
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct VisitHistoryRow: View {
    let item: VisitHistoryItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.start.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                Text(durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Google Takeout tags most ordinary places with `semanticType = "Unknown"`; only
            // Home / Work / Search / etc. carry useful labels. Hide the pill in the Unknown
            // case so the row stays clean.
            if shouldShowPill {
                Text(item.semanticType)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var shouldShowPill: Bool {
        let value = item.semanticType.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.lowercased() != "unknown"
    }

    private var durationText: String {
        let seconds = item.duration
        if seconds < 60 {
            return "\(Int(seconds))s"
        }
        if seconds < 3600 {
            return "\(Int(seconds / 60))m"
        }
        let hours = seconds / 3600
        return String(format: hours < 10 ? "%.1fh" : "%.0fh", hours)
    }
}
