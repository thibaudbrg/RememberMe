import XCTest
@testable import Core

final class CoreTests: XCTestCase {
    func testSchemaVersionIsOne() {
        XCTAssertEqual(Core.schemaVersion, 1)
    }
}
