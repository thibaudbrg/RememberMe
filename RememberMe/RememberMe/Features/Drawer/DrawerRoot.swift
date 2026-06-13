import SwiftUI
import UniformTypeIdentifiers

/// Top-level drawer content: optional back button + segmented picker swapping between
/// the Overview panel (counts + import) and the Timeline panel (chronological list).
struct DrawerRoot: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(PremiumStore.self) private var premium
    @State private var showingSettings = false
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var postImportSkippedOlder = 0
    @State private var showingPostImportPaywall = false

    var body: some View {
        @Bindable var env = environment

        Group {
            if environment.counts.total == 0 {
                EmptyDataView(
                    status: environment.importStatus,
                    error: importError,
                    showsFreeTierNote: !premium.isPremium,
                    onImport: {
                        importError = nil
                        showingImporter = true
                    },
                    onOpenSettings: { showingSettings = true }
                )
            } else {
                VStack(spacing: 20) {
                    HStack(spacing: 10) {
                        if environment.canGoBack {
                            Button {
                                Task { await environment.goBack() }
                            } label: {
                                Label("Back", systemImage: "chevron.backward")
                                    .labelStyle(.iconOnly)
                                    .font(.body.weight(.semibold))
                                    .padding(8)
                                    .background(.thinMaterial, in: Circle())
                            }
                            .accessibilityLabel("Go back")
                            .transition(.opacity)
                        }

                        Picker("Tab", selection: $env.drawerTab) {
                            Text("Timeline").tag(AppEnvironment.DrawerTab.timeline)
                            Text("Photos").tag(AppEnvironment.DrawerTab.photos)
                            Text("Insights").tag(AppEnvironment.DrawerTab.insights)
                        }
                        .pickerStyle(.segmented)
                        .padding(4)
                        .liquidGlassPanel(in: Capsule())
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .animation(.easeInOut(duration: 0.2), value: environment.canGoBack)

                    switch environment.drawerTab {
                    case .timeline:
                        TimelineDrawerContent()
                    case .photos:
                        PhotosDrawerContent()
                    case .insights:
                        InsightsDrawerContent()
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
        }
        .background(
            DocumentPicker(isPresented: $showingImporter, contentTypes: [.json]) { url in
                Task {
                    await environment.importTakeout(from: url, cutoff: premium.importCutoff)
                    if case let .completed(_, _, skippedOlder) = environment.importStatus,
                       skippedOlder > 0 {
                        postImportSkippedOlder = skippedOlder
                        showingPostImportPaywall = true
                    }
                }
            }
        )
        .sheet(isPresented: $showingPostImportPaywall) {
            PaywallSheet(
                contextLine: "Imported the last 14 days. \(postImportSkippedOlder) older records were skipped — unlock Premium, then import the same file again to fill in the rest."
            )
        }
    }
}

/// Empty-state shown in the drawer when the DB has zero events. Matches the rest of the
/// drawer's material/capsule aesthetic — no full-bleed blue buttons, no truncated text.
private struct EmptyDataView: View {
    @Environment(AppEnvironment.self) private var environment
    let status: AppEnvironment.ImportStatus
    let error: String?
    let showsFreeTierNote: Bool
    let onImport: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        // Hide the icon disc at the small detent (~180 pt) — disc + text + button
        // overflows that height and the disc would get clipped by the top edge.
        let showIcon = environment.drawerSize != .small
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: showIcon ? 18 : 12) {
                if showIcon {
                    // Soft material disc behind the icon — visually anchors the empty
                    // state without an aggressive coloured fill.
                    ZStack {
                        Circle()
                            .fill(.thinMaterial)
                            .frame(width: 64, height: 64)
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 4) {
                    Text("No history yet")
                        .font(.title3.weight(.semibold))
                    Text("Import your Google Takeout to fill in the map.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)

                actionSection

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var actionSection: some View {
        switch status {
        case let .running(stage):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                MaterialCapsuleButton(
                    title: "Try again",
                    systemImage: "arrow.clockwise",
                    action: onImport
                )
            }
        default:
            VStack(spacing: 10) {
                MaterialCapsuleButton(
                    title: "Import Google Takeout",
                    systemImage: "square.and.arrow.down",
                    action: onImport
                )
                if showsFreeTierNote {
                    Text("Free imports the last 14 days — Premium unlocks your full history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Button(action: onOpenSettings) {
                    Text("Or open Settings")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Capsule button matching the floating map buttons + drawer picker — thin material
/// background, tint-coloured label, hairline tint border for definition.
private struct MaterialCapsuleButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(.tint.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DrawerRoot()
        .environment(AppEnvironment.preview())
        .padding(.top)
        .background(.thickMaterial)
}
