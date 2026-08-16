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

        try await client.exec("UPSERT conflict CONTENT \(content.content) WHERE uid = type::string($uid)",
                              vars: content.vars)
    }

    /// Files a decision against a conflict that is already stored, touching
    /// nothing else on the row.
    ///
    /// Deliberately not `save(_:scope:)` with a decided `Conflict`: rebuilding
    /// one means re-weighing both sides, and the weights on a filed conflict
    /// are the ones the user was reading when they decided. Re-deriving them at
    /// save time replaces the record of that moment with today's arithmetic —
    /// and because weighing is relative to `now`, the same decision would read
    /// differently every year.
    public func recordDecision(_ decision: ConflictDecision, for id: String,
                               note: String = "") async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(decision), as: UTF8.self)

        try await append(decisionJSON: json, note: note, for: id)
        try await client.exec(
            "UPDATE conflict SET decided = true, decision = $decision WHERE uid = type::string($uid)",
            vars: ["uid": id, "decision": json])
    }

    /// Takes a decision back (§11.6, P3.7).
    ///
    /// **Nothing is deleted.** Reopening writes a row saying the card was
    /// reopened and why, and the old decision stays in the history where it
    /// can be read — "we used to say the opposite, and here is when that
    /// changed" is the question a reversible history exists to answer. A
    /// history somebody can edit is not a history; it is the current opinion
    /// with a timestamp on it.
    ///
    /// The reason is required, and that is not politeness: a reversal with no
    /// reason is indistinguishable from a mis-click when somebody meets it in
    /// six months.
    public func reopen(_ id: String, reason: String) async throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConflictHistoryError.reversalNeedsAReason }
        try await append(decisionJSON: nil, note: trimmed, for: id)
        try await client.exec(
            "UPDATE conflict SET decided = false, decision = NONE WHERE uid = type::string($uid)",
            vars: ["uid": id])
    }

    /// Everything ever decided about this conflict, oldest first.
    public func history(of id: String) async throws -> [ConflictDecisionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let rows = try await client.query("""
            SELECT * FROM conflict_decision
            WHERE conflict_uid = type::string($uid) ORDER BY recorded_at ASC
            """, vars: ["uid": id]).first?.rows ?? []

        return rows.map { row in
            ConflictDecisionRecord(
                decision: (row["decision"]?.stringValue)
                    .flatMap { try? decoder.decode(ConflictDecision.self, from: Data($0.utf8)) },
                note: row["note"]?.stringValue ?? "",
                recordedAt: SurrealTime.date(from: row["recorded_at"]?.stringValue) ?? Date.distantPast)
        }
    }

    private func append(decisionJSON: String?, note: String, for id: String) async throws {
        var vars: [String: Any] = ["uid": id, "note": note]
        var fields = "conflict_uid = type::string($uid), note = $note, recorded_at = time::now()"
        if let decisionJSON {
            fields += ", decision = $decision"
            vars["decision"] = decisionJSON
        }
        try await client.exec("CREATE conflict_decision SET \(fields)", vars: vars)
    }

    /// Moves a decided conflict into `central`, so the next project meets the
    /// decision instead of re-litigating the same two sources (§19.1.1, P21.4).
    ///
    /// An update rather than a second row: a precedent that exists twice is a
    /// precedent that can be answered two ways, and the card's identity is the
    /// pair of passages it was raised over — which has not changed.
    public func promoteToCentral(_ id: String) async throws {
        try await client.exec("""
            UPDATE conflict SET scope_kind = $kind, project_id = NONE
            WHERE uid = type::string($uid) AND decided = true
            """,
            vars: ["uid": id, "kind": ScopeColumns.kind(.central)])
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
            // Read back, not just written: §11.6 puts the system's suggestion on
            // the card, and a suggestion the card cannot name is one the user
            // has to reconstruct from two scores.
            let proposal = (row["proposal"]?.stringValue)
                .flatMap { try? decoder.decode(ConflictResolution.self, from: Data($0.utf8)) }

            return StoredConflict(
                id: id, question: question, a: a, b: b,
                weightAReasons: row["weight_a"]?.stringValue ?? "",
                weightBReasons: row["weight_b"]?.stringValue ?? "",
                scoreA: row["score_a"]?.doubleValue ?? 0,
                scoreB: row["score_b"]?.doubleValue ?? 0,
                needsHuman: row["needs_human"]?.boolValue ?? false,
                proposal: proposal,
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
public enum ConflictHistoryError: Error, CustomStringConvertible, Equatable {
    case reversalNeedsAReason

    public var description: String {
        "การกลับคำตัดสินต้องมีเหตุผล — คำตัดสินที่ถูกกลับโดยไม่มีเหตุผล "
            + "แยกไม่ออกจากการกดผิดเมื่อมีคนมาอ่านในอีกหกเดือน"
    }
}

/// One entry in a conflict's history. `decision == nil` is a reopening — the
/// card went back to being an open question, and that is a decision too.
public struct ConflictDecisionRecord: Sendable, Equatable {
    public let decision: ConflictDecision?
    /// Why. Required for a reversal, optional for the first decision (the
    /// resolution already says what was chosen).
    public let note: String
    public let recordedAt: Date

    public var isReopening: Bool { decision == nil }
}

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
    /// What the system would do, as it was proposed when the conflict was
    /// filed. Kept beside the decision rather than folded into it: the card has
    /// to be able to show a suggestion the human then overrode.
    public let proposal: ConflictResolution?
    public let decision: ConflictDecision?

    public var isOpen: Bool { decision == nil }
}
