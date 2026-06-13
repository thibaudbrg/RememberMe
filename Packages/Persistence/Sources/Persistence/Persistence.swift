import Core
import Foundation

public enum Persistence {
    /// Schema version this build of Persistence is paired with.
    /// Mirrors `Core.schemaVersion`; bumped together when the on-disk schema changes.
    public static let schemaVersion = Schema.currentVersion

    /// Convenience for callers that only need basic counts after an import.
    public struct EventCounts: Equatable, Sendable {
        public let total: Int
        public let activities: Int
        public let visits: Int
        public let paths: Int

        public init(total: Int, activities: Int, visits: Int, paths: Int) {
            self.total = total
            self.activities = activities
            self.visits = visits
            self.paths = paths
        }
    }

    public static func eventCounts(in database: SQLCipherDatabase) throws -> EventCounts {
        let total = try scalarInt(database, sql: "SELECT count(*) FROM events;")
        let activities = try scalarInt(database, sql: "SELECT count(*) FROM events WHERE kind = 'activity';")
        let visits = try scalarInt(database, sql: "SELECT count(*) FROM events WHERE kind = 'visit';")
        let paths = try scalarInt(database, sql: "SELECT count(*) FROM events WHERE kind = 'path';")
        return EventCounts(total: total, activities: activities, visits: visits, paths: paths)
    }

    private static func scalarInt(_ database: SQLCipherDatabase, sql: String) throws -> Int {
        let stmt = try database.prepare(sql)
        defer { stmt.finalize() }
        switch try stmt.step() {
        case .row: return stmt.columnInt(0)
        case .done: return 0
        }
    }
}
