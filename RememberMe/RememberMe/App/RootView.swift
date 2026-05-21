import SwiftUI

/// Top-level layout: fullscreen map with a persistent bottom drawer.
/// When `settings.biometricLockEnabled` is on, gates the whole tree behind `LockedView`.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Settings.self) private var settings
    @State private var drawerPresented = true
    @State private var detent: PresentationDetent = .height(180)
    @State private var hasUnlocked = false

    var body: some View {
        Group {
            if settings.biometricLockEnabled, !hasUnlocked {
                LockedView { hasUnlocked = true }
                    .tint(settings.accent.color)
                    .preferredColorScheme(settings.theme.colorScheme)
            } else {
                mapAndDrawer
            }
        }
    }

    private var mapAndDrawer: some View {
        MapScreen()
            .tint(settings.accent.color)
            .preferredColorScheme(settings.theme.colorScheme)
            .sheet(isPresented: $drawerPresented) {
                DrawerRoot()
                    .tint(settings.accent.color)
                    .preferredColorScheme(settings.theme.colorScheme)
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
