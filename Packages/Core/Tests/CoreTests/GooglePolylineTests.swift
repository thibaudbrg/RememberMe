import XCTest
@testable import Core

final class GooglePolylineTests: XCTestCase {
    /// Example straight from Google's docs:
    /// https://developers.google.com/maps/documentation/utilities/polylinealgorithm
    func testDecodesGoogleSpecExample() {
        let encoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
        let decoded = GooglePolyline.decode(encoded)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].latitude, 38.5, accuracy: 1e-5)
        XCTAssertEqual(decoded[0].longitude, -120.2, accuracy: 1e-5)
        XCTAssertEqual(decoded[1].latitude, 40.7, accuracy: 1e-5)
        XCTAssertEqual(decoded[1].longitude, -120.95, accuracy: 1e-5)
        XCTAssertEqual(decoded[2].latitude, 43.252, accuracy: 1e-5)
        XCTAssertEqual(decoded[2].longitude, -126.453, accuracy: 1e-5)
    }

    func testEmptyStringDecodesToEmptyArray() {
        XCTAssertTrue(GooglePolyline.decode("").isEmpty)
    }

    func testSinglePointDecode() {
        // (38.5, -120.2) on its own encodes as "_p~iF~ps|U".
        let decoded = GooglePolyline.decode("_p~iF~ps|U")
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].latitude, 38.5, accuracy: 1e-5)
        XCTAssertEqual(decoded[0].longitude, -120.2, accuracy: 1e-5)
    }

    func testTruncatedInputReturnsWhateverDecoded() {
        // Half the second pair is missing — first point should still come through.
        let decoded = GooglePolyline.decode("_p~iF~ps|U_ulL")
        XCTAssertEqual(decoded.count, 1)
    }
}
