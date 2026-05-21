import XCTest
@testable import Core

final class GreatCircleTests: XCTestCase {
    func testArcStartsAtStartAndEndsAtEnd() {
        let start = Coordinate(latitude: 47.0, longitude: 6.5)
        let end = Coordinate(latitude: 40.7, longitude: -74.0)
        let arc = GreatCircle.arc(from: start, to: end, steps: 16)

        XCTAssertEqual(arc.first?.latitude ?? 0, start.latitude, accuracy: 1e-9)
        XCTAssertEqual(arc.first?.longitude ?? 0, start.longitude, accuracy: 1e-9)
        XCTAssertEqual(arc.last?.latitude ?? 0, end.latitude, accuracy: 1e-9)
        XCTAssertEqual(arc.last?.longitude ?? 0, end.longitude, accuracy: 1e-9)
    }

    func testArcReturnsStepsPlusOnePoints() {
        let arc = GreatCircle.arc(
            from: Coordinate(latitude: 0, longitude: 0),
            to: Coordinate(latitude: 0, longitude: 90),
            steps: 8
        )
        XCTAssertEqual(arc.count, 9)
    }

    func testArcBulgesNorthForTransAtlanticFlight() {
        // Paris (CDG) to New York (JFK) — the great-circle path curves north over Greenland.
        // A straight Mercator line would stay at ~45° latitude; the great-circle midpoint
        // should be noticeably higher.
        let paris = Coordinate(latitude: 49.0, longitude: 2.5)
        let newYork = Coordinate(latitude: 40.6, longitude: -73.8)
        let arc = GreatCircle.arc(from: paris, to: newYork, steps: 32)
        let midpoint = arc[arc.count / 2]
        // Midpoint should bulge meaningfully above both endpoints (~51-52° for this route).
        XCTAssertGreaterThan(midpoint.latitude, 51.0, "expected great-circle midpoint to bulge above the endpoints")
        XCTAssertGreaterThan(midpoint.latitude, max(paris.latitude, newYork.latitude))
    }

    func testArcReturnsStraightLineForVeryShortDistance() {
        // ~100 m apart: not worth oversampling.
        let start = Coordinate(latitude: 47.0, longitude: 6.5)
        let end = Coordinate(latitude: 47.001, longitude: 6.501)
        let arc = GreatCircle.arc(from: start, to: end)
        XCTAssertEqual(arc.count, 2)
    }
}
