import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Connections to other people's databases (ARCHITECTURE §12.2, P6.3).
//
// P6.2 proved the mechanism — INSTALL, ATTACH, join across, pull. What was
// missing was everything around it: a connection somebody can add without
// editing a plist, that is still there tomorrow, that belongs to a project
// rather than to the whole machine, and whose password is not sitting in a
// file.
//
// Two decisions this file exists to enforce:
//
//  • **The secret is never stored.** A connector keeps the *name of an
//    environment variable*, the same shape §9.3's endpoint registry settled on
//    (P5.5). What is written to disk cannot log anybody in.
//  • **The secret never reaches an error message.** `AnalysisError.queryFailed`
//    carries its SQL by design — which for `ATTACH '…password=…'` would put a
//    live credential in a log, a span and a screen. Every attach that
//    interpolates a secret redacts it before the error leaves this file.
// ─────────────────────────────────────────────────────────────

public struct DBConnector: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    /// The name it answers to in SQL — `SELECT * FROM lab.patients`.
    public var alias: String
    public var kind: ConnectorKind
    /// A file path for SQLite; a connection string with no password for the
    /// server kinds.
    public var target: String
    /// The environment variable the password is read from at connect time.
    /// Nil for SQLite and for servers that do not want one.
    public var secretVariable: String?
    /// §12.2: a connector belongs to a project or to the whole workspace.
    public var scope: Scope
    /// §12.2 attaches read-only by default because the data on the other end
    /// is usually somebody else's.
    public var readOnly: Bool

    public init(id: String = OpaqueID.make("con"),
                alias: String,
                kind: ConnectorKind,
                target: String,
                secretVariable: String? = nil,
                scope: Scope = .central,
                readOnly: Bool = true) {
        self.id = id
        self.alias = alias
        self.kind = kind
        self.target = target
        self.secretVariable = secretVariable
        self.scope = scope
        self.readOnly = readOnly
    }

    /// Whether the password this connector needs is actually in the
    /// environment. Answered before connecting, so "check your environment" is
    /// not something the user learns from a driver error.
    public var secretIsAvailable: Bool {
        guard let secretVariable else { return true }
        return !(ProcessInfo.processInfo.environment[secretVariable] ?? "").isEmpty
    }
}

/// What §12.2 asks for and what is actually reachable from here.
///
/// The two missing kinds are named rather than omitted: a picker with four
/// entries and two silent failures is worse than one that says why.
public enum UnsupportedConnector: String, Sendable, CaseIterable, Identifiable {
    case sqlServer
    case mongoDB

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sqlServer: "SQL Server"
        case .mongoDB: "MongoDB"
        }
    }

    public var reason: String {
        switch self {
        case .sqlServer:
            "DuckDB ยังไม่มี extension ทางการสำหรับ SQL Server — §12.2 วางไว้ว่าจะไปทาง ATTACH "
                + "เมื่อมี ตอนนี้ยังต่อไม่ได้จริง"
        case .mongoDB:
            "ต้องใช้ไดรเวอร์ native (v1 พิสูจน์แล้วว่า community extension \"mongo\" "
                + "build ตาม core ไม่ทัน) — ยังไม่ได้เพิ่มเป็น dependency"
        }
    }
}

public enum ConnectorError: Error, CustomStringConvertible, Equatable {
    case secretMissing(variable: String)
    case connectFailed(alias: String, message: String)

    public var description: String {
        switch self {
        case .secretMissing(let variable):
            "ยังไม่ได้ตั้งตัวแปรสภาพแวดล้อม \(variable) ที่เก็บรหัสผ่านของแหล่งนี้"
        case .connectFailed(let alias, let message):
            "ต่อ '\(alias)' ไม่สำเร็จ: \(message)"
        }
    }
}

extension AnalysisStore {

    /// Attaches a saved connector, reading its password from the environment at
    /// the moment of connecting.
    ///
    /// The password is interpolated into the connection string DuckDB needs and
    /// then scrubbed out of anything that comes back — an ATTACH that fails
    /// would otherwise report the whole statement, credential included, into a
    /// log and a span.
    @discardableResult
    public func attach(_ connector: DBConnector) async throws -> AttachedDatabase {
        var secret: String?
        if let variable = connector.secretVariable {
            let value = ProcessInfo.processInfo.environment[variable] ?? ""
            guard !value.isEmpty else { throw ConnectorError.secretMissing(variable: variable) }
            secret = value
        }
        let target = Self.connectionString(for: connector, secret: secret)
        // `query` scrubs this out of anything it logs or throws while it is
        // set — DuckDB quotes the failing statement back, and the statement is
        // the connection string.
        secretInFlight = secret
        defer { secretInFlight = nil }
        do {
            return try await attach(target, as: connector.alias, kind: connector.kind,
                                    readOnly: connector.readOnly)
        } catch {
            throw ConnectorError.connectFailed(
                alias: connector.alias,
                message: Self.redact("\(error)", secret: secret))
        }
    }

    /// The string handed to `ATTACH`. SQLite takes a path; the server kinds
    /// take libpq-style key/value pairs, which is also what DuckDB's MySQL
    /// scanner accepts.
    static func connectionString(for connector: DBConnector, secret: String?) -> String {
        guard let secret, connector.kind != .sqlite else { return connector.target }
        let separator = connector.target.hasSuffix(" ") ? "" : " "
        return connector.target + separator + "password=\(secret)"
    }

    /// Removes a secret from text that is about to be shown or logged.
    static func redact(_ text: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "••••")
    }
}

// ─────────────────────────────────────────────────────────────
// Where connectors are kept.
//
// A JSON file beside the notebooks rather than a row in SurrealDB: this has to
// be readable before anything is connected to anything, and a person should be
// able to look at the file and see that their password is not in it.
// ─────────────────────────────────────────────────────────────

public struct ConnectorStore: Sendable {
    public let file: URL
    private let log = AppLog.logger("connectors")

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [DBConnector] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let connectors = try? JSONDecoder().decode([DBConnector].self, from: data) else {
            log.error("connector file unreadable — starting from an empty list")
            return []
        }
        return connectors
    }

    public func load(scope: Scope) -> [DBConnector] {
        load().filter { $0.scope == scope || $0.scope == .central }
    }

    public func save(_ connectors: [DBConnector]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(connectors).write(to: file, options: .atomic)
    }

    @discardableResult
    public func add(_ connector: DBConnector) throws -> [DBConnector] {
        var all = load()
        if let index = all.firstIndex(where: { $0.id == connector.id }) {
            all[index] = connector
        } else {
            all.append(connector)
        }
        try save(all)
        return all
    }

    @discardableResult
    public func remove(_ id: String) throws -> [DBConnector] {
        let all = load().filter { $0.id != id }
        try save(all)
        return all
    }
}
