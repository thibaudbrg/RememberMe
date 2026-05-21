import Core
import Foundation
import SQLCipher

/// Errors surfaced by `SQLCipherDatabase` and its prepared statements.
public enum DatabaseError: Error, CustomStringConvertible {
    case openFailed(path: String, code: Int32, message: String)
    case keyRejected(message: String)
    case prepareFailed(sql: String, code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
    case bindFailed(parameterIndex: Int32, code: Int32, message: String)
    case unexpectedColumnType(columnIndex: Int32, sql: String)

    public var description: String {
        switch self {
        case let .openFailed(path, code, message):
            "openFailed(path=\(path), code=\(code), message=\(message))"
        case let .keyRejected(message):
            "keyRejected(\(message))"
        case let .prepareFailed(sql, code, message):
            "prepareFailed(code=\(code), message=\(message), sql=\(sql))"
        case let .stepFailed(code, message):
            "stepFailed(code=\(code), message=\(message))"
        case let .bindFailed(parameterIndex, code, message):
            "bindFailed(index=\(parameterIndex), code=\(code), message=\(message))"
        case let .unexpectedColumnType(columnIndex, sql):
            "unexpectedColumnType(column=\(columnIndex), sql=\(sql))"
        }
    }
}

/// Thin Swift wrapper around an opaque SQLite handle compiled with SQLCipher.
///
/// Marked `@unchecked Sendable` because we open with `SQLITE_OPEN_FULLMUTEX`, which makes SQLite
/// itself serialise concurrent C-API calls on the same handle. Prepared statements (`PreparedStatement`)
/// are also `@unchecked Sendable` for the same reason — but a single statement should not be stepped
/// from two threads at once; the codebase only ever uses a statement within one function call.
public final class SQLCipherDatabase: @unchecked Sendable {
    /// Special path passed to `init` to open an ephemeral in-memory database. Used by tests.
    public static let inMemoryPath = ":memory:"

    private let handle: OpaquePointer

    /// Opens a database at `path` and unlocks it with the supplied raw key. Throws on any failure.
    ///
    /// The key is passed via `PRAGMA key = "x'<hex>'"` — SQLCipher uses the raw bytes directly and
    /// does NOT run its internal PBKDF2 KDF. This matches the contract documented in SECURITY.md.
    public init(path: String, key: DatabaseKey) throws {
        var rawHandle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openCode = sqlite3_open_v2(path, &rawHandle, flags, nil)
        guard openCode == SQLITE_OK, let opened = rawHandle else {
            let message = rawHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "<no handle>"
            if let h = rawHandle { sqlite3_close(h) }
            throw DatabaseError.openFailed(path: path, code: openCode, message: message)
        }
        handle = opened

        // Set the key. `sqlite3_key_v2` would also work, but PRAGMA is what SECURITY.md documents.
        // We escape nothing — the hex blob is built from random bytes we control.
        let pragma = "PRAGMA key = \"\(key.hexBlob)\";"
        if sqlite3_exec(opened, pragma, nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(opened))
            sqlite3_close(opened)
            throw DatabaseError.keyRejected(message: message)
        }

        // SQLCipher accepts any key on the first PRAGMA; we have to actually try to read something
        // to find out whether the key was correct. This is the canonical sanity check from the
        // SQLCipher docs.
        var sanity: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(opened, "SELECT count(*) FROM sqlite_master;", -1, &sanity, nil)
        if prepareCode != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(opened))
            sqlite3_close(opened)
            throw DatabaseError.keyRejected(message: message)
        }
        if sqlite3_step(sanity) != SQLITE_ROW {
            let message = String(cString: sqlite3_errmsg(opened))
            sqlite3_finalize(sanity)
            sqlite3_close(opened)
            throw DatabaseError.keyRejected(message: message)
        }
        sqlite3_finalize(sanity)

        // Reasonable durability defaults. WAL mode improves concurrency on iOS.
        _ = try? execute("PRAGMA journal_mode = WAL;")
        _ = try? execute("PRAGMA synchronous = NORMAL;")
        _ = try? execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs one or more SQL statements that don't return rows. Useful for CREATE TABLE, PRAGMA, BEGIN, COMMIT.
    @discardableResult
    public func execute(_ sql: String) throws -> Int32 {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if code != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw DatabaseError.stepFailed(code: code, message: message)
        }
        return code
    }

    /// Returns the current `user_version` PRAGMA. Used by `Migrations` to decide what to apply.
    public func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version;")
        defer { statement.finalize() }
        switch statement.step() {
        case .row: return statement.columnInt32(0)
        case .done: return 0
        }
    }

    public func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    public func prepare(_ sql: String) throws -> PreparedStatement {
        var rawStatement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &rawStatement, nil)
        guard code == SQLITE_OK, let prepared = rawStatement else {
            let message = String(cString: sqlite3_errmsg(handle))
            if let s = rawStatement { sqlite3_finalize(s) }
            throw DatabaseError.prepareFailed(sql: sql, code: code, message: message)
        }
        return PreparedStatement(handle: prepared, dbHandle: handle, sql: sql)
    }

    /// Runs `block` inside `BEGIN IMMEDIATE` / `COMMIT`. Rolls back on throw.
    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        let result: T
        do {
            result = try block()
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
        try execute("COMMIT;")
        return result
    }
}
