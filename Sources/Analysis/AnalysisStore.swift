import Foundation
import DuckDB
import Observability

// ─────────────────────────────────────────────────────────────
// The analysis store (ARCHITECTURE §12.1, P6.1).
//
// DuckDB rather than SQLite because the work here is columnar and ad hoc —
// window functions, joins across a pulled table and a CSV, aggregates over a
// few million rows — and because a `.duckdb` file is something the user can
// open in DBeaver when they want to leave. §12.1 weighed the alternatives.
//
// Two decisions shape this file:
//
//  • **Results are values, not cursors.** A query hands back a fully
//    materialised `QueryResult`, so nothing downstream holds a live handle
//    into the database across an await. The alternative is a cursor whose
//    lifetime nobody can see, and this project has already paid for one of
//    those (v1's D6).
//  • **Every column arrives as text plus a type name.** The screen and the
//    agent both need something printable; a Notebook cell that renders
//    `Optional(3.14)` is the sort of detail that makes a result untrustworthy.
// ─────────────────────────────────────────────────────────────

public struct QueryResult: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public let name: String
        /// DuckDB's own name for the type, so a surprising value can be
        /// explained ("that is a VARCHAR, which is why it sorts oddly").
        public let type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public let columns: [Column]
    /// Row-major, already rendered. `nil` is SQL NULL and is kept distinct
    /// from the empty string, which is a value someone may have stored.
    public let rows: [[String?]]
    /// How long DuckDB took, for the cell footer.
    public let duration: Duration

    public var rowCount: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty }

    public init(columns: [Column], rows: [[String?]], duration: Duration = .zero) {
        self.columns = columns
        self.rows = rows
        self.duration = duration
    }
}

public enum AnalysisError: Error, CustomStringConvertible, Equatable {
    case openFailed(String)
    case queryFailed(sql: String, message: String)

    public var description: String {
        switch self {
        case .openFailed(let message): "เปิดฐานข้อมูลวิเคราะห์ไม่ได้: \(message)"
        case .queryFailed(_, let message): "คำสั่ง SQL ล้มเหลว: \(message)"
        }
    }
}

