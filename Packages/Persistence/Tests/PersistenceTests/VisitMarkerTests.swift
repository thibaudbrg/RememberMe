import Core
import XCTest
@testable import Persistence

final class VisitMarkerTests: XCTestCase {
    func testReturnsEmptyOnFreshDatabase() throws {
        let database = try DatabaseFactory.open(
            at: SQLCipherDatabase.inMemoryPath,
            keyStore: InMemoryKeyStore(),
            excludeFromBackup: false
        )
        XCTAssertEqual(try Persistence.fetchVisitMarkers(in: database), [])
    }

    func testDeduplicatesByPlaceIDAndOrdersByMostRecent() throws {
        let database = try DatabaseFactory.open(
            at: SQLCipherDatabase.inMemoryPath,
            keyStore: InMemoryKeyStore(),
            excludeFromBackup: false
        )

        let earlier = TimestampedLocal(date: Date(timeIntervalSince1970: 1_700_000_000), tzOffsetMinutes: 0)
        let later = TimestampedLocal(date: Date(timeIntervalSince1970: 1_710_000_000), tzOffsetMinutes: 0)
        let muchLater = TimestampedLocal(date: Date(timeIntervalSince1970: 1_720_000_000), tzOffsetMinutes: 0)

        let visits = [
            makeVisit(placeID: "home", at: Coordinate(latitude: 1, longitude: 1), start: earlier, end: earlier),
            makeVisit(placeID: "home", at: Coordinate(latitude: 1, longitude: 1), start: later, end: later),
            makeVisit(placeID: "work", at: Coordinate(latitude: 2, longitude: 2), start: muchLater, end: muchLater),
        ]
        try EventWriter(database: database).write(visits)

        let markers = try Persistence.fetchVisitMarkers(in: database)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].placeID, "work")
        XCTAssertEqual(markers[0].visitCount, 1)
        XCTAssertEqual(markers[1].placeID, "home")
        XCTAssertEqual(markers[1].visitCount, 2)
    }

    func testRespectsLimit() throws {
        let database = try DatabaseFactory.open(
            at: SQLCipherDatabase.inMemoryPath,
            keyStore: InMemoryKeyStore(),
            excludeFromBackup: false
        )

        let visits = (0 ..< 50).map { index in
            let ts = TimestampedLocal(date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)), tzOffsetMinutes: 0)
            return makeVisit(placeID: "place-\(index)", at: Coordinate(latitude: Double(index), longitude: 0), start: ts, end: ts)
        }
        try EventWriter(database: database).write(visits)

        let markers = try Persistence.fetchVisitMarkers(in: database, limit: 10)
        XCTAssertEqual(markers.count, 10)
    }

    private func makeVisit(
        placeID: String,
        at coordinate: Coordinate,
        start: TimestampedLocal,
        end: TimestampedLocal
    ) -> Event {
        Event(
            start: start,
            end: end,
            source: "test",
            kind: .visit(VisitDetails(
                placeID: placeID,
                location: coordinate,
                semanticType: "Unknown",
                hierarchyLevel: 0,
                probability: 1
            ))
        )
    }
}
