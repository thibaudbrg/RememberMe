import Foundation
import SQLCipher

/// A prepared SQLite statement. Callers bind parameters, step rows, and ultimately call `finalize()`.
/// Single-threaded use only — see `SQLCipherDatabase`'s docs for the concurrency story.
public final class PreparedStatement: @unchecked Sendable {
    /// Result of a single `step()` call.
    public enum StepResult {
        /// `sqlite3_step` returned `SQLITE_ROW` — a row of results is available via the `column…` accessors.
        case row
        /// `sqlite3_step` returned `SQLITE_DONE` — the statement has finished executing.
        case done
    }

    private let handle: OpaquePointer
    private let dbHandle: OpaquePointer
    private let sql: String
    private var finalized = false

    init(handle: OpaquePointer, dbHandle: OpaquePointer, sql: String) {
        self.handle = handle
        self.dbHandle = dbHandle
        self.sql = sql
    }

    deinit {
        if !finalized {
            sqlite3_finalize(handle)
        }
    }

    public func finalize() {
        if !finalized {
            sqlite3_finalize(handle)
            finalized = true
        }
    }

    /// Resets the statement so it can be re-stepped with new bindings. Does NOT clear bindings.
    public func reset() throws {
        let code = sqlite3_reset(handle)
        if code != SQLITE_OK {
            throw DatabaseError.stepFailed(code: code, message: String(cString: sqlite3_errmsg(dbHandle)))
        }
    }

    /// Clears all parameter bindings.
    public func clearBindings() throws {
        let code = sqlite3_clear_bindings(handle)
        if code != SQLITE_OK {
            throw DatabaseError.stepFailed(code: code, message: String(cString: sqlite3_errmsg(dbHandle)))
        }
    }

    public func step() -> StepResult {
        sqlite3_step(handle) == SQLITE_ROW ? .row : .done
    }

    /// Steps once and asserts the result is `.done`. Used for INSERT/UPDATE/DELETE.
    public func stepDone() throws {
        let code = sqlite3_step(handle)
        if code != SQLITE_DONE {
            throw DatabaseError.stepFailed(code: code, message: String(cString: sqlite3_errmsg(dbHandle)))
        }
    }

    // MARK: - Binding (1-indexed, as in the SQLite C API)

    public func bind(_ index: Int32, text: String) throws {
        // SQLITE_TRANSIENT (-1) tells SQLite to make its own copy. Safer than SQLITE_STATIC.
        let code = sqlite3_bind_text(handle, index, text, -1, SQLITE_TRANSIENT)
        if code != SQLITE_OK {
            throw DatabaseError.bindFailed(
                parameterIndex: index, code: code, message: String(cString: sqlite3_errmsg(dbHandle))
            )
        }
    }

    public func bind(_ index: Int32, int64: Int64) throws {
        let code = sqlite3_bind_int64(handle, index, int64)
        if code != SQLITE_OK {
            throw DatabaseError.bindFailed(
                parameterIndex: index, code: code, message: String(cString: sqlite3_errmsg(dbHandle))
            )
        }
    }

    public func bind(_ index: Int32, int: Int) throws {
        try bind(index, int64: Int64(int))
    }

    public func bind(_ index: Int32, int32: Int32) throws {
        let code = sqlite3_bind_int(handle, index, int32)
        if code != SQLITE_OK {
            throw DatabaseError.bindFailed(
                parameterIndex: index, code: code, message: String(cString: sqlite3_errmsg(dbHandle))
            )
        }
    }

    public func bind(_ index: Int32, double: Double) throws {
        let code = sqlite3_bind_double(handle, index, double)
        if code != SQLITE_OK {
            throw DatabaseError.bindFailed(
                parameterIndex: index, code: code, message: String(cString: sqlite3_errmsg(dbHandle))
            )
        }
    }

    public func bindNull(_ index: Int32) throws {
        let code = sqlite3_bind_null(handle, index)
        if code != SQLITE_OK {
            throw DatabaseError.bindFailed(
                parameterIndex: index, code: code, message: String(cString: sqlite3_errmsg(dbHandle))
            )
        }
    }

    // MARK: - Reading columns (0-indexed)

    public func columnInt32(_ index: Int32) -> Int32 {
        sqlite3_column_int(handle, index)
    }

    public func columnInt64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    public func columnInt(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(handle, index))
    }

    public func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    public func columnText(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: cString)
    }
}

/// Tells SQLite to copy bind values rather than treating the supplied pointer as long-lived.
/// `SQLITE_TRANSIENT` is defined as `(sqlite3_destructor_type)-1` in the C headers; Swift needs the cast.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
