import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Projects, made durable (ARCHITECTURE §19.1, P10.1).
//
// The row carries the queryable facts as primitive columns — id, name, stage,
// closed — and the scope statement as JSON, for the same reason
// `AnalysisPlanStore` does it: the five lists are only ever read and written as
// a block, and a row per bullet would invite exactly the piecemeal editing that
// change control is supposed to catch (§19.11).
// ─────────────────────────────────────────────────────────────

public actor ProjectStore: ProjectPersisting {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func save(_ project: Project) async throws {
        let json = String(decoding: try Self.encoder.encode(project), as: UTF8.self)

        var content = ContentBuilder()
        content.setString("uid", project.id.rawValue)
        content.setString("name", project.name)
        content.setString("kind", project.kind.rawValue)
        content.setString("stage", project.stage.rawValue)
        content.set("open", project.isOpen)
        content.setString("project", json)
        content.raw("updated_at", "time::now()")

        // `type::string($uid)` on the comparison as well as in the content: a
        // bound string is re-typed by shape in SurrealDB v3, so an id that
        // happens to look like something else stops matching its own column
        // (ARCHITECTURE App. C.0).
        try await client.exec(
            "UPSERT project CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    /// Newest first. Closed projects come back too — they are the audit trail,
    /// and hiding them at the store level would mean two ways to ask.
    public func all() async throws -> [Project] {
        try await client.query("SELECT * FROM project ORDER BY updated_at DESC")
            .first?.rows.compactMap(Self.decode) ?? []
    }

    public func project(_ id: ProjectID) async throws -> Project? {
        try await client.query("SELECT * FROM project WHERE uid = type::string($uid) LIMIT 1",
                               vars: ["uid": id.rawValue])
            .first?.rows.compactMap(Self.decode).first
    }

    public func delete(_ id: ProjectID) async throws {
        try await client.exec("DELETE project WHERE uid = type::string($uid)",
                              vars: ["uid": id.rawValue])
    }

    private static func decode(_ row: [String: SurrealValue]) -> Project? {
        guard let json = row["project"]?.stringValue,
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(Project.self, from: data)
    }
}
