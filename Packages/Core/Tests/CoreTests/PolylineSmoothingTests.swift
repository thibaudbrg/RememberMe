import XCTest
@testable import Core

final class PolylineSmoothingTests: XCTestCase {
    func testReturnsInputUnchangedWhenTooFewPoints() {
        let single = [Coordinate(latitude: 47, longitude: 6)]
        XCTAssertEqual(PolylineSmoothing.chaikin(coordinates: single), single)

        let pair = [
            Coordinate(latitude: 47, longitude: 6),
            Coordinate(latitude: 47, longitude: 7),
        ]
        XCTAssertEqual(PolylineSmoothing.chaikin(coordinates: pair), pair)
    }

    func testPreservesEndpoints() {
        let input = [
            Coordinate(latitude: 47.0, longitude: 6.0),
            Coordinate(latitude: 47.5, longitude: 6.2),
            Coordinate(latitude: 48.0, longitude: 6.0),
            Coordinate(latitude: 48.5, longitude: 6.5),
        ]
        let smoothed = PolylineSmoothing.chaikin(coordinates: input, iterations: 2)
        XCTAssertEqual(smoothed.first, input.first)
        XCTAssertEqual(smoothed.last, input.last)
    }

    func testStaysInsideOriginalBoundingBox() {
        // Right-angle bend. The smoothed curve must NEVER overshoot the original bbox —
        // that's the whole point of corner-cutting vs Catmull-Rom.
        let input = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 1),
            Coordinate(latitude: 1, longitude: 1),
        ]
        let smoothed = PolylineSmoothing.chaikin(coordinates: input, iterations: 3)
        for point in smoothed {
            XCTAssertGreaterThanOrEqual(point.latitude, 0)
            XCTAssertLessThanOrEqual(point.latitude, 1)
            XCTAssertGreaterThanOrEqual(point.longitude, 0)
            XCTAssertLessThanOrEqual(point.longitude, 1)
        }
    }

    func testStraightLineStaysApproximatelyStraight() {
        let input = (0 ... 3).map { Coordinate(latitude: 0, longitude: Double($0)) }
        let smoothed = PolylineSmoothing.chaikin(coordinates: input, iterations: 2)
        for point in smoothed {
            XCTAssertEqual(point.latitude, 0, accuracy: 1e-9)
        }
    }

    func testEachIterationRoughlyDoublesPointCount() {
        let input = (0 ... 9).map { Coordinate(latitude: 0, longitude: Double($0)) }
        let baseline = input.count
        let onePass = PolylineSmoothing.chaikin(coordinates: input, iterations: 1).count
        let twoPass = PolylineSmoothing.chaikin(coordinates: input, iterations: 2).count
        XCTAssertGreaterThan(onePass, baseline)
        XCTAssertGreaterThan(twoPass, onePass)
        // 2 endpoints + 2 * (n-1) interior samples per pass; 2 passes ≈ 4× the interior.
        XCTAssertLessThan(twoPass, input.count * 5)
    }

    func testCornerIsActuallyRounded() {
        // L-shape — exactly one sharp corner at (0,1). After smoothing, the original sharp
        // vertex should be GONE (the line cuts the corner) and replaced with nearby samples
        // strictly inside the L.
        let input = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 1),
            Coordinate(latitude: 1, longitude: 1),
        ]
        let smoothed = PolylineSmoothing.chaikin(coordinates: input, iterations: 2)
        let sharpCorner = Coordinate(latitude: 0, longitude: 1)
        XCTAssertFalse(smoothed.contains(sharpCorner), "the sharp corner should be cut away")
    }
}
