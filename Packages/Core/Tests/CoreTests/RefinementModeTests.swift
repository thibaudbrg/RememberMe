import XCTest
@testable import Core

final class RefinementModeTests: XCTestCase {
    func testWalkingVariantsMapToWalking() {
        for mode in ["walking", "WALKING", "Walking", "on foot", "running"] {
            XCTAssertEqual(RefinementMode.map(recordedMode: mode), .walking, "for \(mode)")
        }
    }

    func testVehicleVariantsMapToAutomobile() {
        for mode in ["in passenger vehicle", "driving", "car", "motorcycling"] {
            XCTAssertEqual(RefinementMode.map(recordedMode: mode), .automobile, "for \(mode)")
        }
    }

    func testTransitVariantsMapToTransit() {
        for mode in ["in subway", "in train", "in bus", "in tram", "public transport"] {
            XCTAssertEqual(RefinementMode.map(recordedMode: mode), .transit, "for \(mode)")
        }
    }

    func testCyclingMapsToWalking() {
        XCTAssertEqual(RefinementMode.map(recordedMode: "cycling"), .walking)
        XCTAssertEqual(RefinementMode.map(recordedMode: "in bicycle"), .walking)
    }

    func testCyclingDetectionFlagsCycling() {
        XCTAssertTrue(RefinementMode.isCycling(recordedMode: "cycling"))
        XCTAssertTrue(RefinementMode.isCycling(recordedMode: "in bicycle"))
        XCTAssertFalse(RefinementMode.isCycling(recordedMode: "walking"))
        XCTAssertFalse(RefinementMode.isCycling(recordedMode: "driving"))
    }

    func testFlightReturnsNil() {
        XCTAssertNil(RefinementMode.map(recordedMode: "in flight"))
        XCTAssertNil(RefinementMode.map(recordedMode: "on flight"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(RefinementMode.map(recordedMode: ""))
        XCTAssertNil(RefinementMode.map(recordedMode: "   "))
    }

    func testUnknownDefaultsToWalking() {
        // Best-effort default for unrecognized strings.
        XCTAssertEqual(RefinementMode.map(recordedMode: "skateboarding"), .walking)
    }

    func testGranularTransitModesMapToTransitNotVehicleOrWalking() {
        // "cable car" must not match the "car" substring -> automobile, and "ferry" must not
        // fall through to the walking default. These are leg displayModes/raw strings fed back
        // through map() after a journey apply.
        for mode in ["cable car", "Cable Car", "IN_CABLE_CAR", "ferry", "FERRY", "in ferry", "tram", "IN_TRAM"] {
            XCTAssertEqual(RefinementMode.map(recordedMode: mode), .transit, "for \(mode)")
        }
    }
}
