import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The task ledger, made durable (ARCHITECTURE §2.2, P4.2).
//
// §2.2 wants "who is doing what, and how did it go" answerable at any time. In
// memory it is answerable until the app closes, which is the moment a person
// most often wants to ask — after leaving a long run unattended.
//
// The reviewer's findings are stored with the row. A task that failed three
// times and escalated is only useful if the reasons came with it; "escalated"
// on its own is what made v1's loops unreadable.
// ─────────────────────────────────────────────────────────────

public struct LedgerRow: Sendable, Equatable, Identifiable {
    public let assignmentID: String
    public let role: Role
    public let goal: String
    public let attempts: Int
    public let passed: Bool
    public let findings: [String]
    public let summary: String?

    public var id: String { assignmentID }

    public init(assignmentID: String, role: Role, goal: String, attempts: Int,
                passed: Bool, findings: [String], summary: String?) {
        self.assignmentID = assignmentID
        self.role = role
        self.goal = goal
        self.attempts = attempts
        self.passed = passed
        self.findings = findings
        self.summary = summary
    }
}

public actor TaskLedgerStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    /// Upserted on every state change rather than written once at the end: a
    /// run that is interrupted is exactly when the ledger has to be readable.
    public func record(_ row: LedgerRow, scope: Scope) async throws {
        var content = ContentBuilder()
        content.setString("uid", row.assignmentID)
        content.setString("role", row.role.rawValue)
        content.setString("goal", row.goal)
        content.set("attempts", row.attempts)
        content.set("passed", row.passed)
        content.set("findings", row.findings)
        content.setString("summary", row.summary)
        content.setString("scope_kind", ScopeColumns.kind(scope))
        content.setString("project_id", ScopeColumns.projectID(scope))
        content.raw("updated_at", "time::now()")

        try await client.exec("UPSERT task CONTENT \(content.content) WHERE uid = $uid",
                              vars: content.vars)
    }

    public func rows(scope: Scope) async throws -> [LedgerRow] {
        var vars: [String: Any] = ["kind": ScopeColumns.kind(scope)]
        var sql = "SELECT * FROM task WHERE scope_kind = $kind"
        if let projectID = ScopeColumns.projectID(scope) {
            sql += " AND project_id = $pid"
            vars["pid"] = projectID
        }
        sql += " ORDER BY updated_at DESC"

        return try await client.query(sql, vars: vars).first?.rows.compactMap { row in
            guard let id = row["uid"]?.stringValue,
                  let roleName = row["role"]?.stringValue,
                  let role = Role(rawValue: roleName),
                  let goal = row["goal"]?.stringValue else { return nil }
            return LedgerRow(
                assignmentID: id, role: role, goal: goal,
                attempts: row["attempts"]?.intValue ?? 0,
                passed: row["passed"]?.boolValue ?? false,
                findings: row["findings"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                summary: row["summary"]?.stringValue)
        } ?? []
    }

    /// What still needs a person. The list a user opens the app to see after
    /// leaving a run going.
    public func unfinished(scope: Scope) async throws -> [LedgerRow] {
        try await rows(scope: scope).filter { !$0.passed }
    }
}
