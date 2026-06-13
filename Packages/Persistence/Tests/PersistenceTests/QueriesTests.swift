import Core
import XCTest
@testable import Persistence

final class QueriesTests: XCTestCase {
    private var database: SQLCipherDatabase!

    override func setUpWithError() throws {
        database = try DatabaseFactory.open(
            at: SQLCipherDatabase.inMemoryPath,
            keyStore: InMemoryKeyStore(),
            excludeFromBackup: false
        )
    }

    override func tearDown() {
        database = nil
    }

    // MARK: - Places

    func testUpsertPlaceInsertsThenUpdates() throws {
        try Persistence.upsertPlace(
            in: database,
            placeID: "abc",
            coordinate: Coordinate(latitude: 47.0, longitude: 6.5),
            resolvedLabel: nil
        )
        var place = try XCTUnwrap(Persistence.fetchPlace(in: database, placeID: "abc"))
        XCTAssertNil(place.resolvedLabel)

        try Persistence.upsertPlace(
            in: database,
            placeID: "abc",
            coordinate: Coordinate(latitude: 47.0, longitude: 6.5),
            resolvedLabel: "Café Foo, Neuchâtel"
        )
        place = try XCTUnwrap(Persistence.fetchPlace(in: database, placeID: "abc"))
        XCTAssertEqual(place.resolvedLabel, "Café Foo, Neuchâtel")
    }

    func testFetchPlaceReturnsNilForMissingID() throws {
        XCTAssertNil(try Persistence.fetchPlace(in: database, placeID: "nope"))
    }

    // MARK: - Place resolution progress

    func testPlaceResolutionProgressCountsDistinctPlaces() throws {
        let ts = TimestampedLocal(date: Date(timeIntervalSince1970: 1_700_000_000), tzOffsetMinutes: 0)
        // 3 visits across 2 distinct places — distinct count is 2.
        try EventWriter(database: database).write([
            makeVisit(placeID: "alpha", at: Coordinate(latitude: 1, longitude: 1), start: ts, end: ts),
            makeVisit(placeID: "alpha", at: Coordinate(latitude: 1, longitude: 1), start: ts, end: ts),
            makeVisit(placeID: "beta", at: Coordinate(latitude: 2, longitude: 2), start: ts, end: ts),
        ])

        var progress = try Persistence.fetchPlaceResolutionProgress(in: database)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.resolved, 0)

