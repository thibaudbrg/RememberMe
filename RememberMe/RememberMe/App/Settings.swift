import Foundation
import Observation
import SwiftUI

/// User-facing preferences. Persisted via `@AppStorage` keys behind the scenes.
@MainActor
@Observable
public final class Settings {
    static let themeKey = "settings.theme"
    static let accentKey = "settings.accentColor"
    static let arrowsKey = "settings.showDirectionArrows"
    static let biometricKey = "settings.biometricLock"
    static let photosKey = "settings.showPhotosOnMap"
    static let alphaEnabledKey = "settings.alphaModeEnabled"
    static let alphaAcknowledgedKey = "settings.alphaModeAcknowledged"
    static let refinementProviderKey = "settings.refinementProvider"
    static let googleAckKey = "settings.googleRoutingAcknowledged"
    static let googleAPIKeyKey = "settings.googleDirectionsAPIKey"

    public var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    public var accent: AppAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Self.accentKey) }
    }

    /// Whether to show the small "direction of travel" chevrons sprinkled along trip
    /// polylines on the map.
    public var showDirectionArrows: Bool {
        didSet { UserDefaults.standard.set(showDirectionArrows, forKey: Self.arrowsKey) }
    }

    /// When on, the app prompts for Face ID / Touch ID at launch and stays locked behind a
    /// `LockedView` until the user authenticates. Off by default — user opt-in only.
    public var biometricLockEnabled: Bool {
        didSet { UserDefaults.standard.set(biometricLockEnabled, forKey: Self.biometricKey) }
    }

    /// When on, overlay photos from the device library that were taken on the selected day,
    /// at their geo-tagged coordinate. Requires the user to grant Photos read access. Off
    /// by default — accessing photos is a meaningful permission ask.
    public var showPhotosOnMap: Bool {
        didSet { UserDefaults.standard.set(showPhotosOnMap, forKey: Self.photosKey) }
    }

    /// Opt-in for the alpha-features bucket (currently: path refinement via Apple Maps).
    /// Off by default. Flipping ON for the first time triggers a one-shot disclosure sheet
    /// that explains what leaves the device.
    public var alphaModeEnabled: Bool {
        didSet { UserDefaults.standard.set(alphaModeEnabled, forKey: Self.alphaEnabledKey) }
    }

    /// True once the user has seen and accepted the alpha-mode disclosure sheet. Persisted
    /// so the disclosure only appears on first enable.
    public var alphaModeAcknowledged: Bool {
        didSet { UserDefaults.standard.set(alphaModeAcknowledged, forKey: Self.alphaAcknowledgedKey) }
    }

    /// Which third-party routing source the alpha screen uses. Apple Maps is the default;
    /// switching to Google Maps requires a separate user-entered API key and triggers a
    /// distinct disclosure sheet because Google receives the requests instead of Apple.
    public var refinementProvider: RefinementProvider {
        didSet { UserDefaults.standard.set(refinementProvider.rawValue, forKey: Self.refinementProviderKey) }
    }

    /// True once the user has accepted the Google-specific disclosure. Separate from
    /// `alphaModeAcknowledged` so flipping back to Google later doesn't reuse the Apple
    /// consent.
    public var googleRoutingAcknowledged: Bool {
        didSet { UserDefaults.standard.set(googleRoutingAcknowledged, forKey: Self.googleAckKey) }
    }

    /// User-pasted Google Directions API key. Stored locally; never embedded in the
    /// binary. If empty, the Google provider can't run and the UI must prompt the user.
    public var googleDirectionsAPIKey: String {
        didSet { UserDefaults.standard.set(googleDirectionsAPIKey, forKey: Self.googleAPIKeyKey) }
    }

    public init() {
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

        // Default OFF — alpha-mode opens outbound Apple Maps calls; user opt-in only.
        alphaModeEnabled = UserDefaults.standard.bool(forKey: Self.alphaEnabledKey)
        alphaModeAcknowledged = UserDefaults.standard.bool(forKey: Self.alphaAcknowledgedKey)

        // Default to Apple Maps — the lower-leak option of the two.
        let providerRaw = UserDefaults.standard.string(forKey: Self.refinementProviderKey) ?? RefinementProvider.apple.rawValue
        refinementProvider = RefinementProvider(rawValue: providerRaw) ?? .apple
        googleRoutingAcknowledged = UserDefaults.standard.bool(forKey: Self.googleAckKey)
        googleDirectionsAPIKey = UserDefaults.standard.string(forKey: Self.googleAPIKeyKey) ?? ""
    }
}

/// Which third-party routing service the path-refinement screen calls.
public enum RefinementProvider: String, CaseIterable, Identifiable, Sendable {
    /// Apple Maps via `MKDirections`. Anonymized endpoints, no API key — but does not
    /// return transit polylines.
    case apple
    /// Google Directions API. Requires a user-entered API key. Supports transit.
    case google

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .apple: "Apple Maps"
        case .google: "Google Maps"
        }
    }
}

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case auto, light, dark
    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Apple-system colors the user can pick as the accent / trip-line color.
public enum AppAccent: String, CaseIterable, Identifiable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, brown
    public var id: String {
        rawValue
    }

    public var label: String {
        rawValue.capitalized
    }

    public var color: Color {
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
