import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// What lives inside the bottom drawer in v1: a stats summary and the Import action.
struct HomeDrawerContent: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showingFileImporter = false
    @State private var lastImportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusBanner
                counts
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.clear)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.json, UTType(filenameExtension: "json") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleFilePick(result)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RememberMe")
                .font(.title2.weight(.semibold))
            Text("Your local timeline")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch environment.importStatus {
        case .idle:
            EmptyView()
        case .running(let stage):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stage).font(.callout.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .completed(let importedCounts, let skipped):
            VStack(alignment: .leading, spacing: 4) {
                Label("Imported \(importedCounts.total) events", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
                if skipped > 0 {
                    Text("Skipped \(skipped) malformed record\(skipped == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var counts: some View {
        let current = environment.counts
        return HStack(spacing: 12) {
            CountCard(label: "Activities", value: current.activities, symbol: "figure.walk")
            CountCard(label: "Visits", value: current.visits, symbol: "mappin.and.ellipse")
            CountCard(label: "Paths", value: current.paths, symbol: "point.topleft.down.curvedto.point.bottomright.up")
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                lastImportError = nil
                showingFileImporter = true
            } label: {
                Label("Import Google Takeout", systemImage: "square.and.arrow.down.on.square")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImportRunning)

            if let lastImportError {
                Text(lastImportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var isImportRunning: Bool {
        if case .running = environment.importStatus { return true }
        return false
    }

    // MARK: - File picker handler

    private func handleFilePick(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await environment.importTakeout(from: url) }
        case .failure(let error):
            lastImportError = error.localizedDescription
        }
    }
}

private struct CountCard: View {
    let label: String
    let value: Int
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Text(formatted)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

#Preview {
    HomeDrawerContent()
        .environment(AppEnvironment.preview())
        .padding()
        .background(.thickMaterial)
}
