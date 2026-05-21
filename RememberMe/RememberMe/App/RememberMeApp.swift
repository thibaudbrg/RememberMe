import SwiftUI

@main
struct RememberMeApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    await environment.ensureOpen()
                    #if DEBUG
                    await environment.autoImportSampleIfPresent()
                    #endif
                }
        }
    }
}
