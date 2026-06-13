import CoreLocation
import Observation
import SwiftUI

/// Floating "find my location" button. Standard Apple Maps placement: bottom-right.
struct LocateMeButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "location.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(12)
                .background(.thinMaterial, in: Circle())
                .shadow(radius: 2, y: 1)
        }
        .accessibilityLabel("Locate me")
    }
}

/// Tiny location manager owned by MapScreen. Requests when-in-use authorization on demand,
/// keeps a single last-known location, and reports it back to the caller.
///
/// Marked `@unchecked Sendable` because CLLocationManager itself isn't strictly Sendable but
/// we only touch it from the main actor (SwiftUI view code).
@MainActor
@Observable
final class LocateMeManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    public private(set) var lastKnown: CLLocationCoordinate2D?
    /// Bumped on every fresh fix. `CLLocationCoordinate2D` isn't `Equatable`, so views observe
    /// this counter instead of `lastKnown` to react to a new fix arriving.
    public private(set) var fixCount = 0
    /// True only between a user tap and the next fix (or authorization grant). Gates the
    /// one-shot `requestLocation()` so the legacy authorization callback that fires on
    /// creation never kicks off GPS without a tap.
    private var pendingRequest = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Asks for authorization (if needed) and fetches a single fix. Returns the last-known
    /// coordinate immediately if we already have one — the caller can re-center on it without
    /// waiting for a fresh fix.
    @discardableResult
    func requestAndStartIfNeeded() -> CLLocationCoordinate2D? {
        switch manager.authorizationStatus {
        case .notDetermined:
            // Defer the request until the grant arrives in the authorization callback.
            pendingRequest = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
        return lastKnown
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            // Only fetch if the user actually tapped Locate Me first (pendingRequest); the
            // callback also fires on creation with existing authorization, which must not
            // start GPS on its own.
            guard self.pendingRequest else { return }
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            } else {
                self.pendingRequest = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.pendingRequest = false
            self.lastKnown = coordinate
            self.fixCount += 1
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Soft-fail — user-initiated location requests don't need to surface errors prominently.
        Task { @MainActor in self.pendingRequest = false }
    }
}
