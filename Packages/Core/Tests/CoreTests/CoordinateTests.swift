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
}
