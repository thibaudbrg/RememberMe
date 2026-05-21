import SwiftUI

@main
struct RememberMeApp: App {
    @State private var environment = AppEnvironment.live()
    @State private var settings = Settings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(settings)
                .task {
                    environment.pathRefinement.bind(settings: settings)
                    await environment.ensureOpen()
                    #if DEBUG
                    await environment.autoImportSampleIfPresent()
                    #endif
                }
        }
    }
}
