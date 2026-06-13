import XCTest
@testable import Core

final class PolylineDirectionTests: XCTestCase {
    // MARK: - Bearing

    func testBearingDueNorthIsZero() {
        let bearing = PolylineDirection.bearingDegrees(
            from: Coordinate(latitude: 47.0, longitude: 6.0),
            to: Coordinate(latitude: 48.0, longitude: 6.0)
        )
        XCTAssertEqual(bearing, 0, accuracy: 0.5)
    }

    func testBearingDueEastIsNinety() {
        let bearing = PolylineDirection.bearingDegrees(
            from: Coordinate(latitude: 0, longitude: 0),
            to: Coordinate(latitude: 0, longitude: 1)
        )
        XCTAssertEqual(bearing, 90, accuracy: 0.5)
    }

    func testBearingDueSouthIsOneEighty() {
        let bearing = PolylineDirection.bearingDegrees(
            from: Coordinate(latitude: 48, longitude: 6),
            to: Coordinate(latitude: 47, longitude: 6)
        )
        XCTAssertEqual(bearing, 180, accuracy: 0.5)
    }

    func testBearingDueWestIsTwoSeventy() {
        let bearing = PolylineDirection.bearingDegrees(
            from: Coordinate(latitude: 0, longitude: 1),
            to: Coordinate(latitude: 0, longitude: 0)
        )
        XCTAssertEqual(bearing, 270, accuracy: 0.5)
    }

    // MARK: - Haversine

    func testHaversineKnownDistance() {
        // ~1° of latitude ≈ 111 km
        let distance = PolylineDirection.haversineMeters(
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 1, longitude: 0)
        )
        XCTAssertEqual(distance, 111_195, accuracy: 200) // ±200 m tolerance
    }

    func testHaversineAntipodalIsFiniteNotNaN() {
        // Near-antipodal points push the haversine term a few ulps above 1; without the clamp
        // sqrt(1 - central) is NaN. The result must be finite and ~half the Earth's circumference.
        let distance = PolylineDirection.haversineMeters(
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 180)
        )
        XCTAssertTrue(distance.isFinite, "antipodal distance must not be NaN")
        XCTAssertEqual(distance, .pi * PolylineDirection.earthRadiusMeters, accuracy: 1.0)
    }

    // MARK: - Markers

    func testReturnsNoMarkersForShortLine() {
        // ~50 m apart — too short.
        let line = [
            Coordinate(latitude: 47.0, longitude: 6.0),
            Coordinate(latitude: 47.0005, longitude: 6.0),
        ]
        XCTAssertEqual(PolylineDirection.markers(for: line, polylineID: "x"), [])
    }

    func testReturnsMarkersWithIncreasingDistanceFromStart() {
        // 4 km straight line east.
        let line = [
            Coordinate(latitude: 47.0, longitude: 6.0),
            Coordinate(latitude: 47.0, longitude: 6.05), // ~3.8 km east at lat 47
        ]
        let markers = PolylineDirection.markers(for: line, polylineID: "x", maxMarkers: 4)
        XCTAssertGreaterThanOrEqual(markers.count, 2)
        // All bearings should be ~90° (due east).
        for marker in markers {
            XCTAssertEqual(marker.bearingDegrees, 90, accuracy: 1.0)
        }
        // The line runs straight east at a constant latitude, so the interpolated markers must
        // march strictly eastward (longitude strictly increasing) and stay on the latitude.
        let longitudes = markers.map(\.coordinate.longitude)
        for (earlier, later) in zip(longitudes, longitudes.dropFirst()) {
            XCTAssertLessThan(earlier, later, "markers must be ordered by increasing distance from start")
        }
        XCTAssertGreaterThan(longitudes.first ?? 0, 6.0, "first marker is past the start")
        XCTAssertLessThan(longitudes.last ?? 0, 6.05, "last marker is before the end")
        for marker in markers {
            XCTAssertEqual(marker.coordinate.latitude, 47.0, accuracy: 1e-9)
        }
    }

    func testCapsAtMaxMarkers() {
        // Long line — Geneva to Zürich is ~225 km.
        let line = [
            Coordinate(latitude: 46.20, longitude: 6.14),
            Coordinate(latitude: 47.37, longitude: 8.55),
        ]
        let markers = PolylineDirection.markers(for: line, polylineID: "x", maxMarkers: 6)
        XCTAssertLessThanOrEqual(markers.count, 6)
        XCTAssertGreaterThan(markers.count, 0)
    }
}
