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
