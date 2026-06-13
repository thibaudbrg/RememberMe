import OSLog
import SwiftUI
import UIKit

/// `UIApplicationDelegate` adaptor for the SwiftUI app. We need a UIKit delegate
/// because iOS routes background launches — including those triggered by
/// significant-location-change and visit events while our app was terminated — through
/// `application(_:didFinishLaunchingWithOptions:)`. The SwiftUI lifecycle hooks
/// (`.task`) only run once a scene is configured, which can be later than the
/// CoreLocation delivery window.
///
/// Owning `AppEnvironment` and `Settings` here means they're built immediately on
/// any launch, so `LocationTracker` (held inside AppEnvironment) is already a
/// `CLLocationManagerDelegate` when the deferred location event arrives.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let environment = AppEnvironment.live()
    let settings = Settings()
    let premium = PremiumStore()

    private static let log = Logger(subsystem: "com.tibo.rememberme", category: "appdelegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let locationLaunch = launchOptions?[.location] != nil
        Self.log.notice("didFinishLaunching locationLaunch=\(locationLaunch, privacy: .public)")

        // Kick off ensureOpen now so the DB is ready by the time the CLLocationManager
        // delegate (LocationTracker) starts receiving fixes. SwiftUI's .task does the
        // same thing for foreground launches; this is the background-launch belt-and-braces.
        Task { await environment.ensureOpen() }

        // If we relaunched while the device was locked, the DB key (AfterFirstUnlock) can't
        // be read yet, so ensureOpen() leaves `database == nil`. Retry the open the moment
        // protected data becomes available — recovers the tracking session without waiting
        // for the user to foreground the app. ensureOpen() is idempotent once the DB is open.
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [environment] _ in
            Task { @MainActor in await environment.ensureOpen() }
        }

        return true
    }
}
