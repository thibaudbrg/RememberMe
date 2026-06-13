import Core
import CoreLocation
import Foundation
import Observation
import OSLog
import Persistence

private let geocodingLog = Logger(subsystem: "com.tibo.rememberme", category: "geocoding")

/// Reverse-geocodes visited places via Apple's `CLGeocoder` and caches the results in the
/// `places` table. Apple throttles `CLGeocoder` at roughly one request per second, with a
/// per-process daily cap. We respect that with a ~1.2 s gap between requests.
///
/// Concurrency: `@MainActor` because it owns observable state read by SwiftUI. The actual
/// geocoder calls are async and the loop yields between them, so it doesn't block the UI.
@MainActor
@Observable
final class GeocodingService {
    typealias ResolutionCallback = @MainActor () async -> Void

    private let database: SQLCipherDatabase
    private var loopTask: Task<Void, Never>?
    private let onResolve: ResolutionCallback?

    /// How many places have been resolved in the current run (resets on each `start`).
    var resolvedThisRun: Int = 0
    /// Cumulative attempts since process start (success or fail).
    var totalAttempted: Int = 0
    /// Cumulative failed attempts since process start.
    var totalFailed: Int = 0
    /// Last error encountered, if any (cleared on a successful resolution).
    var lastError: String?
    var isRunning: Bool = false

    /// Total distinct places known to the app (count of `place_id`s across all
    /// `visits` rows). Refreshed at the start of each run + every successful
    /// resolution. Together with `resolvedTotal`, gives the UI a "% complete"
    /// signal: `resolvedTotal / placesTotal`.
    var placesTotal: Int = 0
    /// Total distinct places that already have a non-null `resolved_label`.
    /// Once a place lands here it stays — `fetchUnresolvedPlaceIDs` excludes
    /// resolved places, so the geocoder never asks Apple for the same place
    /// twice. Survives app restarts (the data is in the encrypted DB).
    var resolvedTotal: Int = 0

    /// In-memory ring buffer of the most recent attempts (success + failure), newest
    /// first. Cleared on process exit — purely diagnostic, never persisted. The
    /// debug log sheet renders this directly.
    private(set) var recentResolutions: [ResolutionLogEntry] = []
    private let recentResolutionsLimit = 200

    struct ResolutionLogEntry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let placeID: String
        let coordinate: Coordinate
        let outcome: Outcome

