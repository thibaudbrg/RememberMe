import SwiftUI
import UIKit

/// Top-level layout: fullscreen map with a persistent bottom drawer.
/// When `settings.biometricLockEnabled` is on, gates the whole tree behind `LockedView`.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Settings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var drawerPresented = true
    @State private var detent: PresentationDetent = .height(180)
    @State private var hasUnlocked = false

    var body: some View {
        Group {
            if settings.biometricLockEnabled, !hasUnlocked {
                LockedView { hasUnlocked = true }
                    .tint(settings.accent.color)
            } else {
                mapAndDrawer
            }
        }
        .onAppear { applyAppearance() }
        .onChange(of: settings.theme) { _, _ in applyAppearance() }
        .onChange(of: settings.accent) { _, _ in applyAppearance() }
        .onChange(of: scenePhase) { _, phase in
            // Re-arm the lock whenever the app leaves the foreground. Suspension (not
            // termination) is the normal lifecycle, so without this the app stays unlocked
            // for the whole process. Resetting here also swaps `LockedView` in *before* iOS
            // captures the app-switcher snapshot, so the map/timeline aren't exposed there.
            if phase != .active, settings.biometricLockEnabled {
                hasUnlocked = false
            }
        }
    }

    private var mapAndDrawer: some View {
        MapScreen()
            .tint(settings.accent.color)
            .sheet(isPresented: $drawerPresented) {
                DrawerRoot()
                    .tint(settings.accent.color)
                    .presentationDetents(
                        [.height(180), .medium, .large],
                        selection: $detent
                    )
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thickMaterial)
                    .interactiveDismissDisabled()
            }
            .onChange(of: detent) { _, newValue in
                // User dragged the sheet — sync the published drawer size.
                environment.drawerSize = drawerSize(for: newValue)
            }
            .onChange(of: environment.drawerSize) { _, newValue in
                // App code requested a detent change (e.g. tapping a timeline row).
                let target = detentFor(newValue)
                if detent != target {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        detent = target
                    }
                }
            }
    }

    /// Bridges Settings to the active UIWindow. `overrideUserInterfaceStyle = .unspecified`
    /// is the only reliable way to restore live OS-mode tracking for `.auto`, since SwiftUI's
    /// `\.colorScheme` env reads the overridden trait. Setting `tintColor` here also lets the
    /// accent cascade through every sheet UIHostingController, killing the blue-flash on theme flips.
    private func applyAppearance() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        window.overrideUserInterfaceStyle = settings.theme.uiUserInterfaceStyle
        window.tintColor = UIColor(settings.accent.color)
    }

    private func drawerSize(for detent: PresentationDetent) -> AppEnvironment.DrawerSize {
        if detent == .large { return .large }
        if detent == .medium { return .medium }
        return .small
    }

    private func detentFor(_ size: AppEnvironment.DrawerSize) -> PresentationDetent {
        switch size {
        case .small: .height(180)
        case .medium: .medium
        case .large: .large
        }
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
        .environment(Settings())
}
