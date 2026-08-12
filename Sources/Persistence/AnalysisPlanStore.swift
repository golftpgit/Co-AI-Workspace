import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The Analysis Plan, made durable (ARCHITECTURE §12.4, P6.7).
//
// §12.4 calls the plan a pre-registration: the method is agreed before the
// numbers are seen. A pre-registration that only exists while the window is
// open registers nothing — the whole point is that it is still there,
// unchanged, when the results come back and somebody would rather the method
// had been different.
//
// Stored as one row with the decisions and gaps as JSON. They are read and
// written as a block, they are only ever meaningful as a block (approval is a
// statement about the whole plan), and a row per decision would invite exactly
// the piecemeal editing the type refuses.
// ─────────────────────────────────────────────────────────────

public struct StoredPlan: Sendable, Equatable {
    public let plan: AnalysisPlan
    public let updatedAt: Date
}

public actor AnalysisPlanStore {
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

    public func save(_ plan: AnalysisPlan) async throws {
        let json = String(decoding: try Self.encoder.encode(plan), as: UTF8.self)

        var content = ContentBuilder()
        content.setString("uid", plan.id)
        content.setString("title", plan.title)
        content.setString("scope_kind", ScopeColumns.kind(plan.scope))
        content.setString("project_id", ScopeColumns.projectID(plan.scope))
        // Denormalised so "which plans are still waiting for me" is a query
        // rather than a decode of every row.
        content.set("approved", plan.isApproved)
        content.set("open_gaps", plan.openGaps.count)
        content.set("unconfirmed", plan.agentSuggestions.count)
        content.setString("plan", json)
        content.raw("updated_at", "time::now()")

        // `type::string($uid)` on the comparison as well as the content: a
        // bound string shaped like a UUID is read as a UUID value by SurrealDB
        // v3 and never matches a string column (App. C, U15).
        try await client.exec(
            "UPSERT analysis_plan CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func load(scope: Scope) async throws -> [StoredPlan] {
        var vars: [String: Any] = ["kind": ScopeColumns.kind(scope)]
        var sql = "SELECT * FROM analysis_plan WHERE scope_kind = $kind"
        if let projectID = ScopeColumns.projectID(scope) {
            sql += " AND project_id = $pid"
            vars["pid"] = projectID
        }
        sql += " ORDER BY updated_at DESC"

        return try await client.query(sql, vars: vars).first?.rows.compactMap { row in
            guard let json = row["plan"]?.stringValue,
                  let data = json.data(using: .utf8),
                  let plan = try? Self.decoder.decode(AnalysisPlan.self, from: data) else {
                return nil
            }
            return StoredPlan(plan: plan, updatedAt: Date())
        } ?? []
    }

    public func delete(_ id: String) async throws {
        try await client.exec("DELETE analysis_plan WHERE uid = type::string($uid)",
                              vars: ["uid": id])
    }
}
