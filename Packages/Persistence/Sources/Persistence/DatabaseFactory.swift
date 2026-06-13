import Core
import Foundation

/// One-stop opener: get the key from the `KeyStore`, open the SQLCipher DB at `path`,
/// run any pending migrations, return the live handle.
///
/// On first launch the DB file does not exist yet — SQLCipher creates it on open.
/// On subsequent launches the same key unlocks the existing file.
public enum DatabaseFactory {
    /// Opens (or creates) an encrypted database at `path`, runs migrations, and excludes
    /// the file from iCloud/iTunes backup. Returns the open database.
    public static func open(
        at path: String,
        keyStore: KeyStore,
        excludeFromBackup: Bool = true
    ) throws -> SQLCipherDatabase {
        let key = try keyStore.getOrCreateKey()
        let database = try SQLCipherDatabase(path: path, key: key)
        try Migrations.apply(to: database)

        if excludeFromBackup, path != SQLCipherDatabase.inMemoryPath {
            // WAL mode (see SQLCipherDatabase) keeps `-wal`/`-shm` sidecars next to the main file;
            // they hold un-checkpointed pages, so excluding only the main file still leaks data
            // into iCloud/iTunes backups. Exclude all three. The sidecars exist by now because
            // migrations have already written through WAL.
            try setExcludeFromBackup(at: URL(fileURLWithPath: path))
            try setExcludeFromBackup(at: URL(fileURLWithPath: path + "-wal"))
            try setExcludeFromBackup(at: URL(fileURLWithPath: path + "-shm"))
        }

        return database
    }

    private static func setExcludeFromBackup(at url: URL) throws {
        // A sidecar may not exist yet (e.g. an empty WAL gets checkpointed away); skip silently.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
