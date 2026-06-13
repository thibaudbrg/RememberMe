import Foundation
import Observation
import Security
import SwiftUI

/// User-facing preferences. Persisted via `@AppStorage` keys behind the scenes.
@MainActor
@Observable
final class Settings {
    static let themeKey = "settings.theme"
    static let accentKey = "settings.accentColor"
    static let arrowsKey = "settings.showDirectionArrows"
    static let biometricKey = "settings.biometricLock"
    static let photosKey = "settings.showPhotosOnMap"
    static let liveTrackingEnabledKey = "settings.liveTrackingEnabled"
    static let liveTrackingOnboardedKey = "settings.liveTrackingOnboarded"

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    var accent: AppAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Self.accentKey) }
    }

    /// Whether to show the small "direction of travel" chevrons sprinkled along trip
    /// polylines on the map.
    var showDirectionArrows: Bool {
        didSet { UserDefaults.standard.set(showDirectionArrows, forKey: Self.arrowsKey) }
    }

    /// When on, the app prompts for Face ID / Touch ID at launch and stays locked behind a
    /// `LockedView` until the user authenticates. Off by default — user opt-in only.
    var biometricLockEnabled: Bool {
        didSet { UserDefaults.standard.set(biometricLockEnabled, forKey: Self.biometricKey) }
    }

    /// When on, overlay photos from the device library that were taken on the selected day,
    /// at their geo-tagged coordinate. Requires the user to grant Photos read access. Off
    /// by default — accessing photos is a meaningful permission ask.
    var showPhotosOnMap: Bool {
        didSet { UserDefaults.standard.set(showPhotosOnMap, forKey: Self.photosKey) }
    }

    /// Opt-in for the live background location tracker. Off by default; flipping ON
    /// triggers a one-time onboarding sheet and the iOS "Always" authorization prompt.
    /// Setting this to true alone does NOT start tracking — the app gates start on
    /// `CLAuthorizationStatus == .authorizedAlways`.
    var liveTrackingEnabled: Bool {
        didSet { UserDefaults.standard.set(liveTrackingEnabled, forKey: Self.liveTrackingEnabledKey) }
    }

    /// True once the user has seen the live-tracking onboarding sheet. Persisted so the
    /// sheet only appears on the first enable attempt.
    var liveTrackingOnboarded: Bool {
        didSet { UserDefaults.standard.set(liveTrackingOnboarded, forKey: Self.liveTrackingOnboardedKey) }
    }

    init() {
        let themeRaw = UserDefaults.standard.string(forKey: Self.themeKey) ?? AppTheme.auto.rawValue
        theme = AppTheme(rawValue: themeRaw) ?? .auto

        let accentRaw = UserDefaults.standard.string(forKey: Self.accentKey) ?? AppAccent.blue.rawValue
        accent = AppAccent(rawValue: accentRaw) ?? .blue

        if UserDefaults.standard.object(forKey: Self.arrowsKey) == nil {
            showDirectionArrows = true
        } else {
            showDirectionArrows = UserDefaults.standard.bool(forKey: Self.arrowsKey)
        }

        // Default OFF — biometric is opt-in; we never lock users out without explicit consent.
        biometricLockEnabled = UserDefaults.standard.bool(forKey: Self.biometricKey)

        // Default OFF — photo library access is a meaningful permission ask.
        showPhotosOnMap = UserDefaults.standard.bool(forKey: Self.photosKey)

        // Default OFF — live tracking is a meaningful permission ask + battery commitment.
        liveTrackingEnabled = UserDefaults.standard.bool(forKey: Self.liveTrackingEnabledKey)
        liveTrackingOnboarded = UserDefaults.standard.bool(forKey: Self.liveTrackingOnboardedKey)

        Self.scrubLegacyRoutingArtifacts()
    }

    /// One-shot cleanup for installs that used the pre-proxy routing settings: the
    /// user-pasted Google API key (a billing credential — must not linger in the Keychain
    /// now that nothing reads it) and the retired alpha/provider/consent UserDefaults keys.
    private static func scrubLegacyRoutingArtifacts() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "RememberMe.GoogleDirectionsAPIKey",
            kSecAttrAccount as String: "primary",
            kSecAttrSynchronizable as String: false,
        ]
        #if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        SecItemDelete(query as CFDictionary)
        for key in [
            "settings.alphaModeEnabled",
            "settings.alphaModeAcknowledged",
            "settings.refinementProvider",
            "settings.googleRoutingAcknowledged",
            "settings.googleDirectionsAPIKey",
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case auto, light, dark
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// UIKit window style. `.unspecified` lets the window adopt the live OS trait —
    /// which is what we want for `.auto`. Pushed to `UIWindow.overrideUserInterfaceStyle`
    /// because SwiftUI's `\.colorScheme` reads the *overridden* trait, not the system one,
    /// making auto-mode self-perpetuate the last explicit choice.
    var uiUserInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .auto: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Apple-system colors the user can pick as the accent / trip-line color.
enum AppAccent: String, CaseIterable, Identifiable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, brown
    var id: String {
        rawValue
    }

    var label: String {
        rawValue.capitalized
    }

    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .brown: .brown
        }
    }
}
