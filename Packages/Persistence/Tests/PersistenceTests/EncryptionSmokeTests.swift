import Core
import XCTest
@testable import Persistence

/// Proves at the byte level that the on-disk file is genuinely encrypted by SQLCipher:
/// a fresh SQLite file starts with the magic header `"SQLite format 3\0"`; an SQLCipher
/// file does not (the first page is encrypted, so the bytes look like noise).
///
/// Also proves the wrong-key case is rejected at open time.
final class EncryptionSmokeTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RememberMeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testFileDoesNotStartWithSQLiteMagic() throws {
        let dbURL = tempDirectory.appendingPathComponent("encrypted.sqlite")
        do {
            let db = try DatabaseFactory.open(at: dbURL.path, keyStore: InMemoryKeyStore(), excludeFromBackup: false)
            // Force a flush by writing something — schema is already applied by migrations.
            try db.execute(
                "INSERT INTO places (place_id, lat, lon) VALUES ('smoke', 0.0, 0.0);"
            )
        } // close before reading raw bytes

        let raw = try Data(contentsOf: dbURL)
        XCTAssertGreaterThan(raw.count, 16, "DB file should have content")
        let header = raw.prefix(16)
        let sqliteMagic = Data("SQLite format 3\0".utf8)
        XCTAssertNotEqual(header, sqliteMagic, "encrypted DB header must NOT be plain SQLite magic")
    }

    func testWrongKeyIsRejected() throws {
        let dbURL = tempDirectory.appendingPathComponent("wrong-key.sqlite")
        let realStore = InMemoryKeyStore()
        do {
            let db = try DatabaseFactory.open(at: dbURL.path, keyStore: realStore, excludeFromBackup: false)
            try db.execute(
                "INSERT INTO places (place_id, lat, lon) VALUES ('smoke', 0.0, 0.0);"
            )
        }

        // Re-open with a *different* random key.
        let badStore = InMemoryKeyStore()
        XCTAssertNotEqual(try realStore.getOrCreateKey(), try badStore.getOrCreateKey())

        XCTAssertThrowsError(
            try DatabaseFactory.open(at: dbURL.path, keyStore: badStore, excludeFromBackup: false)
        ) { error in
            guard let dbError = error as? DatabaseError else {
                return XCTFail("expected DatabaseError, got \(error)")
            }
            switch dbError {
            case .keyRejected, .prepareFailed:
                break // either is acceptable
            default:
                XCTFail("expected .keyRejected or .prepareFailed, got \(dbError)")
            }
        }
    }

    func testCorrectKeyReopensDatabase() throws {
        let dbURL = tempDirectory.appendingPathComponent("reopen.sqlite")
        let store = InMemoryKeyStore()
        _ = try store.getOrCreateKey() // pin the key

        do {
            let db = try DatabaseFactory.open(at: dbURL.path, keyStore: store, excludeFromBackup: false)
            try db.execute(
                "INSERT INTO places (place_id, lat, lon) VALUES ('persisted', 1.0, 2.0);"
            )
        }

        let reopened = try DatabaseFactory.open(at: dbURL.path, keyStore: store, excludeFromBackup: false)
        let stmt = try reopened.prepare("SELECT place_id, lat, lon FROM places;")
        defer { stmt.finalize() }
        XCTAssertEqual(stmt.step(), .row)
        XCTAssertEqual(stmt.columnText(0), "persisted")
        XCTAssertEqual(stmt.columnDouble(1), 1.0)
        XCTAssertEqual(stmt.columnDouble(2), 2.0)
    }
}
