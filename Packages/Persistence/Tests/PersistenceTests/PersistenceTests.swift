import Core
import XCTest
@testable import Persistence

final class PersistenceTests: XCTestCase {
    func testSchemaVersionMatchesCore() {
        XCTAssertEqual(Persistence.schemaVersion, Schema.currentVersion)
    }

    func testCountsOnFreshDatabaseAreZero() throws {
        let store = InMemoryKeyStore()
        let database = try DatabaseFactory.open(
            at: SQLCipherDatabase.inMemoryPath,
            keyStore: store,
            excludeFromBackup: false
        )
        let counts = try Persistence.eventCounts(in: database)
        XCTAssertEqual(counts, .init(total: 0, activities: 0, visits: 0, paths: 0))
    }
}
