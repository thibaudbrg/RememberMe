import SwiftUI

/// Top-level drawer content: optional back button + segmented picker swapping between
/// the Overview panel (counts + import) and the Timeline panel (chronological list).
struct DrawerRoot: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var env = environment

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

#Preview {
    DrawerRoot()
        .environment(AppEnvironment.preview())
        .padding(.top)
        .background(.thickMaterial)
}
