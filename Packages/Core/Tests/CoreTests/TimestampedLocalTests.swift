import XCTest
@testable import Core

final class TimestampedLocalTests: XCTestCase {
    func testParsesPositiveOffsetWithFractionalSeconds() {
        let ts = TimestampedLocal.parse(iso8601: "2023-08-23T07:52:01.117+02:00")
        XCTAssertNotNil(ts)
        XCTAssertEqual(ts?.tzOffsetMinutes, 120)
    }

    func testParsesNegativeOffset() {
        let ts = TimestampedLocal.parse(iso8601: "2024-01-15T08:30:00.000-05:00")
        XCTAssertEqual(ts?.tzOffsetMinutes, -300)
    }

    func testParsesZuluAsZeroOffset() {
        let ts = TimestampedLocal.parse(iso8601: "2024-01-15T08:00:00.000Z")
        XCTAssertNotNil(ts)
        XCTAssertEqual(ts?.tzOffsetMinutes, 0)
    }

    func testParsesWithoutFractionalSeconds() {
        let ts = TimestampedLocal.parse(iso8601: "2024-01-15T08:00:00+02:00")
        XCTAssertNotNil(ts)
        XCTAssertEqual(ts?.tzOffsetMinutes, 120)
    }

    func testReturnsNilOnGarbage() {
        XCTAssertNil(TimestampedLocal.parse(iso8601: "not a date"))
    }

    func testDatePointsAtSameInstantRegardlessOfOffset() throws {
        let utc = try XCTUnwrap(TimestampedLocal.parse(iso8601: "2024-01-15T08:00:00.000Z"))
        let paris = try XCTUnwrap(TimestampedLocal.parse(iso8601: "2024-01-15T10:00:00.000+02:00"))
        XCTAssertEqual(utc.date, paris.date, "10:00 in +02:00 is the same instant as 08:00 UTC")
    }
}