public actor AnalysisStore {
    private let database: Database
    /// Visible inside the module so `Federation` can prepare statements on the
    /// same connection — an attached database belongs to a connection, not to
    /// the process.
    let connection: Connection
    /// Nil for an in-memory store, which is what tests and scratch work use.
    public nonisolated let fileURL: URL?
    private let log = AppLog.logger("analysis")

    /// Opens (or creates) the store.
    ///
    /// - Parameter fileURL: nil for in-memory. A file is the normal case: the
    ///   point of an analysis store is that yesterday's pulled tables are
    ///   still there today.
    public init(fileURL: URL? = nil) throws {
        do {
            if let fileURL {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                database = try Database(store: .file(at: fileURL))
            } else {
                database = try Database(store: .inMemory)
            }
            connection = try database.connect()
            self.fileURL = fileURL
        } catch {
            throw AnalysisError.openFailed("\(error)")
        }
    }

    /// Runs one statement and materialises the answer.
    ///
    /// Deliberately not variadic or multi-statement: a cell that runs three
    /// statements and shows one table has hidden two results, and the SQL
    /// guard (P6.5) has to see each statement to know whether it mutates.
    @discardableResult
    public func query(_ sql: String) async throws -> QueryResult {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let result = try connection.query(sql)
            let columns = Self.columns(of: result)
            // A second pass with everything cast to text, used only for the
            // types the renderer does not model (lists, structs, intervals).
            // Asked for lazily: it costs a query, and most results never need
            // it.
            let textual = columns.contains { !Self.rendersDirectly($0.type) }
                ? try? connection.query(Self.asTextQuery(sql, columns: columns))
                : nil
            return QueryResult(columns: columns,
                               rows: Self.rows(of: result, textual: textual),
                               duration: started.duration(to: clock.now))
        } catch {
            // The SQL is carried with the message: by the time an error
            // reaches a screen or an agent, "syntax error at or near" with no
            // statement beside it is unactionable.
            let message = String(describing: error)
            log.error("query failed: \(message, privacy: .public)")
            throw AnalysisError.queryFailed(sql: sql, message: message)
        }
    }

    /// The tables this store holds, for the explorer and for an agent that has
    /// to know what it may join.
    public func tables() async throws -> [String] {
        let result = try await query("SHOW TABLES")
        return result.rows.compactMap { $0.first ?? nil }
    }

    /// Runs a statement on this store's connection, for the federation helpers
    /// that need a prepared statement rather than a string.
    func execute(_ statement: PreparedStatement) throws -> ResultSet {
        try statement.execute()
    }

    /// Column names and types of one table.
    ///
    /// Read out of `information_schema` with the name **bound as a parameter**
    /// rather than through `DESCRIBE`: DESCRIBE takes a qualified name, and
    /// DuckDB's parser rejects a doubled quote inside one ("Unterminated quote
    /// in qualified name"), so a legally-named table like `weird"name` could
    /// be created and then never described. A bound parameter has no quoting
    /// problem to get wrong.
    public func schema(of table: String) async throws -> [QueryResult.Column] {
        let statement = try PreparedStatement(connection: connection, query: """
        SELECT column_name, data_type FROM information_schema.columns
        WHERE table_name = ? ORDER BY ordinal_position
        """)
        try statement.bind(table, at: 1)
        let result = try statement.execute()
        let rows = Self.rows(of: result, textual: nil)
        return rows.compactMap { row in
            guard let name = row.first ?? nil, row.count > 1, let type = row[1] else { return nil }
            return QueryResult.Column(name: name, type: type)
        }
    }

    /// Reads a CSV or Parquet file into a table, letting DuckDB infer the
    /// schema.
    @discardableResult
    public func importFile(_ url: URL, into table: String) async throws -> QueryResult {
        try await query(Self.importStatement(url, into: table))
    }

    /// The statement `importFile` would run.
    ///
    /// Exposed because an import overwrites a table of the same name, and the
    /// screen has to put that in front of the SQL guard like any other
    /// statement (P6.5) rather than keeping a second opinion about what is
    /// destructive. The path is quoted, not concatenated.
    public static func importStatement(_ url: URL, into table: String) -> String {
        let path = url.path(percentEncoded: false)
        let reader = url.pathExtension.lowercased() == "parquet"
            ? "read_parquet(\(quotedString(path)))"
            : "read_csv_auto(\(quotedString(path)))"
        return "CREATE OR REPLACE TABLE \(quoted(table)) AS SELECT * FROM \(reader)"
    }

    /// The first column of a result, as text — the shape half the catalogue
    /// queries in this module want.
    static func firstColumn(of result: ResultSet) -> [String] {
        rows(of: result, textual: nil).compactMap { $0.first ?? nil }
    }

    // MARK: - quoting

    /// A double-quoted identifier, with any embedded quote doubled — the SQL
    /// standard's escape, and the reason a table name can never become a
    /// statement.
    ///
    /// Public because the explorer builds `SELECT * FROM <table>` out of a name
    /// the user clicked, and it must use this rather than a second attempt at
    /// the same escape.
    public static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func quotedString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: - reading DuckDB's result

    private static func columns(of result: ResultSet) -> [QueryResult.Column] {
        (0..<result.columnCount).map { index in
            let column = result[index]
            return QueryResult.Column(name: result.columnName(at: index),
                                      type: Self.name(of: column.underlyingDatabaseType))
        }
    }

    /// Renders every column as text.
    ///
    /// A cast in this library only succeeds when the Swift type matches the
    /// column's actual type — casting a BIGINT to String yields a column of
    /// nils, not "42". So each column is read through the type DuckDB says it
    /// is, and only then turned into text. Getting this wrong does not throw;
    /// it silently blanks the table, which is the worst way for a result to be
    /// wrong.
    private static func rows(of result: ResultSet, textual: ResultSet?) -> [[String?]] {
        let rowCount = Int(result.rowCount)
        let rendered: [[String?]] = (0..<result.columnCount).map { index in
            let direct = Self.render(result[index])
            if !direct.isEmpty { return direct }
            // A type this renderer does not model: take DuckDB's own text
            // form, which the store asked for alongside the real result.
            guard let textual, index < textual.columnCount else {
                return Array(repeating: nil, count: rowCount)
            }
            return (0..<textual[index].count).map { textual[index].cast(to: String.self)[DBInt($0)] }
        }
        guard let first = rendered.first else { return [] }
        return (0..<first.count).map { row in rendered.map { $0[row] } }
    }

    private static func render(_ column: Column<Void>) -> [String?] {
        func map<T>(_ typed: Column<T>, _ text: @escaping (T) -> String) -> [String?] {
            (0..<typed.count).map { typed[DBInt($0)].map(text) }
        }
        switch column.underlyingDatabaseType {
        case .boolean: return map(column.cast(to: Bool.self)) { $0 ? "true" : "false" }
        case .tinyint: return map(column.cast(to: Int8.self)) { "\($0)" }
        case .smallint: return map(column.cast(to: Int16.self)) { "\($0)" }
        case .integer: return map(column.cast(to: Int32.self)) { "\($0)" }
        case .bigint: return map(column.cast(to: Int64.self)) { "\($0)" }
        case .utinyint: return map(column.cast(to: UInt8.self)) { "\($0)" }
        case .usmallint: return map(column.cast(to: UInt16.self)) { "\($0)" }
        case .uinteger: return map(column.cast(to: UInt32.self)) { "\($0)" }
        case .ubigint: return map(column.cast(to: UInt64.self)) { "\($0)" }
        case .float: return map(column.cast(to: Float.self)) { "\($0)" }
        case .double: return map(column.cast(to: Double.self)) { "\($0)" }
        case .decimal: return map(column.cast(to: Decimal.self)) { "\($0)" }
        // DuckDB's own date/time types, not Foundation's: `cast(to:)` matches
        // on the column's real type, and asking for a `Foundation.Date` where
        // the column is a DuckDB `Date` yields a column of nils.
        case .date:
            return map(column.cast(to: DuckDB.Date.self)) { Self.day($0) }
        case .timestamp, .timestampS, .timestampMS, .timestampNS:
            return map(column.cast(to: Timestamp.self)) { Self.instant($0) }
        case .time: return map(column.cast(to: Time.self)) { "\($0.components)" }
        case .uuid: return map(column.cast(to: UUID.self)) { $0.uuidString }
        case .varchar, .enum: return map(column.cast(to: String.self)) { $0 }
        default:
            // Lists, structs, maps, intervals, blobs — everything this
            // renderer does not model. `cast(to: String.self)` would blank
            // them (a cast never fails, it just returns nils), so they are
            // rendered by DuckDB itself in a second pass; see `textual`.
            return []
        }
    }

    /// Whether `render` handles this type without DuckDB's help.
    static func rendersDirectly(_ typeName: String) -> Bool {
        !["list", "struct", "map", "union", "interval", "blob", "hugeint", "uhugeint",
          "timestampTZ", "timeTZ", "bit", "array"].contains(typeName)
    }

    /// The same query with every column cast to text, so DuckDB renders the
    /// shapes this file does not model. Wrapped rather than rewritten: the
    /// user's SQL is not edited, only selected from.
    static func asTextQuery(_ sql: String, columns: [QueryResult.Column]) -> String {
        let projections = columns.enumerated().map { index, column in
            "CAST(\(quoted(column.name)) AS VARCHAR) AS \(quoted("c\(index)"))"
        }.joined(separator: ", ")
        return "SELECT \(projections) FROM (\(sql))"
    }

    private static func name(of type: DatabaseType) -> String {
        // `DatabaseType`'s description is `DatabaseType.bigint`; the column
        // header wants `bigint`.
        "\(type)".split(separator: ".").last.map(String.init) ?? "\(type)"
    }

    /// DuckDB counts days from the Unix epoch; rendered in UTC so a date
    /// column reads the same wherever the machine is.
    private static func day(_ date: DuckDB.Date) -> String {
        let components = date.components
        return String(format: "%04d-%02d-%02d", components.year, components.month,
                      components.day)
    }

    private static func instant(_ timestamp: Timestamp) -> String {
        let seconds = Double(timestamp.microseconds) / 1_000_000
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Foundation.Date(timeIntervalSince1970: seconds))
    }
}
