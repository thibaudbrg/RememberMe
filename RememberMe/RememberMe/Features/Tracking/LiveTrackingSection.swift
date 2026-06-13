import CoreLocation
import Core
import SwiftUI

/// Settings section for the live background tracker. Two rows:
/// 1. The on/off toggle (gated through onboarding + Always authorization)
/// 2. A status row showing the current tracker state + auth status, with an
///    inline "Open Settings" link when the user has denied or only granted
///    While-In-Use.
struct LiveTrackingSection: View {
    @Environment(Settings.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    /// Lifted to SettingsSheet so the onboarding cover is attached at the top of the
    /// settings NavigationStack, not nested inside a Form Section. Nested sheets here
    /// were getting auto-dismissed by SwiftUI before the user could interact.
    @Binding var showingOnboarding: Bool
    /// Lifted to SettingsSheet for the same nested-sheet reason. Tapping the
    /// "Show log" button flips this true; SettingsSheet attaches the .sheet.
    @Binding var showingLog: Bool

    var body: some View {
        @Bindable var settings = settings

        Section {
            Toggle(isOn: toggleBinding) {
                Label("Live tracking", systemImage: "location.viewfinder")
            }
            statusRow
            Button {
                showingLog = true
            } label: {
                Label("Show log", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Live tracking")
        } footer: {
            Text("When on, RememberMe records your trips and places on this device. Off by default. Requires \"Allow Always\" in Settings.")
        }
    }

    // MARK: - Toggle gating

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { settings.liveTrackingEnabled },
            set: { newValue in
                if newValue {
                    if !settings.liveTrackingOnboarded {
                        // Show the explainer before persisting. The cover's onContinue
                        // is what actually flips enabled + asks for auth.
                        showingOnboarding = true
                    } else {
                        settings.liveTrackingEnabled = true
                        environment.tracker.setEnabled(true)
                        environment.tracker.requestAlwaysAuthorization()
                    }
                } else {
                    settings.liveTrackingEnabled = false
                    environment.tracker.setEnabled(false)
                }
            }
        )
    }

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        if settings.liveTrackingEnabled {
            VStack(alignment: .leading, spacing: 6) {
                authStatusLine
                if environment.tracker.authorizationStatus == .authorizedAlways {
                    if environment.tracker.accuracyAuthorization == .reducedAccuracy {
                        reducedAccuracyWarning
                    }
                    trackerStateLine
                }
            }
        }
    }

    private var reducedAccuracyWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Precise Location is off — trips won't record")
                    .font(.callout)
                Text("Turn on Precise Location for RememberMe in Settings so fixes are accurate enough to log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var authStatusLine: some View {
        switch environment.tracker.authorizationStatus {
        case .authorizedAlways:
            HStack(spacing: 10) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Always authorized").font(.callout)
            }
        case .authorizedWhenInUse:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text("Needs Always permission").font(.callout)
                }
                Text("RememberMe can't record when the app is closed unless you pick \"Allow Always\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Settings") { environment.tracker.openSystemSettings() }
                    .font(.callout.weight(.semibold))
            }
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Location access denied").font(.callout)
                }
                Text("Open Settings and set Location to \"Always\" to start recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Settings") { environment.tracker.openSystemSettings() }
                    .font(.callout.weight(.semibold))
            }
        case .notDetermined:
            HStack(spacing: 10) {
                Circle().fill(.gray).frame(width: 8, height: 8)
                Text("Waiting for permission…").font(.callout)
            }
        @unknown default:
            EmptyView()
        }
    }

    private var trackerStateLine: some View {
        HStack(spacing: 10) {
            Image(systemName: trackerStateIcon(environment.tracker.state))
                .foregroundStyle(.secondary)
            Text("State: \(environment.tracker.state.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func trackerStateIcon(_ state: TrackerState) -> String {
        switch state {
        case .off: "moon.zzz"
        case .deepSleep: "moon.fill"
        case .waking: "sunrise"
        case .tracking: "location.fill"
        case .stationary: "pause.circle"
        }
    }
}
