import Core
import XCTest
@testable import Persistence

final class LiveTripWriterTests: XCTestCase {
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

    // MARK: - openTrip

    func testOpenTripInsertsPathEventWithStartEqualEnd() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        try writer.openTrip(eventID: id, start: start, tzOffsetMinutes: 60)

        let stmt = try database.prepare("""
            SELECT kind, start_ts, end_ts, start_tz_offset_min, end_tz_offset_min, source
            FROM events WHERE id = ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: id.uuidString)
        XCTAssertEqual(try stmt.step(), .row)
        XCTAssertEqual(stmt.columnText(0), "path")
        XCTAssertEqual(stmt.columnInt64(1), 1_700_000_000)
        XCTAssertEqual(stmt.columnInt64(2), 1_700_000_000) // end == start
        XCTAssertEqual(stmt.columnInt32(3), 60)
        XCTAssertEqual(stmt.columnInt32(4), 60)
        XCTAssertEqual(stmt.columnText(5), "live-ios-v1")
    }

    // MARK: - appendPoints

    func testAppendPointsInsertsExpectedRows() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        try writer.openTrip(eventID: id, start: Date(), tzOffsetMinutes: 0)

        let pts: [PathPoint] = [
            PathPoint(coordinate: Coordinate(latitude: 1.0, longitude: 2.0), offsetMinutes: 0),
            PathPoint(coordinate: Coordinate(latitude: 1.001, longitude: 2.001), offsetMinutes: 1),
            PathPoint(coordinate: Coordinate(latitude: 1.002, longitude: 2.002), offsetMinutes: 2),
        ]
        try writer.appendPoints(eventID: id, startingSequence: 0, points: pts)

        let stmt = try database.prepare("""
            SELECT seq, offset_min, lat, lon FROM path_points WHERE event_id = ? ORDER BY seq;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: id.uuidString)

