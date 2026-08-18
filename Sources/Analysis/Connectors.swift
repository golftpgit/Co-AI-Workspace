import Foundation
import os
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
//  • **The secret is never stored.** A connector keeps the *name* the password
//    is filed under, the same shape §9.3's endpoint registry settled on (P5.5).
//    What is written to disk cannot log anybody in. Since P9.3 the value behind
//    that name lives in the Keychain rather than in the environment, which is
//    what §15 always said and what the code never did.
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
    /// The name the password is filed under, read at connect time. Nil for
    /// SQLite and for servers that do not want one.
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

    /// Whether the password this connector needs can actually be had.
    /// Answered before connecting, so that is not something the user learns
    /// from a driver error. Note that a Keychain which will not open answers
    /// `false` here — `attach` is where the two are told apart, because that
    /// is where there is somewhere to put the explanation (P9.3).
    public var secretIsAvailable: Bool {
        guard let secretVariable else { return true }
        return SecretStore.has(secretVariable)
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
            localised("DuckDB has no official SQL Server extension yet — §12.2 plans to go via ATTACH ", "Why SQL Server cannot be connected to.")
                + localised("once one exists; for now the connection genuinely cannot be made", "Ends the explanation of why SQL Server cannot be connected to.")
        case .mongoDB:
            localised("needs a native driver (v1 showed the community \"mongo\" extension ", "Why MongoDB cannot be connected to.")
                + localised("does not keep up with core builds) — it has not been added as a dependency", "Ends the explanation of why MongoDB cannot be connected to.")
        }
    }
}

public enum ConnectorError: Error, CustomStringConvertible, Equatable {
    case secretMissing(variable: String)
    /// The Keychain would not answer. Separate from `secretMissing` for the
    /// reason `SecretStore` gives: "we could not look" and "it is not there"
    /// send a person to two different places (P9.3).
    case secretUnreadable(variable: String, detail: String)
    case connectFailed(alias: String, message: String)

    public var description: String {
        switch self {
        case .secretMissing(let variable):
            localised("no password has been set for this source (“\(variable)”)", "The credential for a data source is missing. Placeholder: the name it would be stored under.")
        case .secretUnreadable(let variable, let detail):
            localised("could not read the password “\(variable)” from the Keychain (\(detail)) — which does not mean it was never set", "Reading a stored credential failed. Placeholders: the name it is stored under and the underlying reason.")
        case .connectFailed(let alias, let message):
            localised("could not connect to '\(alias)': \(message)", "Connecting to a data source failed. Placeholders: the source's alias and the underlying message.")
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
            switch SecretStore.status(variable) {
            case .present: secret = SecretStore.value(variable)
            case .absent: throw ConnectorError.secretMissing(variable: variable)
            case .unreadable(let detail):
                throw ConnectorError.secretUnreadable(variable: variable, detail: detail)
            }
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
        // P9.2 — both shapes: the envelope this build writes, and the bare
        // array every file written before it is. A newer file is left alone
        // and reported rather than read as though we understood it.
        switch VersionedList.decode(data, as: DBConnector.self) {
        case .list(let connectors, _):
            return connectors
        case .fromNewerBuild(let version):
            FileStoreIncidents.shared.record(.newerSchema(doing: "connector", version: version))
            return []
        case .unreadable:
            reportUnreadable(file, kind: "connector", log: log)
            return []
        }
    }

    public func load(scope: Scope) -> [DBConnector] {
        load().filter { $0.scope == scope || $0.scope == .central }
    }

    public func save(_ connectors: [DBConnector]) throws {
        // P9.2 — a file from a newer build is not written over. Running on
        // defaults for one session is recoverable; overwriting is not, and the
        // build somebody would go back to is the one that lost their settings.
        guard VersionedList.mayOverwrite(file, of: DBConnector.self) else {
            throw FileStoreError.fileFromNewerBuild
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try VersionedList.encode(connectors).write(to: file, options: .atomic)
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

/// A list file that will not decode. The copy is taken here, before anything
/// can save over it, and the report is kept where a screen can show it — a
/// corrupt file that only ever reached the unified log is a list that went
/// empty one morning with no explanation (P9.4).
private func reportUnreadable(_ file: URL, kind: String, log: Logger) {
    let failure = FileStoreSafety.reportUnreadable(file, describedAs: kind)
    log.error("\(failure.summary, privacy: .public)")
}
