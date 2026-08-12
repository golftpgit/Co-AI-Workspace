import Foundation
import DuckDB
import Observability

// ─────────────────────────────────────────────────────────────
// Reading somebody else's database without copying it (ARCHITECTURE §12.2,
// P6.2).
//
// The reason this is worth having: research data lives in whatever the lab
// already runs — a Postgres instance, a SQL Server, a SQLite file somebody
// emailed. Copying it into the analysis store means the copy is stale the
// moment it lands, and means asking for an export before any question can be
// answered. DuckDB's scanners let a query join a local table to a remote one
// in place.
//
// What this file does *not* do is pretend an extension is installed when it is
// not. `INSTALL` reaches out to DuckDB's extension repository the first time,
// so on a machine with no network the honest answer is "this connector is not
// available here", not a query that fails halfway with a parser error.
// ─────────────────────────────────────────────────────────────

public enum ConnectorKind: String, Sendable, CaseIterable, Codable {
    case sqlite
    case postgres
    case mysql

    /// The DuckDB extension that provides the scanner.
    public var extensionName: String {
        switch self {
        case .sqlite: "sqlite_scanner"
        case .postgres: "postgres_scanner"
        case .mysql: "mysql_scanner"
        }
    }

    /// What `ATTACH … (TYPE …)` expects.
    public var attachType: String {
        switch self {
        case .sqlite: "sqlite"
        case .postgres: "postgres"
        case .mysql: "mysql"
        }
    }
}

public struct AttachedDatabase: Sendable, Equatable {
    /// The name the attached database answers to in SQL.
    public let alias: String
    public let kind: ConnectorKind
    /// A file path or a connection string, depending on the kind.
    public let target: String
    public let readOnly: Bool
}

extension AnalysisStore {

    /// Makes a connector available, downloading the extension on first use.
    ///
    /// Returns the extension's version so a failure to install is a value the
    /// caller can show, not an exception it has to interpret.
    @discardableResult
    public func install(_ kind: ConnectorKind) async throws -> String {
        try await query("INSTALL \(kind.extensionName)")
        try await query("LOAD \(kind.extensionName)")
        let result = try await query("""
        SELECT extension_version FROM duckdb_extensions()
        WHERE extension_name = \(Self.quotedString(kind.extensionName)) AND loaded
        """)
        return result.rows.first?.first.flatMap { $0 } ?? "loaded"
    }

    /// Attaches an external database so its tables can be queried in place.
    ///
    /// Read-only by default, and deliberately so: this is somebody else's
    /// production data far more often than it is ours, and §12.2's promise is
    /// "explore schema → pull table → or query directly", none of which needs
    /// write access.
    @discardableResult
    public func attach(_ target: String, as alias: String, kind: ConnectorKind,
                       readOnly: Bool = true) async throws -> AttachedDatabase {
        try await install(kind)
        let options = ["TYPE \(kind.attachType)"] + (readOnly ? ["READ_ONLY"] : [])
        try await query("""
        ATTACH IF NOT EXISTS \(Self.quotedString(target)) AS \(Self.quoted(alias)) \
        (\(options.joined(separator: ", ")))
        """)
        return AttachedDatabase(alias: alias, kind: kind, target: target, readOnly: readOnly)
    }

    public func detach(_ alias: String) async throws {
        try await query("DETACH \(Self.quoted(alias))")
    }

    /// Everything attached right now, including the store itself.
    public func attachedDatabases() async throws -> [String] {
        let result = try await query("SELECT database_name FROM duckdb_databases()")
        return result.rows.compactMap { $0.first ?? nil }
    }

    /// The tables an attached database exposes — the "explore schema" half of
    /// §12.2, before anyone decides whether to pull or to query in place.
    public func tables(in alias: String) async throws -> [String] {
        let statement = try PreparedStatement(connection: connection, query: """
        SELECT table_name FROM information_schema.tables
        WHERE table_catalog = ? ORDER BY table_name
        """)
        try statement.bind(alias, at: 1)
        return AnalysisStore.firstColumn(of: try execute(statement))
    }

    /// Copies a remote table into the store.
    ///
    /// The alternative to a federated query rather than a replacement for it:
    /// a pull is what you want when the analysis will be run twenty times and
    /// the source is slow or far away, and a stale copy is a real cost, so the
    /// caller chooses rather than the store choosing for them.
    @discardableResult
    public func pull(_ table: String, from alias: String,
                     into localName: String? = nil) async throws -> QueryResult {
        let destination = localName ?? table
        return try await query("""
        CREATE OR REPLACE TABLE \(Self.quoted(destination)) AS
        SELECT * FROM \(Self.quoted(alias)).\(Self.quoted(table))
        """)
    }
}
