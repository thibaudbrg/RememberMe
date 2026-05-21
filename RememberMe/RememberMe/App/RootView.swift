import SwiftUI

/// Top-level layout: fullscreen map with a persistent bottom drawer.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var drawerPresented = true

    var body: some View {
        MapScreen()
            .ignoresSafeArea()
            .sheet(isPresented: $drawerPresented) {
                HomeDrawerContent()
                    .presentationDetents([.height(140), .medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thickMaterial)
                    .interactiveDismissDisabled()
            }
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
}