        var seenSeq: [Int32] = []
        while try stmt.step() == .row {
            seenSeq.append(stmt.columnInt32(0))
        }
        XCTAssertEqual(seenSeq, [0, 1, 2])
    }

    func testAppendPointsRespectsStartingSequence() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        try writer.openTrip(eventID: id, start: Date(), tzOffsetMinutes: 0)

        let first: [PathPoint] = [
            PathPoint(coordinate: Coordinate(latitude: 1.0, longitude: 2.0), offsetMinutes: 0),
            PathPoint(coordinate: Coordinate(latitude: 1.001, longitude: 2.001), offsetMinutes: 1),
        ]
        try writer.appendPoints(eventID: id, startingSequence: 0, points: first)

        let second: [PathPoint] = [
            PathPoint(coordinate: Coordinate(latitude: 1.002, longitude: 2.002), offsetMinutes: 2),
        ]
        try writer.appendPoints(eventID: id, startingSequence: 2, points: second)

        let stmt = try database.prepare("""
            SELECT seq FROM path_points WHERE event_id = ? ORDER BY seq;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: id.uuidString)
        var seqs: [Int32] = []
        while try stmt.step() == .row { seqs.append(stmt.columnInt32(0)) }
        XCTAssertEqual(seqs, [0, 1, 2])
    }

    func testAppendPointsIsNoOpForEmptyArray() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        try writer.openTrip(eventID: id, start: Date(), tzOffsetMinutes: 0)
        XCTAssertNoThrow(try writer.appendPoints(eventID: id, startingSequence: 0, points: []))

        let stmt = try database.prepare("SELECT COUNT(*) FROM path_points WHERE event_id = ?;")
        defer { stmt.finalize() }
        try stmt.bind(1, text: id.uuidString)
        XCTAssertEqual(try stmt.step(), .row)
        XCTAssertEqual(stmt.columnInt32(0), 0)
    }

    // MARK: - updateEnd

    func testUpdateEndOverwritesEndTimestamp() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try writer.openTrip(eventID: id, start: start, tzOffsetMinutes: 0)

        let end = Date(timeIntervalSince1970: 1_700_003_600) // +1h
        try writer.updateEnd(eventID: id, end: end, tzOffsetMinutes: 0)

        let stmt = try database.prepare("SELECT end_ts FROM events WHERE id = ?;")
        defer { stmt.finalize() }
        try stmt.bind(1, text: id.uuidString)
        XCTAssertEqual(try stmt.step(), .row)
        XCTAssertEqual(stmt.columnInt64(0), 1_700_003_600)
    }

    // MARK: - End-to-end round trip

    // MARK: - writeActivity (Phase 7)

    func testWriteActivityInsertsBothEventAndActivityRow() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_000_600) // +10 min

        try writer.writeActivity(
            eventID: id,
            start: start,
            end: end,
            tzOffsetMinutes: 0,
            startCoord: Coordinate(latitude: 47.0, longitude: 6.5),
            endCoord: Coordinate(latitude: 47.05, longitude: 6.55),
            distanceMeters: 1234.5,
            mode: "walking",
            probability: 0.85
        )

        let stmt = try database.prepare("""
            SELECT e.kind, a.start_lat, a.end_lat, a.distance_m, a.mode, a.probability
            FROM events e
            JOIN activities a ON a.event_id = e.id
            WHERE e.id = ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: id.uuidString)
        XCTAssertEqual(try stmt.step(), .row)
        XCTAssertEqual(stmt.columnText(0), "activity")
        XCTAssertEqual(stmt.columnDouble(1), 47.0)
        XCTAssertEqual(stmt.columnDouble(2), 47.05)
        XCTAssertEqual(stmt.columnDouble(3), 1234.5)
        XCTAssertEqual(stmt.columnText(4), "walking")
        XCTAssertEqual(stmt.columnDouble(5), 0.85)
    }

    // MARK: - Visits (Phase 8)

    func testOpenVisitInsertsEventAndVisitRow() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try writer.openVisit(
            eventID: id,
            placeID: "live-abc-123",
            coordinate: Coordinate(latitude: 48.85, longitude: 2.34),
            start: start,
            end: start,
            tzOffsetMinutes: 60
        )

        let stmt = try database.prepare("""
            SELECT e.kind, e.start_ts, e.end_ts, v.place_id, v.lat, v.lon, v.semantic_type, v.probability
            FROM events e
            JOIN visits v ON v.event_id = e.id
            WHERE e.id = ?;
        """)
        defer { stmt.finalize() }
        try stmt.bind(1, text: id.uuidString)
        XCTAssertEqual(try stmt.step(), .row)
        XCTAssertEqual(stmt.columnText(0), "visit")
        XCTAssertEqual(stmt.columnInt64(1), 1_700_000_000)
        XCTAssertEqual(stmt.columnInt64(2), 1_700_000_000) // end == start initially
        XCTAssertEqual(stmt.columnText(3), "live-abc-123")
        XCTAssertEqual(stmt.columnDouble(4), 48.85)
        XCTAssertEqual(stmt.columnDouble(5), 2.34)
        XCTAssertEqual(stmt.columnText(6), "Unknown")
        XCTAssertEqual(stmt.columnDouble(7), 1.0)
    }

    func testCloseVisitUpdatesEndTimestamp() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try writer.openVisit(
            eventID: id,
            placeID: "live-xyz-999",
            coordinate: Coordinate(latitude: 48.85, longitude: 2.34),
            start: start,
            end: start,
            tzOffsetMinutes: 60
        )

        let depart = Date(timeIntervalSince1970: 1_700_003_600)
        try writer.closeVisit(eventID: id, end: depart, tzOffsetMinutes: 60)

        let stmt = try database.prepare("SELECT end_ts FROM events WHERE id = ?;")
        defer { stmt.finalize() }
        try stmt.bind(1, text: id.uuidString)
        XCTAssertEqual(try stmt.step(), .row)
        XCTAssertEqual(stmt.columnInt64(0), 1_700_003_600)
    }

    // MARK: - Crash recovery (Phase 9)

    func testFindOrphanedLivePathsReturnsPathsWithoutSiblingActivity() throws {
        let writer = LiveTripWriter(database: database)

        // Two trips. Trip A: only path, no sibling activity. Trip B: both.
        // The pairing in the DB is by (start_ts, end_ts), not id.
        let orphanPath = UUID()
        let orphanStart = Date(timeIntervalSince1970: 1_700_000_000)
        let orphanEnd = Date(timeIntervalSince1970: 1_700_000_600)
        try writer.openTrip(eventID: orphanPath, start: orphanStart, tzOffsetMinutes: 0)
        try writer.updateEnd(eventID: orphanPath, end: orphanEnd, tzOffsetMinutes: 0)

        let completePath = UUID()
        let completeActivity = UUID() // different id from the path
        let completeStart = Date(timeIntervalSince1970: 1_700_010_000)
        let completeEnd = Date(timeIntervalSince1970: 1_700_010_600)
        try writer.openTrip(eventID: completePath, start: completeStart, tzOffsetMinutes: 0)
        try writer.updateEnd(eventID: completePath, end: completeEnd, tzOffsetMinutes: 0)
        try writer.writeActivity(
            eventID: completeActivity,
            start: completeStart,
            end: completeEnd,
            tzOffsetMinutes: 0,
            startCoord: Coordinate(latitude: 0, longitude: 0),
            endCoord: Coordinate(latitude: 0, longitude: 0),
            distanceMeters: 0,
            mode: "walking",
            probability: 1
        )

        let orphans = try writer.findOrphanedLivePaths()
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.id, orphanPath)
        XCTAssertEqual(orphans.first?.startTimestamp, 1_700_000_000)
        XCTAssertEqual(orphans.first?.endTimestamp, 1_700_000_600)
    }

    func testFetchTripEndpointsAndDistanceFromPathPoints() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        try writer.openTrip(eventID: id, start: Date(), tzOffsetMinutes: 0)
        // Three points roughly straight-line. Each ~100m apart.
        try writer.appendPoints(eventID: id, startingSequence: 0, points: [
            PathPoint(coordinate: Coordinate(latitude: 47.0, longitude: 6.5), offsetMinutes: 0),
            PathPoint(coordinate: Coordinate(latitude: 47.001, longitude: 6.5), offsetMinutes: 1),
            PathPoint(coordinate: Coordinate(latitude: 47.002, longitude: 6.5), offsetMinutes: 2),
        ])

        let endpoints = try writer.fetchTripEndpointsAndDistance(eventID: id)
        XCTAssertNotNil(endpoints)
        XCTAssertEqual(endpoints?.start.latitude, 47.0)
        XCTAssertEqual(endpoints?.end.latitude, 47.002)
        // ~111m per 0.001° latitude → expect roughly 222m total.
        XCTAssertEqual(endpoints?.distanceMeters ?? 0, 222, accuracy: 10)
    }

    func testFetchTripEndpointsReturnsNilWhenNoPathPoints() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        try writer.openTrip(eventID: id, start: Date(), tzOffsetMinutes: 0)
        XCTAssertNil(try writer.fetchTripEndpointsAndDistance(eventID: id))
    }

    func testOrphanRecoveryFlowMakesPreviouslyOrphanedPathFindable() throws {
        // Simulates the Phase 9 recovery: a path event exists with no sibling
        // activity. After writing a placeholder activity with matching
        // start_ts/end_ts, findOrphanedLivePaths should return empty.
        let writer = LiveTripWriter(database: database)
        let pathID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_000_600)
        try writer.openTrip(eventID: pathID, start: start, tzOffsetMinutes: 0)
        try writer.updateEnd(eventID: pathID, end: end, tzOffsetMinutes: 0)

        XCTAssertEqual(try writer.findOrphanedLivePaths().count, 1)

        // Recover.
        try writer.writeActivity(
            eventID: UUID(), // different id, as per the design
            start: start,
            end: end,
            tzOffsetMinutes: 0,
            startCoord: Coordinate(latitude: 0, longitude: 0),
            endCoord: Coordinate(latitude: 0, longitude: 0),
            distanceMeters: 0,
            mode: "unknown",
            probability: 0
        )

        XCTAssertTrue(try writer.findOrphanedLivePaths().isEmpty)
    }

    // MARK: - Visit dedupe

    func testFindLiveVisitMatchesSameArrivalNearby() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        let arrival = Date(timeIntervalSince1970: 1_700_000_000)
        try writer.openVisit(
            eventID: id,
            placeID: "live-abc",
            coordinate: Coordinate(latitude: 46.53, longitude: 6.58),
            start: arrival,
            end: arrival,
            tzOffsetMinutes: 60
        )

        // Same arrival, ~50m away → match.
        let match = try writer.findLiveVisit(
            arrival: arrival,
            near: Coordinate(latitude: 46.5305, longitude: 6.58)
        )
        XCTAssertEqual(match?.eventID, id)
        XCTAssertEqual(match?.placeID, "live-abc")

        // Different arrival → no match.
        XCTAssertNil(try writer.findLiveVisit(
            arrival: arrival.addingTimeInterval(60),
            near: Coordinate(latitude: 46.53, longitude: 6.58)
        ))

        // Same arrival but kilometres away → no match.
        XCTAssertNil(try writer.findLiveVisit(
            arrival: arrival,
            near: Coordinate(latitude: 46.6, longitude: 6.58)
        ))
    }

    func testDedupeLiveVisitsKeepsLongestRow() throws {
        let writer = LiveTripWriter(database: database)
        let arrival = Date(timeIntervalSince1970: 1_700_000_000)
        let coord = Coordinate(latitude: 46.99, longitude: 6.93)

        // Three rows for the same physical visit: two 0-duration placeholders
        // and one closed with the real departure (the Maladière ×3 case).
        let zeroA = UUID(), zeroB = UUID(), full = UUID()
        for id in [zeroA, zeroB] {
            try writer.openVisit(eventID: id, placeID: "live-\(id)", coordinate: coord, start: arrival, end: arrival, tzOffsetMinutes: 60)
        }
        try writer.openVisit(
            eventID: full,
            placeID: "live-\(full)",
            coordinate: coord,
            start: arrival,
            end: arrival.addingTimeInterval(13 * 3600),
            tzOffsetMinutes: 60
        )

        let removed = try writer.dedupeLiveVisits()
        XCTAssertEqual(removed, 2)

        let stmt = try database.prepare("SELECT id FROM events WHERE kind = 'visit';")
        defer { stmt.finalize() }
        var remaining: [String] = []
        while try stmt.step() == .row { remaining.append(stmt.columnText(0) ?? "") }
        XCTAssertEqual(remaining, [full.uuidString])

        // Orphaned visits-table rows are gone too.
        let visitRows = try database.prepare("SELECT COUNT(*) FROM visits;")
        defer { visitRows.finalize() }
        XCTAssertEqual(try visitRows.step(), .row)
        XCTAssertEqual(visitRows.columnInt32(0), 1)
    }

    func testDedupeLiveVisitsLeavesDistinctVisitsAlone() throws {
        let writer = LiveTripWriter(database: database)
        let coord = Coordinate(latitude: 46.99, longitude: 6.93)
        try writer.openVisit(
            eventID: UUID(), placeID: "live-a", coordinate: coord,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600), tzOffsetMinutes: 60
        )
        try writer.openVisit(
            eventID: UUID(), placeID: "live-b", coordinate: coord,
            start: Date(timeIntervalSince1970: 1_700_010_000),
            end: Date(timeIntervalSince1970: 1_700_013_600), tzOffsetMinutes: 60
        )
        XCTAssertEqual(try writer.dedupeLiveVisits(), 0)
    }

    // MARK: - Null Island cleanup

    func testDeleteNullIslandActivitiesRemovesOnlyPlaceholders() throws {
        let writer = LiveTripWriter(database: database)
        let bogus = UUID(), real = UUID()
        try writer.writeActivity(
            eventID: bogus,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_000_000),
            tzOffsetMinutes: 0,
            startCoord: Coordinate(latitude: 0, longitude: 0),
            endCoord: Coordinate(latitude: 0, longitude: 0),
            distanceMeters: 0,
            mode: "unknown",
            probability: 0
        )
        try writer.writeActivity(
            eventID: real,
            start: Date(timeIntervalSince1970: 1_700_010_000),
            end: Date(timeIntervalSince1970: 1_700_010_600),
            tzOffsetMinutes: 0,
            startCoord: Coordinate(latitude: 46.5, longitude: 6.6),
            endCoord: Coordinate(latitude: 46.6, longitude: 6.7),
            distanceMeters: 1000,
            mode: "walking",
            probability: 0.9
        )

        XCTAssertEqual(try writer.deleteNullIslandActivities(), 1)

        let stmt = try database.prepare("SELECT id FROM events WHERE kind = 'activity';")
        defer { stmt.finalize() }
        var remaining: [String] = []
        while try stmt.step() == .row { remaining.append(stmt.columnText(0) ?? "") }
        XCTAssertEqual(remaining, [real.uuidString])
    }

    // MARK: - deleteEvents

    func testDeleteEventsRemovesPathAndItsPoints() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        try writer.openTrip(eventID: id, start: Date(), tzOffsetMinutes: 0)
        try writer.appendPoints(eventID: id, startingSequence: 0, points: [
            PathPoint(coordinate: Coordinate(latitude: 1, longitude: 2), offsetMinutes: 0),
        ])

        try writer.deleteEvents(ids: [id])

        let events = try database.prepare("SELECT COUNT(*) FROM events;")
        defer { events.finalize() }
        XCTAssertEqual(try events.step(), .row)
        XCTAssertEqual(events.columnInt32(0), 0)
        let points = try database.prepare("SELECT COUNT(*) FROM path_points;")
        defer { points.finalize() }
        XCTAssertEqual(try points.step(), .row)
        XCTAssertEqual(points.columnInt32(0), 0)
    }

    func testFullTripRoundTripReadsBackViaPersistenceQueries() throws {
        let writer = LiveTripWriter(database: database)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try writer.openTrip(eventID: id, start: start, tzOffsetMinutes: 0)

        try writer.appendPoints(
            eventID: id,
            startingSequence: 0,
            points: [
                PathPoint(coordinate: Coordinate(latitude: 47.06, longitude: 6.59), offsetMinutes: 0),
                PathPoint(coordinate: Coordinate(latitude: 47.07, longitude: 6.60), offsetMinutes: 5),
                PathPoint(coordinate: Coordinate(latitude: 47.08, longitude: 6.61), offsetMinutes: 10),
            ]
        )
        try writer.updateEnd(
            eventID: id,
            end: Date(timeIntervalSince1970: 1_700_000_000 + 10 * 60),
            tzOffsetMinutes: 0
        )

        let counts = try Persistence.eventCounts(in: database)
        XCTAssertEqual(counts.paths, 1)
        XCTAssertEqual(counts.total, 1)

        let points = try Persistence.fetchPathPoints(in: database, eventID: id)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.first?.latitude, 47.06)
        XCTAssertEqual(points.last?.latitude, 47.08)
    }
}
