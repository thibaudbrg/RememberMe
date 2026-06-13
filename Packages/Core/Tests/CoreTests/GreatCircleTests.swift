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

    func testArcStaysContinuousAcrossTheAntimeridian() {
        // Tokyo (HND) to San Francisco (SFO) — the great-circle path crosses the 180th meridian.
        // Each interpolated longitude must stay within 180° of the previous one (no ±360 jump),
        // so MapPolyline draws a continuous line across the dateline instead of across the world.
        let tokyo = Coordinate(latitude: 35.55, longitude: 139.78)
        let sanFrancisco = Coordinate(latitude: 37.62, longitude: -122.38)
        let arc = GreatCircle.arc(from: tokyo, to: sanFrancisco, steps: 32)

        for (earlier, later) in zip(arc, arc.dropFirst()) {
            XCTAssertLessThanOrEqual(
                abs(later.longitude - earlier.longitude),
                180,
                "consecutive arc longitudes jumped more than 180° — the dateline wasn't unwrapped"
            )
        }
        // The unwrap pushes longitudes past +180 across the dateline; the endpoint stays correct
        // modulo 360 (San Francisco at -122.38 unwraps to +237.62).
        let last = arc.last?.longitude ?? 0
        XCTAssertEqual(((last - sanFrancisco.longitude) / 360).rounded() * 360,
                       last - sanFrancisco.longitude,
                       accuracy: 1e-6,
                       "endpoint longitude must equal San Francisco's modulo a whole number of turns")
    }

    func testShortArcStaysContinuousAcrossTheAntimeridian() {
        // Two points ~20 km apart straddling the dateline take the short-circuit [start, end] path;
        // the end longitude must be unwrapped so the segment doesn't span the globe.
        let west = Coordinate(latitude: 0, longitude: 179.95)
        let east = Coordinate(latitude: 0, longitude: -179.95)
        let arc = GreatCircle.arc(from: west, to: east)
        XCTAssertEqual(arc.count, 2)
        XCTAssertLessThanOrEqual(abs(arc[1].longitude - arc[0].longitude), 180)
        XCTAssertEqual(arc[1].longitude, 180.05, accuracy: 1e-6) // -179.95 unwrapped against 179.95
    }
}
