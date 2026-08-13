import Foundation
import AgentKit
import ProjectKit

// ─────────────────────────────────────────────────────────────
// Registers and baselines on disk (ARCHITECTURE §19.11, P10.7–P10.8).
//
// Same arrangement as `ExceptionStore`: the columns a query needs — which
// project, which kind, still open, which version — plus the entry itself as a
// blob. Adding a sixth register later is a change in ProjectKit and not a
// migration here, because nothing in this file knows what a risk is.
// ─────────────────────────────────────────────────────────────

public actor RegisterStore: RegisterPersisting {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    public func save(_ entry: RegisterEntry) async throws {
        let json = String(decoding: try Coding.encoder.encode(entry), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", entry.id)
        content.setString("project_id", entry.projectID.rawValue)
        content.setString("kind", entry.kind.rawValue)
        content.set("open", entry.status.isOpen)
        content.setString("entry", json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT register CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: ProjectID) async throws -> [RegisterEntry] {
        try await client.query(
            "SELECT * FROM register WHERE project_id = type::string($pid) ORDER BY updated_at DESC",
            vars: ["pid": project.rawValue])
            .first?.rows.compactMap { row in
                guard let json = row["entry"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(RegisterEntry.self, from: Data(json.utf8))
            } ?? []
    }
}

/// A frozen agreement, stored append-only by construction: `version` is unique
/// per project, so a second write of the same version is rejected by the
/// database rather than quietly replacing what was agreed (§19.11).
public actor BaselineStore: BaselinePersisting {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    public func save(_ baseline: Baseline) async throws {
        let json = String(decoding: try Coding.encoder.encode(baseline), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", baseline.id)
        content.setString("project_id", baseline.projectID.rawValue)
        content.set("version", baseline.version)
        content.setString("baseline", json)
        content.raw("frozen_at", "time::now()")

        try await client.exec(
            "UPSERT baseline CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: ProjectID) async throws -> [Baseline] {
        try await client.query(
            "SELECT * FROM baseline WHERE project_id = type::string($pid) ORDER BY version DESC",
            vars: ["pid": project.rawValue])
            .first?.rows.compactMap { row in
                guard let json = row["baseline"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(Baseline.self, from: Data(json.utf8))
            } ?? []
    }
}

/// One encoder and one decoder for the blobs in this file. ISO-8601 on both
/// sides, because a date written by one and read by the other is the classic
/// way a round-trip stops round-tripping.
enum Coding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