        enum Outcome: Sendable {
            case resolved(label: String)
            case failed(message: String)
            case onDemand(label: String)
        }
    }

    /// Drops the in-memory log. Doesn't affect persisted names — those stay in
    /// the encrypted DB regardless.
    func clearLog() {
        recentResolutions = []
    }

    private func recordLog(_ entry: ResolutionLogEntry) {
        recentResolutions.insert(entry, at: 0)
        if recentResolutions.count > recentResolutionsLimit {
            recentResolutions.removeLast(recentResolutions.count - recentResolutionsLimit)
        }
    }

    init(database: SQLCipherDatabase, onResolve: ResolutionCallback? = nil) {
        self.database = database
        self.onResolve = onResolve
        refreshProgressSnapshot()
    }

    /// Re-counts total + resolved places from the DB. Cheap (two COUNT queries),
    /// called once at run start and once after each successful resolution so
    /// the UI percentage stays accurate.
    func refreshProgressSnapshot() {
        guard let progress = try? Persistence.fetchPlaceResolutionProgress(in: database) else { return }
        placesTotal = progress.total
        resolvedTotal = progress.resolved
    }

    /// Kicks off a background trickle that resolves up to `maxPerRun` places. Idempotent —
    /// calling while already running is a no-op.
    func start(maxPerRun: Int = 200) {
        guard loopTask == nil else { return }
        resolvedThisRun = 0
        refreshProgressSnapshot()
        isRunning = true
        loopTask = Task { @MainActor in
            await runLoop(maxPerRun: maxPerRun)
            self.isRunning = false
            self.loopTask = nil
            self.refreshProgressSnapshot()
        }
    }

    /// Resolves a single place on demand (used when the user opens a place detail view).
    /// Returns the label if known/cached or just-resolved; nil if geocoding failed.
    @discardableResult
    func resolveOnDemand(placeID: String, coordinate: Coordinate) async -> String? {
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
            recordLog(ResolutionLogEntry(
                timestamp: Date(),
                placeID: placeID,
                coordinate: coordinate,
                outcome: .onDemand(label: label)
            ))
            resolvedTotal += 1
            return label
        } catch {
            lastError = error.localizedDescription
            recordLog(ResolutionLogEntry(
                timestamp: Date(),
                placeID: placeID,
                coordinate: coordinate,
                outcome: .failed(message: error.localizedDescription)
            ))
            return nil
        }
    }

    // MARK: - Internals

    private func runLoop(maxPerRun: Int) async {
        guard let ids = try? Persistence.fetchUnresolvedPlaceIDs(in: database, limit: maxPerRun),
              !ids.isEmpty,
              let coordinates = try? Persistence.fetchPlaceCoordinates(in: database, placeIDs: ids)
        else {
            geocodingLog.notice("runLoop: nothing to resolve")
            return
        }

        geocodingLog.notice("runLoop: starting, \(ids.count, privacy: .public) places to resolve")

        for placeID in ids {
            if Task.isCancelled { return }
            guard let coordinate = coordinates[placeID] else { continue }

            totalAttempted += 1
            do {
                let label = try await reverseGeocode(coordinate)
                try Persistence.upsertPlace(
                    in: database,
                    placeID: placeID,
                    coordinate: coordinate,
                    resolvedLabel: label
                )
                resolvedThisRun += 1
                resolvedTotal += 1
                lastError = nil
                geocodingLog.notice("resolved \(self.resolvedThisRun, privacy: .public)/\(ids.count, privacy: .public)")
#if VERBOSE_LOGGING
                geocodingLog.notice("resolved \(placeID, privacy: .private) -> \(label, privacy: .private)")
#endif
                recordLog(ResolutionLogEntry(
                    timestamp: Date(),
                    placeID: placeID,
                    coordinate: coordinate,
                    outcome: .resolved(label: label)
                ))
                await onResolve?()
            } catch {
                totalFailed += 1
                lastError = error.localizedDescription
                if let clError = error as? CLError {
                    geocodingLog.error("CLError \(clError.code.rawValue, privacy: .public) for \(placeID, privacy: .private) @\(coordinate.latitude, privacy: .private),\(coordinate.longitude, privacy: .private): \(error.localizedDescription, privacy: .private)")
                } else {
                    geocodingLog.error("error for \(placeID, privacy: .private): \(error.localizedDescription, privacy: .private)")
                }
                recordLog(ResolutionLogEntry(
                    timestamp: Date(),
                    placeID: placeID,
                    coordinate: coordinate,
                    outcome: .failed(message: error.localizedDescription)
                ))
            }

            // Throttle: Apple's documented limit is ~50/min. 1.2s sleep keeps us safely under.
            try? await Task.sleep(for: .seconds(1.2))
        }
    }

    private func reverseGeocode(_ coordinate: Coordinate) async throws -> String {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Fresh geocoder per request: CLGeocoder handles one request at a time and the
        // second cancels the first. A new instance lets the background trickle and on-demand
        // lookups run without clobbering each other. The app-level rate is held by the loop's
        // 1.2 s throttle.
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else {
            // Empty result → treat as a failure so the place stays unresolved and is retried
            // on a later run, instead of persisting a "Unknown location" placeholder that
            // `fetchUnresolvedPlaceIDs` would exclude forever.
            geocodingLog.debug("reverseGeocode: no placemarks returned for \(coordinate.latitude, privacy: .private),\(coordinate.longitude, privacy: .private)")
            throw CLError(.geocodeFoundNoResult)
        }
        let label = formatPlacemark(placemark)
        if label == "Unknown location" {
            geocodingLog.debug("formatPlacemark fallback for \(coordinate.latitude, privacy: .private),\(coordinate.longitude, privacy: .private): name=\(placemark.name ?? "nil", privacy: .private) street=\(placemark.thoroughfare ?? "nil", privacy: .private) locality=\(placemark.locality ?? "nil", privacy: .private) admin=\(placemark.administrativeArea ?? "nil", privacy: .private) country=\(placemark.country ?? "nil", privacy: .private)")
        }
        return label
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
