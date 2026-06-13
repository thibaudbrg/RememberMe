import SwiftUI

@main
struct RememberMeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.environment)
                .environment(delegate.settings)
                .environment(delegate.premium)
                .task {
                    await delegate.premium.load()
                    await delegate.environment.ensureOpen()
                    #if DEBUG
                    await delegate.environment.autoImportSampleIfPresent()
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    // Retry the background geocoding trickle every time the app comes
                    // foreground. start() is idempotent — no-op if already running or
                    // if everything is resolved.
                    if phase == .active {
                        delegate.environment.geocoder?.start()
                        // Re-read the DB so trips/visits recorded while we were
                        // backgrounded appear immediately (the process can stay
                        // alive for days, so launch-time data goes stale).
                        delegate.environment.tracker.flushNow()
                        Task { await delegate.environment.refresh() }
                    }
                }
        }
    }
}
