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
            try setExcludeFromBackup(at: URL(fileURLWithPath: path))
        }

        return database
    }

    private static func setExcludeFromBackup(at url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
