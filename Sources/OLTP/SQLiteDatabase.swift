import Foundation
import SQLite3

// ─────────────────────────────────────────────────────────────
// The one database shape that takes concurrent writers (ARCHITECTURE §19.17).
//
// The gap this fills only appeared with M16. SurrealDB holds the semi-structured
// side and DuckDB the analytical side, and neither is built for "twenty people
// fill in a form at the same time while the app reads": DuckDB is an OLAP engine
// designed around a single writer, and pointing a web server's INSERTs at it is
// using it for the wrong kind of work — it does not fail on the developer's
// machine, it fails on the day of real fieldwork, which is the day it cannot be
// redone.
//
// SQLite in WAL mode is the answer that adds nothing to the package: it ships
// with the operating system, so there is no third sidecar to bundle, sign and
// keep alive, and DuckDB can `ATTACH` the file and read across without anybody
// writing an ETL.
//
// This is a thin, honest wrapper — prepare, bind, step — and not an ORM. The
// thing that matters here is the concurrency configuration, which is why it is
// stated once, at the top, in one place.
// ─────────────────────────────────────────────────────────────

public enum SQLiteError: Error, CustomStringConvertible, Equatable {
    case open(path: String, message: String)
    case statement(sql: String, message: String)

    public var description: String {
        switch self {
        case .open(let path, let message): "เปิดฐานข้อมูล \(path) ไม่ได้: \(message)"
        case .statement(let sql, let message): "คำสั่ง SQL ล้มเหลว: \(message) — \(sql)"
        }
    }
}

/// A value bound to a statement parameter. A closed set: everything M16 stores
/// is text, a number or nothing, and an `Any` here would put "whatever the form
/// sent" straight into a bind call.
public enum SQLiteValue: Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case double(Double)
    case null
}

/// One row, as columns in the order they were selected.
public struct SQLiteRow: Sendable, Equatable {
    public let columns: [String]
    public let values: [SQLiteValue]

    public subscript(_ column: String) -> SQLiteValue? {
        guard let index = columns.firstIndex(of: column) else { return nil }
        return values[index]
    }

    public func string(_ column: String) -> String? {
        if case .text(let value) = self[column] { return value }
        return nil
    }

    public func integer(_ column: String) -> Int64? {
        if case .integer(let value) = self[column] { return value }
        return nil
    }
}

/// One connection, serialised by being an actor.
///
/// Serialised deliberately rather than pooled: WAL's promise is many readers and
/// **one** writer at a time, with the others queueing. An actor is exactly that
/// queue, and it is cheaper to be honest about it here than to discover the
/// contention through `SQLITE_BUSY` on the day twenty people are answering.
public actor SQLiteDatabase {
    private var handle: OpaquePointer?
    public let path: String

    /// SQLite's own constant for "give this text back to me, I own it" — passing
    /// nil here would let SQLite keep a pointer to a Swift string that has gone.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL) throws {
        self.path = path.path(percentEncoded: false)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(self.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw SQLiteError.open(path: self.path, message: message)
        }
        self.handle = handle

        // The three settings that make this a store for fieldwork rather than a
        // file that happens to hold rows:
        //   WAL      — readers do not block the writer and the writer does not
        //              block readers, which is the whole reason this file exists.
        //   NORMAL   — fsync at checkpoints rather than on every commit. With WAL
        //              this is durable across an app crash, which is the failure
        //              worth surviving; the one it trades away is a power cut
        //              mid-answer.
        //   busy 5s  — a second writer waits rather than returning SQLITE_BUSY,
        //              because "your answer was not saved, try again" is not a
        //              thing to say to somebody halfway through a questionnaire.
        for pragma in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=NORMAL",
                       "PRAGMA busy_timeout=5000", "PRAGMA foreign_keys=ON"] {
            sqlite3_exec(handle, pragma, nil, nil, nil)
        }
    }

    isolated deinit {
        sqlite3_close_v2(handle)
        handle = nil
    }

    /// Executes a statement that returns nothing.
    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        try run(sql, bindings)
    }

    /// Executes a statement and collects its rows.
    public func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        var rows: [SQLiteRow] = []
        try step(sql, bindings) { statement in
            let count = Int(sqlite3_column_count(statement))
            var columns: [String] = []
            var values: [SQLiteValue] = []
            for index in 0..<count {
                columns.append(String(cString: sqlite3_column_name(statement, Int32(index))))
                values.append(Self.value(statement, at: Int32(index)))
            }
            rows.append(SQLiteRow(columns: columns, values: values))
        }
        return rows
    }

    /// Runs several statements inside one transaction, so a submission is either
    /// wholly stored or wholly absent. A half-written answer set is worse than a
    /// rejected one: it looks like data.
    ///
    /// A list of statements rather than a closure, on purpose: a transaction that
    /// can run arbitrary code is a transaction somebody eventually awaits inside,
    /// holding a write lock across a suspension while twenty people wait behind
    /// it.
    public func transaction(_ statements: [(sql: String, bindings: [SQLiteValue])]) throws {
        try run("BEGIN IMMEDIATE")
        do {
            for statement in statements {
                try run(statement.sql, statement.bindings)
            }
            try run("COMMIT")
        } catch {
            _ = try? run("ROLLBACK")
            throw error
        }
    }

    // MARK: - the thin part

    @discardableResult
    private func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        try step(sql, bindings) { _ in }
        return Int(sqlite3_changes(handle))
    }

    private func step(_ sql: String, _ bindings: [SQLiteValue],
                      _ each: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteError.statement(sql: sql, message: lastMessage())
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch binding {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .null: sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else {
                throw SQLiteError.statement(sql: sql, message: lastMessage())
            }
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: each(statement)
            case SQLITE_DONE: return
            default: throw SQLiteError.statement(sql: sql, message: lastMessage())
            }
        }
    }

    private func lastMessage() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private static func value(_ statement: OpaquePointer, at index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .double(sqlite3_column_double(statement, index))
        case SQLITE_NULL: .null
        default:
            if let text = sqlite3_column_text(statement, index) {
                .text(String(cString: text))
            } else {
                .null
            }
        }
    }
}
