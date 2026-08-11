import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// The conflict ledger, made durable (ARCHITECTURE §11.6, P3.6).
//
// §11.6's promise is that a decision is made once. A ledger that lives in
// memory breaks exactly that promise on the next launch — the user is asked
// again about a disagreement they already settled, which is worse than never
// having asked, because it says the answer went nowhere.
//
// Both passages are stored verbatim rather than by reference to their chunks.
// A conflict outlives the documents that caused it: one of them can be deleted
// or superseded, and the card still has to show what was actually said.
// ─────────────────────────────────────────────────────────────

public actor ConflictStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    public func save(_ conflict: Conflict, scope: Scope) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var content = ContentBuilder()
        content.setString("uid", conflict.id)
        content.setString("question", conflict.question)
        content.setString("scope_kind", ScopeColumns.kind(scope))
        content.setString("project_id", ScopeColumns.projectID(scope))
        content.set("decided", conflict.decision != nil)
        content.setString("side_a", String(decoding: try encoder.encode(conflict.a), as: UTF8.self))
        content.setString("side_b", String(decoding: try encoder.encode(conflict.b), as: UTF8.self))
        content.setString("weight_a", conflict.weightA.reasons.joined(separator: " · "))
        content.setString("weight_b", conflict.weightB.reasons.joined(separator: " · "))
        content.set("score_a", conflict.weightA.score)
        content.set("score_b", conflict.weightB.score)
        content.set("needs_human", conflict.needsHuman)
        content.setString("proposal",
                          String(decoding: try encoder.encode(conflict.proposal), as: UTF8.self))
        if let decision = conflict.decision {
            content.setString("decision",
                              String(decoding: try encoder.encode(decision), as: UTF8.self))
        }
        content.raw("created_at", "time::now()")

        try await client.exec("UPSERT conflict CONTENT \(content.content) WHERE uid = $uid",
                              vars: content.vars)
    }

    /// Everything filed for a scope, decided and open alike. The decided ones
    /// are what stop the same question being asked twice; the open ones are
    /// the cards still waiting.
    public func load(scope: Scope) async throws -> [StoredConflict] {
        var vars: [String: Any] = ["kind": ScopeColumns.kind(scope)]
        var sql = "SELECT * FROM conflict WHERE scope_kind = $kind"
        if let projectID = ScopeColumns.projectID(scope) {
            sql += " AND project_id = $pid"
            vars["pid"] = projectID
        }
        sql += " ORDER BY created_at DESC"

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try await client.query(sql, vars: vars).first?.rows.compactMap { row in
            guard let id = row["uid"]?.stringValue,
                  let question = row["question"]?.stringValue,
                  let aJSON = row["side_a"]?.stringValue,
                  let bJSON = row["side_b"]?.stringValue,
                  let a = try? decoder.decode(ConflictSide.self, from: Data(aJSON.utf8)),
                  let b = try? decoder.decode(ConflictSide.self, from: Data(bJSON.utf8))
            else { return nil }

            let decision = (row["decision"]?.stringValue)
                .flatMap { try? decoder.decode(ConflictDecision.self, from: Data($0.utf8)) }

            return StoredConflict(
                id: id, question: question, a: a, b: b,
                weightAReasons: row["weight_a"]?.stringValue ?? "",
                weightBReasons: row["weight_b"]?.stringValue ?? "",
                scoreA: row["score_a"]?.doubleValue ?? 0,
                scoreB: row["score_b"]?.doubleValue ?? 0,
                needsHuman: row["needs_human"]?.boolValue ?? false,
                decision: decision)
        } ?? []
    }

    public func open(scope: Scope) async throws -> [StoredConflict] {
        try await load(scope: scope).filter { $0.decision == nil }
    }
}

/// A conflict as it comes back from storage. Deliberately not `Conflict`: the
/// weights are already-rendered reasons rather than a recomputed score, so
/// reopening a card years later shows what was weighed *then* and not what the
/// current rules would say.
public struct StoredConflict: Sendable, Equatable, Identifiable {
    public let id: String
    public let question: String
    public let a: ConflictSide
    public let b: ConflictSide
    public let weightAReasons: String
    public let weightBReasons: String
    public let scoreA: Double
    public let scoreB: Double
    public let needsHuman: Bool
    public let decision: ConflictDecision?

    public var isOpen: Bool { decision == nil }
}
