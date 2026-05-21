import Core
import CoreLocation
import Foundation
import Observation
import Persistence

/// Reverse-geocodes visited places via Apple's `CLGeocoder` and caches the results in the
/// `places` table. Apple throttles `CLGeocoder` at roughly one request per second, with a
/// per-process daily cap. We respect that with a ~1.2 s gap between requests.
///
/// Concurrency: `@MainActor` because it owns observable state read by SwiftUI. The actual
/// geocoder calls are async and the loop yields between them, so it doesn't block the UI.
@MainActor
@Observable
public final class GeocodingService {
    public typealias ResolutionCallback = @MainActor () async -> Void

    private let database: SQLCipherDatabase
    private let geocoder = CLGeocoder()
    private var loopTask: Task<Void, Never>?
    private let onResolve: ResolutionCallback?

    /// How many places have been resolved in the current run (resets on each `start`).
    public var resolvedThisRun: Int = 0
    /// Last error encountered, if any (cleared on a successful resolution).
    public var lastError: String?
    public var isRunning: Bool = false

    public init(database: SQLCipherDatabase, onResolve: ResolutionCallback? = nil) {
        self.database = database
        self.onResolve = onResolve
    }

    /// Kicks off a background trickle that resolves up to `maxPerRun` places. Idempotent —
    /// calling while already running is a no-op.
    public func start(maxPerRun: Int = 200) {
        guard loopTask == nil else { return }
        resolvedThisRun = 0
        isRunning = true
        loopTask = Task { @MainActor in
            await runLoop(maxPerRun: maxPerRun)
            self.isRunning = false
            self.loopTask = nil
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
    }

    /// Resolves a single place on demand (used when the user opens a place detail view).
    /// Returns the label if known/cached or just-resolved; nil if geocoding failed.
    @discardableResult
    public func resolveOnDemand(placeID: String, coordinate: Coordinate) async -> String? {
        if let existing = (try? Persistence.fetchPlace(in: database, placeID: placeID))?.resolvedLabel {
            return existing
        }
        do {
            let label = try await reverseGeocode(coordinate)
            try Persistence.upsertPlace(
                in: database,
                placeID: placeID,
                coordinate: coordinate,
                resolvedLabel: label
            )
            return label
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Internals

    private func runLoop(maxPerRun: Int) async {
        guard let ids = try? Persistence.fetchUnresolvedPlaceIDs(in: database, limit: maxPerRun),
              !ids.isEmpty,
              let coordinates = try? Persistence.fetchPlaceCoordinates(in: database, placeIDs: ids)
        else {
            return
        }

        for placeID in ids {
            if Task.isCancelled { return }
            guard let coordinate = coordinates[placeID] else { continue }

            do {
                let label = try await reverseGeocode(coordinate)
                try Persistence.upsertPlace(
                    in: database,
                    placeID: placeID,
                    coordinate: coordinate,
                    resolvedLabel: label
                )
                resolvedThisRun += 1
                lastError = nil
                await onResolve?()
            } catch {
                lastError = error.localizedDescription
            }

            // Throttle: Apple's documented limit is ~50/min. 1.2s sleep keeps us safely under.
            try? await Task.sleep(for: .seconds(1.2))
        }
    }

    private func reverseGeocode(_ coordinate: Coordinate) async throws -> String {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else {
            return "Unknown location"
        }
        return formatPlacemark(placemark)
    }

    /// Produces a short, human-readable label from a CLPlacemark.
    /// Examples: "Café de Flore, Paris", "12 rue de la Paix, Paris", "Annecy".
    private func formatPlacemark(_ placemark: CLPlacemark) -> String {
        // 1. Named POI (a restaurant, station, etc.) → "Name, City"
        if let name = placemark.name, !looksLikeStreetNumber(name) {
            if let locality = placemark.locality, name != locality {
                return "\(name), \(locality)"
            }
            return name
        }

        // 2. Street address → "<number> <street>, <city>"
        var parts: [String] = []
        if let street = placemark.thoroughfare {
            if let number = placemark.subThoroughfare {
                parts.append("\(number) \(street)")
            } else {
                parts.append(street)
            }
        }
        if let locality = placemark.locality {
            parts.append(locality)
        }
        if !parts.isEmpty { return parts.joined(separator: ", ") }

        // 3. Last resort.
        return placemark.locality
            ?? placemark.administrativeArea
            ?? placemark.country
            ?? "Unknown location"
    }

    private func looksLikeStreetNumber(_ text: String) -> Bool {
        text.range(of: #"^\d+"#, options: .regularExpression) != nil
    }
}
