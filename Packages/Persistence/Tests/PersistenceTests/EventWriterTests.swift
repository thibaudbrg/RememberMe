import Core
import XCTest
@testable import Persistence

final class EventWriterTests: XCTestCase {
    private var keyStore: InMemoryKeyStore!
    private var database: SQLCipherDatabase!

    override func setUpWithError() throws {
        keyStore = InMemoryKeyStore()
        database = try DatabaseFactory.open(
            at: SQLCipherDatabase.inMemoryPath,
            keyStore: keyStore,
            excludeFromBackup: false
        )
    }

    override func tearDown() {
        database = nil
        keyStore = nil
    }

    func testWritesOneOfEachKind() throws {
        let events = makeEvents()
        let writer = EventWriter(database: database)
        let written = try writer.write(events)

        XCTAssertEqual(written, 3)

        let counts = try Persistence.eventCounts(in: database)
        XCTAssertEqual(counts, .init(total: 3, activities: 1, visits: 1, paths: 1))
    }

    func testActivityRowMatchesInput() throws {
        let events = makeEvents()
        let writer = EventWriter(database: database)
        try writer.write(events)

        let stmt = try database.prepare("""
            SELECT a.start_lat, a.start_lon, a.end_lat, a.end_lon, a.distance_m, a.mode, a.probability
            FROM activities a
            JOIN events e ON e.id = a.event_id
            WHERE e.kind = 'activity';
        """)
        defer { stmt.finalize() }
        XCTAssertEqual(stmt.step(), .row)
        XCTAssertEqual(stmt.columnDouble(0), 0.0)
        XCTAssertEqual(stmt.columnDouble(1), 0.0)
        XCTAssertEqual(stmt.columnDouble(2), 0.01)
        XCTAssertEqual(stmt.columnDouble(3), 0.01)
        XCTAssertEqual(stmt.columnDouble(4), 1572.0)
        XCTAssertEqual(stmt.columnText(5), "walking")
        XCTAssertEqual(stmt.columnDouble(6), 0.9)
    }

    func testVisitRowPreservesPlaceID() throws {
        try EventWriter(database: database).write(makeEvents())

        let stmt = try database.prepare("SELECT place_id, semantic_type, probability FROM visits;")
        defer { stmt.finalize() }
        XCTAssertEqual(stmt.step(), .row)
        XCTAssertEqual(stmt.columnText(0), "FIXTURE_PLACE_ALPHA")
        XCTAssertEqual(stmt.columnText(1), "Work")
        XCTAssertEqual(stmt.columnDouble(2), 0.95)
    }

    func testPathPointsWritesAllSamples() throws {
        try EventWriter(database: database).write(makeEvents())

        let stmt = try database.prepare("SELECT count(*) FROM path_points;")
        defer { stmt.finalize() }
        XCTAssertEqual(stmt.step(), .row)
        XCTAssertEqual(stmt.columnInt(0), 4)
    }

    func testTimezoneOffsetIsPreserved() throws {
        try EventWriter(database: database).write(makeEvents())

        let stmt = try database.prepare(
            "SELECT start_tz_offset_min, end_tz_offset_min FROM events WHERE kind = 'activity';"
        )
        defer { stmt.finalize() }
        XCTAssertEqual(stmt.step(), .row)
        XCTAssertEqual(stmt.columnInt(0), 120) // +02:00
        XCTAssertEqual(stmt.columnInt(1), 120)
    }

    func testEmptyArrayIsNoop() throws {
        let written = try EventWriter(database: database).write([])
        XCTAssertEqual(written, 0)
    }

    func testForeignKeyCascadeDeletesChildren() throws {
        try EventWriter(database: database).write(makeEvents())

        try database.execute("DELETE FROM events WHERE kind = 'path';")

        let stmt = try database.prepare("SELECT count(*) FROM path_points;")
        defer { stmt.finalize() }
        XCTAssertEqual(stmt.step(), .row)
        XCTAssertEqual(stmt.columnInt(0), 0, "deleting the parent event should cascade to path_points")
    }

    // MARK: - Fixtures

    private func makeEvents() -> [Event] {
        let parisOffset = 120
        let start = TimestampedLocal(date: Date(timeIntervalSince1970: 1_705_305_600), tzOffsetMinutes: parisOffset)
        let end = TimestampedLocal(date: Date(timeIntervalSince1970: 1_705_312_800), tzOffsetMinutes: parisOffset)

        let activity = Event(
            start: start,
            end: end,
            source: "test",
            kind: .activity(ActivityDetails(
                start: Coordinate(latitude: 0.0, longitude: 0.0),
                end: Coordinate(latitude: 0.01, longitude: 0.01),
                distanceMeters: 1572,
                mode: "walking",
                probability: 0.9
            ))
        )
        let visit = Event(
            start: start,
            end: end,
            source: "test",
            kind: .visit(VisitDetails(
                placeID: "FIXTURE_PLACE_ALPHA",
                location: Coordinate(latitude: 0.01, longitude: 0.01),
                semanticType: "Work",
                hierarchyLevel: 0,
                probability: 0.95
            ))
        )
        let path = Event(
            start: start,
            end: end,
            source: "test",
            kind: .path([
                PathPoint(coordinate: Coordinate(latitude: 0.01, longitude: 0.01), offsetMinutes: 0),
                PathPoint(coordinate: Coordinate(latitude: 0.012, longitude: 0.011), offsetMinutes: 10),
                PathPoint(coordinate: Coordinate(latitude: 0.015, longitude: 0.013), offsetMinutes: 20),
                PathPoint(coordinate: Coordinate(latitude: 0.02, longitude: 0.02), offsetMinutes: 30),
            ])
        )

        return [activity, visit, path]
    }
}
