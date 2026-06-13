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
/// Marked `@unchecked Sendable`. We open with `SQLITE_OPEN_FULLMUTEX`, which serialises individual
/// C-API calls on the same handle — but that only covers a single call, NOT the multi-statement
/// scope of a transaction. Because the codebase drives this one shared connection from several
/// threads at once (live tracker, importer, geocoder, refinement), an `NSRecursiveLock` serialises
/// access so a transaction owns the connection for its whole `BEGIN…COMMIT` scope and single-statement
/// writes can't silently interleave into another thread's open transaction. The lock is recursive so
/// statements run inside a `transaction` block re-enter on the same thread.
public final class SQLCipherDatabase: @unchecked Sendable {
    /// Special path passed to `init` to open an ephemeral in-memory database. Used by tests.
    public static let inMemoryPath = ":memory:"

    private let handle: OpaquePointer

    /// Serialises access to the single shared connection across threads. Held for the whole scope of
    /// `transaction()` and around every single-statement write path. Recursive so a transaction
    /// block's own `execute`/`prepare`/`step` calls re-enter without deadlocking.
    private let lock = NSRecursiveLock()

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
        lock.lock()
        defer { lock.unlock() }
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
        switch try statement.step() {
        case .row: return statement.columnInt32(0)
        case .done: return 0
        }
    }

    public func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    /// Prepares a statement. Acquires `lock` and hands ownership of it to the returned
    /// `PreparedStatement`, which releases it on `finalize()`/`deinit` — so the whole
    /// prepare→bind→step→finalize lifecycle of a single-statement read/write owns the connection
    /// and can't interleave into another thread's open transaction. Every call site finalises in a
    /// `defer`, so the lock is always released. Recursive, so statements inside a `transaction` block
    /// re-enter on the same thread.
    public func prepare(_ sql: String) throws -> PreparedStatement {
        lock.lock()
        var rawStatement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &rawStatement, nil)
        guard code == SQLITE_OK, let prepared = rawStatement else {
            let message = String(cString: sqlite3_errmsg(handle))
            if let s = rawStatement { sqlite3_finalize(s) }
            lock.unlock()
            throw DatabaseError.prepareFailed(sql: sql, code: code, message: message)
        }
        return PreparedStatement(handle: prepared, dbHandle: handle, sql: sql, lock: lock)
    }

    /// Runs `block` inside `BEGIN IMMEDIATE` / `COMMIT`. Rolls back on throw.
    ///
    /// Holds `lock` for the entire `BEGIN…COMMIT/ROLLBACK` scope so the transaction owns the
    /// connection — no other thread's statement can interleave into it. The lock is recursive, so the
    /// block's own `execute`/`prepare`/`step` calls re-enter on this thread without deadlocking.
    public func transaction<T>(_ block: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        let result: T
        do {
            result = try block()
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
        do {
            try execute("COMMIT;")
        } catch {
            // A failed COMMIT (SQLITE_FULL, I/O error, …) can leave the connection inside the open
            // transaction. Roll back to restore autocommit before rethrowing; if SQLite already
            // auto-rolled-back, the ROLLBACK just errors harmlessly and is ignored.
            _ = try? execute("ROLLBACK;")
            throw error
        }
        return result
    }
}
