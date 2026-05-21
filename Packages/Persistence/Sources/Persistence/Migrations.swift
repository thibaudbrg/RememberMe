import Foundation

/// Applies the SQL schema to a fresh database and runs upgrades on existing ones.
/// The current `user_version` PRAGMA records what's been applied; we only ever
/// move it forward in single-step increments.
public enum Migrations {
    /// Migration steps, indexed by the version they bring the database TO.
    /// Add a new entry whenever `Schema.currentVersion` is bumped.
    public static let steps: [Int32: String] = [
        1: Schema.v1,
    ]

    /// Runs whatever upgrades are needed to bring `database` up to `Schema.currentVersion`.
    /// No-op if already at the latest version.
    public static func apply(to database: SQLCipherDatabase) throws {
        let current = try database.userVersion()
        if current == Schema.currentVersion { return }
        if current > Schema.currentVersion {
            throw MigrationError.databaseFromFuture(found: current, expected: Schema.currentVersion)
        }

        try database.transaction {
            var version = current
            while version < Schema.currentVersion {
                let next = version + 1
                guard let sql = steps[next] else {
                    throw MigrationError.missingStep(version: next)
                }
                try database.execute(sql)
                version = next
            }
            try database.setUserVersion(Schema.currentVersion)
        }
    }
}

public enum MigrationError: Error, CustomStringConvertible {
    case missingStep(version: Int32)
    case databaseFromFuture(found: Int32, expected: Int32)

    public var description: String {
        switch self {
        case let .missingStep(v):
            "missing migration step for version \(v)"
        case let .databaseFromFuture(found, expected):
            "database is at version \(found) but this build only knows up to \(expected); refusing to open"
        }
    }
}
