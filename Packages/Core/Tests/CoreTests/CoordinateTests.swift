import XCTest
@testable import Core

final class CoordinateTests: XCTestCase {
    func testParsesValidGeoURI() {
        let coord = Coordinate.parse(geoURI: "geo:46.997669,6.943593")
        XCTAssertEqual(coord?.latitude, 46.997669)
        XCTAssertEqual(coord?.longitude, 6.943593)
    }

    func testParsesNegativeCoordinates() {
        let coord = Coordinate.parse(geoURI: "geo:-33.865143,-151.209900")
        XCTAssertEqual(coord?.latitude, -33.865143)
        XCTAssertEqual(coord?.longitude, -151.209900)
    }

    func testRejectsMissingPrefix() {
        XCTAssertNil(Coordinate.parse(geoURI: "46.997669,6.943593"))
    }

    func testRejectsMissingComma() {
        XCTAssertNil(Coordinate.parse(geoURI: "geo:46.997669 6.943593"))
    }

    func testRejectsNonNumeric() {
        XCTAssertNil(Coordinate.parse(geoURI: "geo:north,east"))
    }

    func testRejectsNonFiniteValues() {
        // Double("nan")/Double("inf") parse successfully in Swift — the range guard must reject them.
        XCTAssertNil(Coordinate.parse(geoURI: "geo:nan,inf"))
        XCTAssertNil(Coordinate.parse(geoURI: "geo:0,inf"))
        XCTAssertNil(Coordinate.parse(geoURI: "geo:nan,0"))
    }

    func testRejectsOutOfRangeValues() {
        XCTAssertNil(Coordinate.parse(geoURI: "geo:91.5,0"))   // latitude > 90
        XCTAssertNil(Coordinate.parse(geoURI: "geo:-90.1,0"))  // latitude < -90
        XCTAssertNil(Coordinate.parse(geoURI: "geo:0,200"))    // longitude > 180
        XCTAssertNil(Coordinate.parse(geoURI: "geo:0,-181"))   // longitude < -180
    }

    func testAcceptsExtremeButValidValues() {
        XCTAssertNotNil(Coordinate.parse(geoURI: "geo:90,180"))
        XCTAssertNotNil(Coordinate.parse(geoURI: "geo:-90,-180"))
    }
}
