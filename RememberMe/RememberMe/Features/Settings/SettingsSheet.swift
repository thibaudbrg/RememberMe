import SwiftUI
import UniformTypeIdentifiers

/// Modal sheet with appearance, accent color, and data-management actions.
struct SettingsSheet: View {
    @Environment(Settings.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(PremiumStore.self) private var premium
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

    @State private var showingPaywall = false
    @State private var postImportSkippedOlder = 0
    @State private var showingRefineHistoryConfirm = false
    @State private var showingRefineHistoryRun = false
    @State private var showingTrackingOnboarding = false
    @State private var showingTrackingLog = false

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
                    if environment.photoLibrary.authorization == .limited {
                        Button {
                            environment.photoLibrary.presentLimitedLibraryPicker()
                        } label: {
                            Label("Manage selected photos", systemImage: "photo.badge.plus")
                        }
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

                LiveTrackingSection(
                    showingOnboarding: $showingTrackingOnboarding,
                    showingLog: $showingTrackingLog
                )

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
                    Label("Long-press a trip in the timeline to refine it.", systemImage: "hand.tap")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        if premium.isPremium {
                            showingRefineHistoryConfirm = true
                        } else {
                            showingPaywall = true
                        }
                    } label: {
                        Label("Refine entire history", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("Refine routes")
                } footer: {
                    Text("Snaps noisy GPS traces to real roads, rails and paths. Only a trip's start and end (rounded to ~11 m) leave your device — sent to RememberMe's routing service, then Google. No identity, no full track. Premium feature.")
                }

                #if DEBUG
                Section {
                    Toggle("Force Premium", isOn: Binding(
                        get: { premium.debugForcePremium },
                        set: { premium.debugForcePremium = $0 }
                    ))
                } header: {
                    Text("Debug")
                } footer: {
                    Text("DEBUG builds only — unlocks Premium features without a purchase so the routing proxy / App Attest path can be tested. Compiled out of release builds.")
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .background(
                DocumentPicker(isPresented: $showingFileImporter, contentTypes: [.json]) { url in
                    handleFilePick(url)
                }
            )
            .background(
                DocumentPicker(
                    isPresented: $showingEncryptedImporter,
                    contentTypes: [UTType(filenameExtension: "rmex") ?? .data, .data]
                ) { url in
                    handleEncryptedFilePick(url)
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
                .disabled(exportPassphrase.count < 8 || exportPassphrase != exportPassphraseConfirm)
            } message: {
                Text("Use at least 8 characters. Choose something memorable — there is no recovery if you forget.")
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
            .sheet(isPresented: $showingPaywall, onDismiss: { postImportSkippedOlder = 0 }) {
                PaywallSheet(
                    contextLine: postImportSkippedOlder > 0
                        ? "Imported the last 14 days. \(postImportSkippedOlder) older records were skipped — unlock Premium, then import the same file again to fill in the rest."
                        : nil
                )
            }
            .sheet(isPresented: $showingTrackingLog) {
                LiveTrackingLogSheet()
            }
            .fullScreenCover(isPresented: $showingTrackingOnboarding) {
                LiveTrackingOnboardingSheet(
                    onContinue: {
                        settings.liveTrackingOnboarded = true
                        settings.liveTrackingEnabled = true
                        environment.tracker.setEnabled(true)
                        environment.tracker.requestAlwaysAuthorization()
                        showingTrackingOnboarding = false
                    },
                    onCancel: {
                        settings.liveTrackingEnabled = false
                        showingTrackingOnboarding = false
                    }
                )
            }
            .alert("Refine entire history?", isPresented: $showingRefineHistoryConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Refine", role: .destructive) {
                    showingRefineHistoryRun = true
                }
            } message: {
                Text(refineHistoryWarningText)
            }
            .sheet(isPresented: $showingRefineHistoryRun) {
                RefineHistoryProgressSheet(days: environment.daysWithData, title: "Refine history")
                    .presentationDetents([.large])
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thickMaterial)
    }

    private var refineHistoryWarningText: String {
        let dayCount = environment.daysWithData.count
        return """
        \(dayCount) days will be processed, newest first.

        Some trips may be skipped — sparse GPS, network errors, or modes the routing service doesn't cover. This may take a long time. You can cancel at any moment.
        """
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

    private func handleFilePick(_ url: URL) {
        Task {
            await environment.importTakeout(from: url, cutoff: premium.importCutoff)
            if case let .completed(_, _, skippedOlder) = environment.importStatus,
               skippedOlder > 0 {
                postImportSkippedOlder = skippedOlder
                showingPaywall = true
            }
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

    private func handleEncryptedFilePick(_ url: URL) {
        pendingImportURL = url
        importPassphrase = ""
        showingImportPassphrase = true
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
