import Core
import XCTest
@testable import Persistence

final class DayQueriesTests: XCTestCase {
    private var database: SQLCipherDatabase!
    private let calendar = Calendar(identifier: .gregorian)

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

    func testDayBoundedMarkersOnlyReturnTheRequestedDay() throws {
        // Two visits to "home" on 2024-01-15, one visit to "work" on 2024-01-16.
        let jan15Noon = isoDate("2024-01-15T12:00:00Z")
        let jan16Noon = isoDate("2024-01-16T12:00:00Z")
        try EventWriter(database: database).write([
            makeVisit(placeID: "home", at: Coordinate(latitude: 1, longitude: 1), date: jan15Noon),
            makeVisit(placeID: "home", at: Coordinate(latitude: 1, longitude: 1), date: jan15Noon),
            makeVisit(placeID: "work", at: Coordinate(latitude: 2, longitude: 2), date: jan16Noon),
        ])

        let day15 = dayRange(around: jan15Noon)
        let markers = try Persistence.fetchVisitMarkers(in: database, dayRange: day15)
        XCTAssertEqual(markers.map(\.placeID), ["home"])
        XCTAssertEqual(markers.first?.visitCount, 2)
    }

    func testDayBoundedTimelineOrderedAscending() throws {
        let jan15Morning = isoDate("2024-01-15T07:00:00Z")
        let jan15Noon = isoDate("2024-01-15T12:00:00Z")
        try EventWriter(database: database).write([
            makeVisit(placeID: "lunch", at: Coordinate(latitude: 1, longitude: 1), date: jan15Noon),
            makeVisit(placeID: "coffee", at: Coordinate(latitude: 2, longitude: 2), date: jan15Morning),
        ])

        let timeline = try Persistence.fetchTimeline(in: database, dayRange: dayRange(around: jan15Noon))
        XCTAssertEqual(timeline.count, 2)
        // ascending: morning before noon
        XCTAssertLessThan(timeline[0].start.date, timeline[1].start.date)
    }

    func testDayBoundedTripsExcludeOtherDays() throws {
        let jan10 = isoDate("2024-01-10T10:00:00Z")
        let jan11 = isoDate("2024-01-11T10:00:00Z")
        try EventWriter(database: database).write([
            makeActivity(date: jan10, mode: "walking"),
            makeActivity(date: jan11, mode: "in passenger vehicle"),
        ])

        let trips = try Persistence.fetchTrips(in: database, dayRange: dayRange(around: jan11))
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.mode, "in passenger vehicle")
    }

    func testFetchPathTracesReturnsOrderedPoints() throws {
        let day = isoDate("2024-01-15T08:00:00Z")
        let path = Event(
            start: TimestampedLocal(date: day, tzOffsetMinutes: 0),
            end: TimestampedLocal(date: day, tzOffsetMinutes: 0),
            source: "test",
            kind: .path([
                PathPoint(coordinate: Coordinate(latitude: 1.0, longitude: 1.0), offsetMinutes: 0),
                PathPoint(coordinate: Coordinate(latitude: 1.2, longitude: 1.0), offsetMinutes: 5),
                PathPoint(coordinate: Coordinate(latitude: 1.5, longitude: 1.1), offsetMinutes: 10),
            ])
        )
        try EventWriter(database: database).write([path])

        let traces = try Persistence.fetchPathTraces(in: database, dayRange: dayRange(around: day))
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(traces[0].points.count, 3)
        XCTAssertEqual(traces[0].points.first?.latitude, 1.0)
        XCTAssertEqual(traces[0].points.last?.latitude, 1.5)
    }

    func testDaySummaryAggregatesActivitiesAndVisits() throws {
        let day = isoDate("2024-01-15T08:00:00Z")
        try EventWriter(database: database).write([
            makeActivity(date: day, mode: "walking", distance: 1000, durationSec: 600),
            makeActivity(date: day, mode: "running", distance: 2000, durationSec: 800),
            makeVisit(placeID: "home", at: Coordinate(latitude: 0, longitude: 0), date: day),
        ])

        let summary = try Persistence.fetchDaySummary(in: database, dayRange: dayRange(around: day))
        XCTAssertEqual(summary.visitCount, 1)
        XCTAssertEqual(summary.activityCount, 2)
        XCTAssertEqual(summary.totalDistanceMeters, 3000)
        XCTAssertEqual(summary.activityDuration, 1400)
    }

    func testFetchDaysWithDataReturnsDistinctDescending() throws {
        try EventWriter(database: database).write([
            makeVisit(placeID: "a", at: Coordinate(latitude: 0, longitude: 0), date: isoDate("2024-01-10T12:00:00Z")),
            makeVisit(placeID: "b", at: Coordinate(latitude: 0, longitude: 0), date: isoDate("2024-01-10T15:00:00Z")),
            makeVisit(placeID: "c", at: Coordinate(latitude: 0, longitude: 0), date: isoDate("2024-01-12T12:00:00Z")),
        ])

        let days = try Persistence.fetchDaysWithData(in: database)
        XCTAssertEqual(days.count, 2) // 2024-01-10 and 2024-01-12
        // descending
        XCTAssertGreaterThan(days[0], days[1])
    }

    // MARK: - Helpers

    private func dayRange(around date: Date) -> Range<Date> {
        let start = calendar.startOfDay(for: date)
        return start ..< (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400))
    }

    private func isoDate(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: string) else {
            preconditionFailure("invalid test fixture date string: \(string)")
        }
        return date
    }

    private func makeVisit(placeID: String, at coordinate: Coordinate, date: Date) -> Event {
        let ts = TimestampedLocal(date: date, tzOffsetMinutes: 0)
        return Event(
            start: ts,
            end: ts,
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

    private func makeActivity(
        date: Date,
        mode: String,
        distance: Double = 100,
        durationSec: TimeInterval = 60
    ) -> Event {
        Event(
            start: TimestampedLocal(date: date, tzOffsetMinutes: 0),
            end: TimestampedLocal(date: date.addingTimeInterval(durationSec), tzOffsetMinutes: 0),
            source: "test",
            kind: .activity(ActivityDetails(
                start: Coordinate(latitude: 0, longitude: 0),
                end: Coordinate(latitude: 1, longitude: 1),
                distanceMeters: distance,
                mode: mode,
                probability: 0.9
            ))
        )
    }
}
