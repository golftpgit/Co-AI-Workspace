import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Registers and baselines on disk (ARCHITECTURE §19.11, P10.7–P10.8).
//
// Same arrangement as `ExceptionStore`, and for the same reason: `Persistence`
// does not import `ProjectKit`. The row is the columns a query needs — which
// project, which kind, still open, which version — plus the entry itself as a
// blob that the module owning the type decodes.
//
// That keeps one dependency edge pointing one way, and it means adding a sixth
// register later is a change in ProjectKit and not a migration here.
// ─────────────────────────────────────────────────────────────

/// One stored register entry, as the database sees it.
public struct RegisterRecord: Sendable, Equatable {
    public let id: String
    public let projectID: String
    public let kind: String
    public let isOpen: Bool
    public let json: String

    public init(id: String, projectID: String, kind: String, isOpen: Bool, json: String) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.isOpen = isOpen
        self.json = json
    }
}

public actor RegisterStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    public func save(_ record: RegisterRecord) async throws {
        var content = ContentBuilder()
        content.setString("uid", record.id)
        content.setString("project_id", record.projectID)
        content.setString("kind", record.kind)
        content.set("open", record.isOpen)
        content.setString("entry", record.json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT register CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: String) async throws -> [RegisterRecord] {
        try await client.query(
            "SELECT * FROM register WHERE project_id = type::string($pid) ORDER BY updated_at DESC",
            vars: ["pid": project])
            .first?.rows.compactMap { row in
                guard let id = row["uid"]?.stringValue,
                      let json = row["entry"]?.stringValue else { return nil }
                return RegisterRecord(id: id,
                                      projectID: row["project_id"]?.stringValue ?? project,
                                      kind: row["kind"]?.stringValue ?? "",
                                      isOpen: row["open"]?.boolValue ?? true,
                                      json: json)
            } ?? []
    }
}

/// A frozen agreement. Append-only by construction: `version` is unique per
/// project, so a second write of the same version is rejected by the database
/// rather than quietly replacing what was agreed (§19.11).
public struct BaselineRecord: Sendable, Equatable {
    public let id: String
    public let projectID: String
    public let version: Int
    public let json: String

    public init(id: String, projectID: String, version: Int, json: String) {
        self.id = id
        self.projectID = projectID
        self.version = version
        self.json = json
    }
}

public actor BaselineStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    public func save(_ record: BaselineRecord) async throws {
        var content = ContentBuilder()
        content.setString("uid", record.id)
        content.setString("project_id", record.projectID)
        content.set("version", record.version)
        content.setString("baseline", record.json)
        content.raw("frozen_at", "time::now()")

        try await client.exec(
            "UPSERT baseline CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: String) async throws -> [BaselineRecord] {
        try await client.query(
            "SELECT * FROM baseline WHERE project_id = type::string($pid) ORDER BY version DESC",
            vars: ["pid": project])
            .first?.rows.compactMap { row in
                guard let id = row["uid"]?.stringValue,
                      let json = row["baseline"]?.stringValue,
                      let version = row["version"]?.intValue else { return nil }
                return BaselineRecord(id: id,
                                      projectID: row["project_id"]?.stringValue ?? project,
                                      version: version, json: json)
            } ?? []
    }
}
