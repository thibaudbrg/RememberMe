import Core
import Foundation
import Observation
import Persistence

/// State + actions for the live app. Created once at launch, injected via the SwiftUI `.environment(_:)`.
///
/// Ownership:
/// - `keyStore`: persists the DB key in the Keychain
/// - `database`: opened lazily on first call to `ensureOpen()`; lives until app termination
/// - `counts`, `importStatus`: observed by the SwiftUI tree
@MainActor
@Observable
public final class AppEnvironment {
    public enum ImportStatus: Equatable, Sendable {
        case idle
        case running(stage: String)
        case completed(Persistence.EventCounts, skipped: Int)
        case failed(message: String)
    }

    private let keyStore: any KeyStore
    private let databasePath: String
    private var database: SQLCipherDatabase?

    public var counts: Persistence.EventCounts = .empty
    public var visitMarkers: [VisitMarker] = []
    public var importStatus: ImportStatus = .idle

    // MARK: - Init

    public init(keyStore: any KeyStore, databasePath: String) {
        self.keyStore = keyStore
        self.databasePath = databasePath
    }

    /// The production environment: real Keychain, real on-disk database under Application Support.
    public static func live() -> AppEnvironment {
        AppEnvironment(
            keyStore: KeychainKeyStore(),
            databasePath: Self.defaultDatabasePath()
        )
    }

    /// Preview / unit-test environment: in-memory key, in-memory database.
    public static func preview() -> AppEnvironment {
        AppEnvironment(
            keyStore: InMemoryKeyStore(),
            databasePath: SQLCipherDatabase.inMemoryPath
        )
    }

    // MARK: - Database lifecycle

    /// Opens (or creates) the encrypted database and refreshes published state.
    /// Idempotent — safe to call multiple times.
    public func ensureOpen() async {
        if database != nil { return }
        do {
            let opened = try DatabaseFactory.open(
                at: databasePath,
                keyStore: keyStore,
                excludeFromBackup: databasePath != SQLCipherDatabase.inMemoryPath
            )
            self.database = opened
            await refresh()
        } catch {
            importStatus = .failed(message: "Couldn't open database: \(error.localizedDescription)")
        }
    }

    /// Re-reads counts and visit markers from the database. Cheap; safe to call after any write.
    public func refresh() async {
        guard let database else { return }
        do {
            counts = try Persistence.eventCounts(in: database)
            visitMarkers = try Persistence.fetchVisitMarkers(in: database)
        } catch {
            importStatus = .failed(message: "Couldn't refresh: \(error.localizedDescription)")
        }
    }

    // MARK: - Import

    /// Decodes a Google Takeout `location-history.json` at `url` and writes everything into the DB.
    /// The heavy lifting happens off the main actor.
    public func importTakeout(from url: URL) async {
        await ensureOpen()
        guard let database else { return }

        importStatus = .running(stage: "Reading file…")

        // The file picker hands us a security-scoped URL — we must open the scope before reading.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            importStatus = .running(stage: "Decoding…")
            let decoded = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                return try GoogleTakeoutDecoder().decode(data)
            }.value

            importStatus = .running(stage: "Writing \(decoded.events.count) events…")
            let writer = EventWriter(database: database)
            let written = try await Task.detached(priority: .userInitiated) {
                try writer.write(decoded.events)
            }.value

            await refresh()
            importStatus = .completed(counts, skipped: decoded.skipped.count)
            _ = written
        } catch {
            importStatus = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Debug-only auto-import

    #if DEBUG
    /// If the app's own Documents folder contains `location-history.json` AND the database is
    /// currently empty, kicks off an import. Lets us drive the full flow from `xcrun simctl`
    /// without manually steering the file picker.
    ///
    /// This entire method is omitted from Release builds.
    public func autoImportSampleIfPresent() async {
        guard counts.total == 0 else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let candidate = docs?.appendingPathComponent("location-history.json"),
              FileManager.default.fileExists(atPath: candidate.path)
        else {
            return
        }
        await importTakeout(from: candidate)
    }
    #endif

    // MARK: - Helpers

    private static func defaultDatabasePath() -> String {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = appSupport.appendingPathComponent("RememberMe", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("db.sqlite")
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        return file.path
    }
}

public extension Persistence.EventCounts {
    static let empty = Persistence.EventCounts(total: 0, activities: 0, visits: 0, paths: 0)
}
