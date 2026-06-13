import Core
import XCTest
@testable import Persistence

/// Migrations are exercised here against *populated* older-version databases — the real
/// app-update scenario where `ALTER TABLE` runs over a live `events` table with rows in it.
/// (Every other suite opens a fresh DB, which only ever runs the full chain on empty tables.)
final class MigrationsTests: XCTestCase {
    /// Opens a raw (un-migrated) database, applies the schema constants up to `version` by hand,
    /// and stamps `user_version` so `Migrations.apply` resumes from exactly there.
    private func makeDatabase(atVersion version: Int32) throws -> SQLCipherDatabase {
        let key = try InMemoryKeyStore().getOrCreateKey()
        let database = try SQLCipherDatabase(path: SQLCipherDatabase.inMemoryPath, key: key)
        let stepsByVersion: [Int32: String] = [1: Schema.v1, 2: Schema.v2, 3: Schema.v3, 4: Schema.v4]
        for v in 1 ... version {
            guard let sql = stepsByVersion[v] else { preconditionFailure("no schema constant for v\(v)") }
            try database.execute(sql)
        }
        try database.setUserVersion(version)
        return database
    }

    /// Inserts one activity event the old way (no `is_superseded` / `derived_from_event_id`
    /// columns yet) so we can prove the row — and its child — survive the upgrade.
    private func seedActivity(in database: SQLCipherDatabase, id: String) throws {
        try database.execute("""
            INSERT INTO events (id, kind, start_ts, start_tz_offset_min, end_ts, end_tz_offset_min, source, imported_at)
            VALUES ('\(id)', 'activity', 1700000000, 0, 1700001800, 0, 'test', 1);
            INSERT INTO activities (event_id, start_lat, start_lon, end_lat, end_lon, distance_m, mode, probability)
            VALUES ('\(id)', 48.0, 2.0, 48.1, 2.1, 1234.0, 'walking', 0.9);
        """)
    }

    func testV1DatabaseWithDataMigratesToCurrent() throws {
        let database = try makeDatabase(atVersion: 1)
        let id = "11111111-1111-1111-1111-111111111111"
        try seedActivity(in: database, id: id)

        try Migrations.apply(to: database)
        XCTAssertEqual(try database.userVersion(), Schema.currentVersion)

        // The seeded row survives.
        let countStmt = try database.prepare("SELECT count(*) FROM events;")
        defer { countStmt.finalize() }
        XCTAssertEqual(try countStmt.step(), .row)
        XCTAssertEqual(countStmt.columnInt(0), 1)

        // The columns added in v3 default correctly: is_superseded = 0, derived_from_event_id NULL.
        let colStmt = try database.prepare("SELECT is_superseded, derived_from_event_id FROM events WHERE id = ?;")
        defer { colStmt.finalize() }
        try colStmt.bind(1, text: id)
        XCTAssertEqual(try colStmt.step(), .row)
        XCTAssertEqual(colStmt.columnInt(0), 0)
        XCTAssertTrue(colStmt.columnIsNull(1))

        // The activity child row is still intact.
        let modeStmt = try database.prepare("SELECT mode FROM activities WHERE event_id = ?;")
        defer { modeStmt.finalize() }
        try modeStmt.bind(1, text: id)
        XCTAssertEqual(try modeStmt.step(), .row)
        XCTAssertEqual(modeStmt.columnText(0), "walking")
    }

    func testV3DatabaseWithDataMigratesToCurrent() throws {
        // v3 → current adds the v4 ALTER on path_refinements; data in events must carry through.
        let database = try makeDatabase(atVersion: 3)
        let id = "33333333-3333-3333-3333-333333333333"
        try seedActivity(in: database, id: id)
        // Mark it superseded — a non-default value must survive the upgrade unchanged.
        try database.execute("UPDATE events SET is_superseded = 1 WHERE id = '\(id)';")

        try Migrations.apply(to: database)
        XCTAssertEqual(try database.userVersion(), Schema.currentVersion)

        let stmt = try database.prepare("SELECT is_superseded FROM events WHERE id = ?;")
        defer { stmt.finalize() }
        try stmt.bind(1, text: id)
        XCTAssertEqual(try stmt.step(), .row)
        XCTAssertEqual(stmt.columnInt(0), 1, "a pre-existing is_superseded value must survive migration")

        // The v4 column is now present.
        let prStmt = try database.prepare("SELECT journey_member_ids FROM path_refinements LIMIT 0;")
        prStmt.finalize()
    }
}
