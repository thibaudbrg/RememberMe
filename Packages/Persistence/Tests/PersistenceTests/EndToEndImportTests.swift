import Core
import XCTest
@testable import Persistence

/// Wires the full pipeline together: read the user's real Google Takeout file,
/// decode it, persist it into an encrypted database, then verify counts and a few spot-checks.
/// Skips gracefully if the real file isn't present (e.g. CI checkout without `sample-data/`).
final class EndToEndImportTests: XCTestCase {
    func testImportsRealTakeoutIntoEncryptedDatabase() throws {
        guard let url = realLocationHistoryURL() else {
            throw XCTSkip("sample-data/google-takeout/location-history.json not present; skipping end-to-end test")
        }
        let data = try Data(contentsOf: url)

        let startDecode = Date()
        let decoded = try GoogleTakeoutDecoder().decode(data)
        let decodeSeconds = Date().timeIntervalSince(startDecode)

        XCTAssertGreaterThan(decoded.events.count, 0)
        print(
            "decoded \(decoded.events.count) events in \(String(format: "%.2f", decodeSeconds))s, skipped \(decoded.skipped.count)"
        )

        let database = try DatabaseFactory.open(
            at: SQLCipherDatabase.inMemoryPath,
            keyStore: InMemoryKeyStore(),
            excludeFromBackup: false
        )

        let startWrite = Date()
        let written = try EventWriter(database: database).write(decoded.events)
        let writeSeconds = Date().timeIntervalSince(startWrite)

        XCTAssertEqual(written, decoded.events.count)
        print("wrote \(written) events in \(String(format: "%.2f", writeSeconds))s")

        let counts = try Persistence.eventCounts(in: database)
        // With deterministic ids + INSERT OR IGNORE, events that collide on
        // source|kind|start|end|payload dedupe on insert — so stored total can be <= decoded count.
        XCTAssertLessThanOrEqual(counts.total, decoded.events.count)
        XCTAssertGreaterThan(counts.total, 0)
        XCTAssertEqual(counts.activities + counts.visits + counts.paths, counts.total)
        print(
            "counts: total=\(counts.total) activities=\(counts.activities) visits=\(counts.visits) paths=\(counts.paths)"
        )

        // Spot-check path_points count > events of kind=path (every path has >= 1 sample).
        let pathPointsStmt = try database.prepare("SELECT count(*) FROM path_points;")
        defer { pathPointsStmt.finalize() }
        XCTAssertEqual(try pathPointsStmt.step(), .row)
        let pathPointCount = pathPointsStmt.columnInt(0)
        XCTAssertGreaterThanOrEqual(pathPointCount, counts.paths)
        print("path_points rows: \(pathPointCount)")
    }

    private func realLocationHistoryURL() -> URL? {
        // Walk up from this source file's location until we find the repo root that contains `sample-data/`.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            let candidate = dir.appendingPathComponent("sample-data/google-takeout/location-history.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
