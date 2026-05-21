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
