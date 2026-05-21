import XCTest
@testable import Persistence

final class PersistenceTests: XCTestCase {
    func testNoMigrationsAppliedYet() {
        XCTAssertTrue(Persistence.migrationsApplied.isEmpty)
    }
}
