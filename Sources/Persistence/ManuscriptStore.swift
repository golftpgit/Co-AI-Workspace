import Foundation
import AgentKit
import DocGen

// ─────────────────────────────────────────────────────────────
// The five-chapter manuscript, made durable (ARCHITECTURE §20.8, P11.9).
//
// A thesis draft is written over months, and the whole promise of §20.8 is
// about time passing: a number is bound to a cell so that re-running the
// analysis in March changes what the draft says in April. A manuscript that
// only lives while the window is open cannot keep a promise about April.
//
// One row, whole document as JSON, for the same reason `AnalysisPlanStore`
// does it: the manuscript is only meaningful as a whole — the reference in
// chapter 4 and the sentence around it are one thing — and a row per section
// would invite editing the pieces apart from each other.
//
// **Scoped to a project, and no fallback to General.** Somebody else's thesis
// appearing in this project's list is worse than an empty list.
// ─────────────────────────────────────────────────────────────

public struct StoredManuscript: Sendable, Equatable {
    public let manuscript: Manuscript
    public let updatedAt: Date
}

public actor ManuscriptStore {
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
        // Matched to the encoder above. A mismatch here makes every save
        // unreadable on the next launch while looking perfectly fine on the
        // way in — the shape of bug U32-2.
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func save(_ manuscript: Manuscript) async throws {
        let json = String(decoding: try Self.encoder.encode(manuscript), as: UTF8.self)

        var content = ContentBuilder()
        content.setString("uid", manuscript.id)
        content.setString("title", manuscript.title)
        content.setString("scope_kind", ScopeColumns.kind(manuscript.scope))
        content.setString("project_id", ScopeColumns.projectID(manuscript.scope))
        // Denormalised so a list screen can say "12 numbers reported" without
        // decoding every draft in the project.
        content.set("reported_numbers", manuscript.references.count)
        content.setString("manuscript", json)
        content.raw("updated_at", "time::now()")

        // `type::string($uid)` on the comparison as well: a bound string shaped
        // like a UUID is read as a UUID value by SurrealDB v3 and never matches
        // a string column (App. C, U15).
        try await client.exec(
            "UPSERT manuscript CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func load(scope: Scope) async throws -> [StoredManuscript] {
        var vars: [String: Any] = ["kind": ScopeColumns.kind(scope)]
        var sql = "SELECT * FROM manuscript WHERE scope_kind = $kind"
        if let projectID = ScopeColumns.projectID(scope) {
            sql += " AND project_id = $pid"
            vars["pid"] = projectID
        }
        sql += " ORDER BY updated_at DESC"

        return try await client.query(sql, vars: vars).first?.rows.compactMap { row in
            guard let json = row["manuscript"]?.stringValue,
                  let data = json.data(using: .utf8),
                  let manuscript = try? Self.decoder.decode(Manuscript.self, from: data) else {
                return nil
            }
            return StoredManuscript(manuscript: manuscript, updatedAt: Date())
        } ?? []
    }

    public func delete(_ id: String) async throws {
        try await client.exec("DELETE manuscript WHERE uid = type::string($uid)",
                              vars: ["uid": id])
    }
}