        // Resolve alpha.
        try Persistence.upsertPlace(
            in: database,
            placeID: "alpha",
            coordinate: Coordinate(latitude: 1, longitude: 1),
            resolvedLabel: "Alpha Place"
        )
        progress = try Persistence.fetchPlaceResolutionProgress(in: database)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.resolved, 1)

        // Resolve beta. Now 100%.
        try Persistence.upsertPlace(
            in: database,
            placeID: "beta",
            coordinate: Coordinate(latitude: 2, longitude: 2),
            resolvedLabel: "Beta Place"
        )
        progress = try Persistence.fetchPlaceResolutionProgress(in: database)
        XCTAssertEqual(progress.resolved, progress.total)
    }

    // MARK: - Visit history

    func testFetchVisitHistoryReturnsVisitsForPlaceOnly() throws {
        let homeTs = TimestampedLocal(date: Date(timeIntervalSince1970: 1_700_000_000), tzOffsetMinutes: 0)
        let workTs = TimestampedLocal(date: Date(timeIntervalSince1970: 1_710_000_000), tzOffsetMinutes: 0)
        try EventWriter(database: database).write([
            makeVisit(placeID: "home", at: Coordinate(latitude: 1, longitude: 1), start: homeTs, end: homeTs),
            makeVisit(placeID: "home", at: Coordinate(latitude: 1, longitude: 1), start: homeTs, end: homeTs),
            makeVisit(placeID: "work", at: Coordinate(latitude: 2, longitude: 2), start: workTs, end: workTs),
        ])

        let homeHistory = try Persistence.fetchVisitHistory(in: database, placeID: "home")
        XCTAssertEqual(homeHistory.count, 2)
        let workHistory = try Persistence.fetchVisitHistory(in: database, placeID: "work")
        XCTAssertEqual(workHistory.count, 1)
    }

    // MARK: - Trips

    func testFetchRecentTripsReturnsActivitiesNewestFirst() throws {
        try EventWriter(database: database).write([
            makeActivity(start: 1_700_000_000, mode: "walking"),
            makeActivity(start: 1_710_000_000, mode: "in passenger vehicle"),
        ])

        let trips = try Persistence.fetchRecentTrips(in: database)
        XCTAssertEqual(trips.count, 2)
        XCTAssertEqual(trips[0].mode, "in passenger vehicle") // newest first
        XCTAssertEqual(trips[1].mode, "walking")
    }

    func testFetchPathPointsReturnsPointsInSequenceOrder() throws {
        let ts = TimestampedLocal(date: Date(timeIntervalSince1970: 1_700_000_000), tzOffsetMinutes: 0)
        let path = Event(
            start: ts,
            end: ts,
            source: "test",
            kind: .path([
                PathPoint(coordinate: Coordinate(latitude: 1.0, longitude: 1.0), offsetMinutes: 0),
                PathPoint(coordinate: Coordinate(latitude: 1.1, longitude: 1.0), offsetMinutes: 5),
                PathPoint(coordinate: Coordinate(latitude: 1.2, longitude: 1.0), offsetMinutes: 10),
            ])
        )
        try EventWriter(database: database).write([path])

        let points = try Persistence.fetchPathPoints(in: database, eventID: path.id)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].latitude, 1.0)
        XCTAssertEqual(points[2].latitude, 1.2)
    }

    // MARK: - Timeline

    func testFetchTimelineIncludesAllKindsNewestFirst() throws {
        let early = TimestampedLocal(date: Date(timeIntervalSince1970: 1_700_000_000), tzOffsetMinutes: 0)
        let mid = TimestampedLocal(date: Date(timeIntervalSince1970: 1_710_000_000), tzOffsetMinutes: 0)
        let late = TimestampedLocal(date: Date(timeIntervalSince1970: 1_720_000_000), tzOffsetMinutes: 0)
        try EventWriter(database: database).write([
            makeVisit(placeID: "home", at: Coordinate(latitude: 1, longitude: 1), start: early, end: early),
            makeActivity(start: mid.date.timeIntervalSince1970, mode: "walking"),
            Event(start: late, end: late, source: "test", kind: .path([
                PathPoint(coordinate: Coordinate(latitude: 0, longitude: 0), offsetMinutes: 0),
            ])),
        ])

        let timeline = try Persistence.fetchTimeline(in: database)
        XCTAssertEqual(timeline.count, 3)
        XCTAssertEqual(timeline.map(\.kind), ["path", "activity", "visit"])
    }

    func testFetchTimelineIncludesResolvedLabelWhenAvailable() throws {
        let ts = TimestampedLocal(date: Date(timeIntervalSince1970: 1_700_000_000), tzOffsetMinutes: 0)
        try EventWriter(database: database).write([
            makeVisit(placeID: "home", at: Coordinate(latitude: 1, longitude: 1), start: ts, end: ts),
        ])
        try Persistence.upsertPlace(
            in: database,
            placeID: "home",
            coordinate: Coordinate(latitude: 1, longitude: 1),
            resolvedLabel: "Home Sweet Home"
        )

        let timeline = try Persistence.fetchTimeline(in: database)
        guard case let .visit(_, _, resolvedLabel, _, _) = timeline.first?.detail else {
            return XCTFail("expected a visit entry")
        }
        XCTAssertEqual(resolvedLabel, "Home Sweet Home")
    }

    func testSetUserLabelStoresAndPrefersOverResolvedLabel() throws {
        // Pre-resolve a label.
        try Persistence.upsertPlace(
            in: database,
            placeID: "home",
            coordinate: Coordinate(latitude: 47.0, longitude: 6.5),
            resolvedLabel: "12 Rue Quelconque, Neuchâtel"
        )
        // User renames.
        try Persistence.setUserLabel(
            in: database,
            placeID: "home",
            coordinate: Coordinate(latitude: 47.0, longitude: 6.5),
            userLabel: "Home"
        )
        let place = try XCTUnwrap(Persistence.fetchPlace(in: database, placeID: "home"))
        XCTAssertEqual(place.userLabel, "Home")
        XCTAssertEqual(place.resolvedLabel, "12 Rue Quelconque, Neuchâtel")
    }

    func testSetUserLabelWithEmptyClearsExistingLabel() throws {
        try Persistence.setUserLabel(
            in: database,
            placeID: "p1",
            coordinate: Coordinate(latitude: 0, longitude: 0),
            userLabel: "Hello"
        )
        try Persistence.setUserLabel(
            in: database,
            placeID: "p1",
            coordinate: Coordinate(latitude: 0, longitude: 0),
            userLabel: "  "
        )
        let place = try XCTUnwrap(Persistence.fetchPlace(in: database, placeID: "p1"))
        XCTAssertNil(place.userLabel)
    }

    // MARK: - Geocoding queue helpers

    func testFetchUnresolvedPlaceIDsExcludesAlreadyResolved() throws {
        let ts = TimestampedLocal(date: Date(timeIntervalSince1970: 1_700_000_000), tzOffsetMinutes: 0)
        try EventWriter(database: database).write([
            makeVisit(placeID: "a", at: Coordinate(latitude: 1, longitude: 1), start: ts, end: ts),
            makeVisit(placeID: "b", at: Coordinate(latitude: 2, longitude: 2), start: ts, end: ts),
            makeVisit(placeID: "c", at: Coordinate(latitude: 3, longitude: 3), start: ts, end: ts),
        ])
        try Persistence.upsertPlace(
            in: database,
            placeID: "b",
            coordinate: Coordinate(latitude: 2, longitude: 2),
            resolvedLabel: "Place B"
        )

        let unresolved = try Persistence.fetchUnresolvedPlaceIDs(in: database)
        XCTAssertEqual(Set(unresolved), Set(["a", "c"]))
    }

    func testFetchPlaceCoordinatesReturnsRepresentativeCoord() throws {
        let ts = TimestampedLocal(date: Date(timeIntervalSince1970: 1_700_000_000), tzOffsetMinutes: 0)
        try EventWriter(database: database).write([
            makeVisit(placeID: "a", at: Coordinate(latitude: 47.0, longitude: 6.5), start: ts, end: ts),
            makeVisit(placeID: "b", at: Coordinate(latitude: 48.0, longitude: 7.0), start: ts, end: ts),
        ])

        let coords = try Persistence.fetchPlaceCoordinates(in: database, placeIDs: ["a", "b"])
        XCTAssertEqual(coords["a"], Coordinate(latitude: 47.0, longitude: 6.5))
        XCTAssertEqual(coords["b"], Coordinate(latitude: 48.0, longitude: 7.0))
    }

    func testFetchPlaceCoordinatesHandlesEmptyInput() throws {
        XCTAssertEqual(try Persistence.fetchPlaceCoordinates(in: database, placeIDs: []), [:])
    }

    // MARK: - Helpers

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

    private func makeActivity(start: TimeInterval, mode: String) -> Event {
        let ts = TimestampedLocal(date: Date(timeIntervalSince1970: start), tzOffsetMinutes: 0)
        return Event(
            start: ts,
            end: ts,
            source: "test",
            kind: .activity(ActivityDetails(
                start: Coordinate(latitude: 0, longitude: 0),
                end: Coordinate(latitude: 1, longitude: 1),
                distanceMeters: 100,
                mode: mode,
                probability: 0.9
            ))
        )
    }
}
