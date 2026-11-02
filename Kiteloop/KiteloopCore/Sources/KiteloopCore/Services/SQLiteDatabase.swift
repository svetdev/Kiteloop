import Foundation
import SQLite3

/// Tells SQLite the bytes it was handed may be freed the moment `sqlite3_step`
/// returns, so it must copy them. Binding a Swift `String` without this hands
/// SQLite a pointer that dies at the end of the `withCString` call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

package enum SQLiteError: Error, CustomStringConvertible {
    case open(path: String, message: String)
    case prepare(sql: String, message: String)
    case step(sql: String, message: String)

    package var description: String {
        switch self {
        case .open(let path, let message): "SQLite could not open \(path): \(message)"
        case .prepare(let sql, let message): "SQLite could not prepare \(sql): \(message)"
        case .step(let sql, let message): "SQLite failed running \(sql): \(message)"
        }
    }
}

/// A value bound to a statement placeholder. `null` is a first-class case rather
/// than something the caller works around: across this app "not recorded" and
/// "zero" are different facts, and a `NULL` is how the first one survives a
/// round trip through the database.
package enum SQLiteValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    package static func of(_ value: Int?) -> SQLiteValue { value.map { .int(Int64($0)) } ?? .null }
    package static func of(_ value: Double?) -> SQLiteValue { value.map { .double($0) } ?? .null }
    package static func of(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
    package static func of(_ value: Bool?) -> SQLiteValue { value.map { .int($0 ? 1 : 0) } ?? .null }
    /// Dates are stored as epoch seconds — a REAL that sorts, subtracts and
    /// aggregates, which an ISO-8601 string does not.
    package static func of(_ value: Date?) -> SQLiteValue { value.map { .double($0.timeIntervalSince1970) } ?? .null }
}

/// The minimum needed to talk to SQLite from Swift: open a file, run statements,
/// read rows back. Deliberately not a general query builder or an ORM — this
/// exists so `MetricIndex` can hold a schema it wrote by hand.
///
/// Not `Sendable`, and not thread-safe by itself: the handle is owned by one
/// actor, which is what serialises access to it.
package final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// The open database's file, so a caller can delete it to force a rebuild.
    package let url: URL

    package init(url: URL) throws {
        self.url = url
        let path = url.path(percentEncoded: false)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(db)
            throw SQLiteError.open(path: path, message: message)
        }
        self.handle = db
        // WAL keeps a reader (a `/v1/metrics` call) from blocking the writer that
        // is catching the index up, and `NORMAL` is the durability the projection
        // wants: the JSONL log is the thing that must survive a crash, and a lost
        // tail here is recovered by replaying it.
        try? execute("PRAGMA journal_mode = WAL")
        try? execute("PRAGMA synchronous = NORMAL")
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// The schema revision stamped into the file. `MetricIndex` uses it to decide
    /// whether the database on disk was written by the schema this build knows —
    /// and when it wasn't, drops and replays rather than migrating.
    ///
    /// A file with no stamp reads `0`, which is what makes an unstamped database
    /// look stale — so writing the stamp is `setUserVersion`, which throws. A
    /// swallowed write here is invisible in exactly the wrong way: the caller
    /// carries on with a database that will be dropped and replayed again on the
    /// next open, and on every one after it.
    package var userVersion: Int32 {
        (try? query("PRAGMA user_version") { Int32($0.int(0)) })?.first ?? 0
    }

    /// Stamps the schema revision into the file. `PRAGMA user_version` takes no
    /// bindings, so the value is interpolated — it is an `Int32`, not caller text.
    package func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    /// Runs one or more statements with no bindings and no results.
    package func execute(_ sql: String) throws {
        guard let handle else { return }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw SQLiteError.step(sql: sql, message: message)
        }
    }

    /// Runs one parameterised statement that returns no rows.
    package func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SQLiteError.step(sql: sql, message: lastErrorMessage)
        }
    }

    /// Runs one parameterised query, decoding each row with `decode`.
    package func query<T>(_ sql: String, _ parameters: [SQLiteValue] = [], _ decode: (Row) -> T) throws -> [T] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                rows.append(decode(Row(statement: statement)))
            } else if status == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.step(sql: sql, message: lastErrorMessage)
            }
        }
        return rows
    }

    /// Runs `body` inside one transaction, rolling back if it throws. Ingest uses
    /// it per source file so a decode failure part-way through cannot leave the
    /// rows and the consumed-bytes marker disagreeing.
    package func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw SQLiteError.prepare(sql: sql, message: lastErrorMessage)
        }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    /// One result row, valid only for the duration of the `decode` call it is
    /// handed to — it points straight at SQLite's statement.
    package struct Row {
        package let statement: OpaquePointer?

        package func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }

        package func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        package func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

        package func text(_ column: Int32) -> String {
            guard let cString = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: cString)
        }

        package func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }

        // The optional accessors are the reason `isNull` exists: a NULL column
        // read through `int`/`double` comes back as 0, which is the one value
        // this app's metrics must never confuse with "nothing was recorded".
        package func optInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
        package func optDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
        package func optText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
        package func optDate(_ column: Int32) -> Date? { isNull(column) ? nil : date(column) }
        package func optBool(_ column: Int32) -> Bool? { isNull(column) ? nil : int(column) != 0 }

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(statement: OpaquePointer?) {
            self.statement = statement
        }
    }
}
