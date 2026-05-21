import SwiftUI
import UniformTypeIdentifiers

/// Modal sheet with appearance, accent color, and data-management actions.
struct SettingsSheet: View {
    @Environment(Settings.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var showingFileImporter = false
    @State private var lastImportError: String?

    // Encrypted export/import state — all sheet-local, no persistence.
    @State private var exportPassphrase = ""
    @State private var exportPassphraseConfirm = ""
    @State private var showingExportPassphrase = false
    @State private var showingExportShareURL: URL?
    @State private var showingEncryptedImporter = false
    @State private var pendingImportURL: URL?
    @State private var importPassphrase = ""
    @State private var showingImportPassphrase = false

    @State private var showingAlphaConfirmation = false
    @State private var showingGoogleConfirmation = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Map") {
                    Toggle(isOn: $settings.showDirectionArrows) {
                        Label("Direction arrows", systemImage: "arrowtriangle.up.fill")
                    }
                    Toggle(isOn: $settings.showPhotosOnMap) {
                        Label("Photos on map", systemImage: "photo.on.rectangle.angled")
                    }
                    .onChange(of: settings.showPhotosOnMap) { _, isOn in
                        Task { await environment.loadDayPhotos(enabled: isOn) }
                    }
                }

                Section {
                    Toggle(isOn: $settings.biometricLockEnabled) {
                        Label("Require Face ID", systemImage: "faceid")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("When on, RememberMe asks for Face ID at launch before showing your history.")
                }

                Section("Trip color") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(minimum: 36)), count: 6),
                        spacing: 12
                    ) {
                        ForEach(AppAccent.allCases) { accent in
                            AccentSwatch(
                                accent: accent,
                                isSelected: settings.accent == accent,
                                onPick: { settings.accent = accent }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    importRow
                    if let lastImportError {
                        Text(lastImportError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    statsRow
                } header: {
                    Text("Data")
                }

                Section {
                    encryptedExportRow
                    encryptedImportRow
                    encryptedStatusRow
                } header: {
                    Text("Encrypted backup")
                } footer: {
                    Text("Backups never leave your device unless you share them. The file is encrypted with your passphrase using Argon2id + ChaCha20-Poly1305. Lose the passphrase, lose the backup — there's no recovery.")
                }

                Section {
                    Toggle(isOn: $settings.alphaModeEnabled) {
                        Label("Alpha features", systemImage: "flask")
                    }
                    .onChange(of: settings.alphaModeEnabled) { _, isOn in
                        if isOn, !settings.alphaModeAcknowledged {
                            showingAlphaConfirmation = true
                        }
                    }
                    if settings.alphaModeEnabled {
                        Picker("Routing provider", selection: $settings.refinementProvider) {
                            ForEach(RefinementProvider.allCases) { provider in
                                Text(provider.label).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: settings.refinementProvider) { _, newValue in
                            if newValue == .google, !settings.googleRoutingAcknowledged {
                                showingGoogleConfirmation = true
                            }
                        }

                        switch settings.refinementProvider {
                        case .apple:
                            Label("Transit isn't supported — bus / train / subway trips will be skipped.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .google:
                            SecureField("Google Directions API key", text: $settings.googleDirectionsAPIKey)
                                .textContentType(.password)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            if settings.googleDirectionsAPIKey.isEmpty {
                                Label("Paste your key from Google Cloud Console.", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Label("Long-press a trip in the timeline to refine it.", systemImage: "hand.tap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Alpha features")
                } footer: {
                    Text(alphaFooterText)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .background(
                DocumentPicker(isPresented: $showingFileImporter, contentTypes: [.json]) { result in
                    handleFilePick(result)
                }
            )
            .background(
                DocumentPicker(
                    isPresented: $showingEncryptedImporter,
                    contentTypes: [UTType(filenameExtension: "rmex") ?? .data, .data]
                ) { result in
                    handleEncryptedFilePick(result)
                }
            )
            .alert("Choose a passphrase", isPresented: $showingExportPassphrase) {
                SecureField("Passphrase", text: $exportPassphrase)
                SecureField("Confirm", text: $exportPassphraseConfirm)
                Button("Cancel", role: .cancel) {
                    exportPassphrase = ""
                    exportPassphraseConfirm = ""
                }
                Button("Export") {
                    runExport()
                }
                .disabled(exportPassphrase.isEmpty || exportPassphrase != exportPassphraseConfirm)
            } message: {
                Text("Used to encrypt the backup. Choose something memorable — there is no recovery if you forget.")
            }
            .alert("Enter passphrase", isPresented: $showingImportPassphrase) {
                SecureField("Passphrase", text: $importPassphrase)
                Button("Cancel", role: .cancel) {
                    importPassphrase = ""
                    pendingImportURL = nil
                }
                Button("Restore") { runImport() }
                    .disabled(importPassphrase.isEmpty)
            } message: {
                Text("The same passphrase you used when exporting this file.")
            }
            .sheet(item: $showingExportShareURL) { url in
                ShareSheet(items: [url])
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingAlphaConfirmation) {
                AlphaConfirmationSheet(alphaEnabled: $settings.alphaModeEnabled)
            }
            .sheet(isPresented: $showingGoogleConfirmation) {
                GoogleConfirmationSheet(selectedProvider: $settings.refinementProvider)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var alphaFooterText: String {
        switch settings.refinementProvider {
        case .apple:
            "Apple Maps via MKDirections. Endpoint coordinates (rounded to ~11 m) leave your device; no API key, no Apple ID binding. Transit polylines are not exposed by Apple's API."
        case .google:
            "Google Directions API. Endpoint coordinates (rounded to ~11 m) plus your personal API key leave your device on every request. Google sees these calls under your Google Cloud account — not the app developer's."
        }
    }

    // MARK: - Plaintext Takeout import row

    @ViewBuilder
    private var importRow: some View {
        switch environment.importStatus {
        case let .running(stage):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stage).font(.callout)
            }
        default:
            Button {
                lastImportError = nil
                showingFileImporter = true
            } label: {
                Label("Import Google Takeout", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var statsRow: some View {
        let counts = environment.counts
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(counts.total) events stored")
                .font(.callout)
            Text("\(counts.activities) activities · \(counts.visits) visits · \(counts.paths) paths")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handleFilePick(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            Task { await environment.importTakeout(from: url) }
        case let .failure(error):
            lastImportError = error.localizedDescription
        }
    }

    // MARK: - Encrypted export rows

    private var encryptedExportRow: some View {
        Button {
            exportPassphrase = ""
            exportPassphraseConfirm = ""
            showingExportPassphrase = true
        } label: {
            Label("Export encrypted backup", systemImage: "lock.shield")
        }
        .disabled(environment.counts.total == 0 || isExportBusy)
    }

    private var encryptedImportRow: some View {
        Button {
            showingEncryptedImporter = true
        } label: {
            Label("Restore from encrypted backup", systemImage: "arrow.uturn.backward")
        }
        .disabled(isExportBusy)
    }

    @ViewBuilder
    private var encryptedStatusRow: some View {
        switch environment.exportStatus {
        case .idle:
            EmptyView()
        case let .running(stage):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stage).font(.callout)
            }
        case let .completed(_, eventCount):
            Text("Last operation: \(eventCount) events.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var isExportBusy: Bool {
        if case .running = environment.exportStatus { return true }
        return false
    }

    private func runExport() {
        let passphrase = exportPassphrase
        exportPassphrase = ""
        exportPassphraseConfirm = ""
        Task {
            if let url = await environment.exportEncrypted(passphrase: passphrase) {
                showingExportShareURL = url
            }
        }
    }

    private func handleEncryptedFilePick(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            pendingImportURL = url
            importPassphrase = ""
            showingImportPassphrase = true
        case let .failure(error):
            environment.exportStatus = .failed(message: error.localizedDescription)
        }
    }

    private func runImport() {
        guard let url = pendingImportURL else { return }
        let passphrase = importPassphrase
        importPassphrase = ""
        pendingImportURL = nil
        Task {
            _ = await environment.importEncrypted(from: url, passphrase: passphrase)
        }
    }
}

/// Trivial `URL: Identifiable` so we can drive `.sheet(item:)` from an optional URL.
extension URL: Identifiable {
    public var id: String { absoluteString }
}

/// Wraps `UIActivityViewController` so we can hand the export file to AirDrop / Files /
/// Messages without writing a custom UI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct AccentSwatch: View {
    let accent: AppAccent
    let isSelected: Bool
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            ZStack {
                Circle()
                    .fill(accent.color)
                    .frame(width: 32, height: 32)
                if isSelected {
                    Circle()
                        .stroke(.primary, lineWidth: 2)
                        .frame(width: 40, height: 40)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accent.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    SettingsSheet()
        .environment(Settings())
        .environment(AppEnvironment.preview())
}
