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
    /// Set when the lead gave up and asked for a person (§2.5). Distinct from
    /// `!passed`, which also covers work that was simply interrupted — and the
    /// difference decides whether run-until-done may pick it up again. Resuming
    /// an escalation automatically would undo the escalation.
    public let needsHuman: Bool
    /// A person stopped this piece of work (P4.7). Recorded rather than
    /// deleted: "we decided not to do this" is a different fact from "this
    /// never existed", and the difference is what someone reads the ledger
    /// for. Like an escalation, it is never picked up again automatically.
    public let cancelled: Bool
    public let findings: [String]
    public let summary: String?
    /// Stored so an assignment can be rebuilt after the app closes. Without the
    /// criteria there is nothing to review against, and `Assignment` refuses to
    /// exist without them, so a ledger that omits them can be read but never
    /// resumed.
    public let acceptanceCriteria: [Criterion]
    public let deliverableType: String
    /// Which leaf of the WBS this round of work was against (§19.6, P10.4).
    /// `nil` for work that predates the plan or that happened in General,
    /// which is a real state and not a defect: not every turn is a promise.
    public let workPackageID: String?

    public var id: String { assignmentID }

    /// The assignment this row came from, or `nil` when the row predates
    /// criteria being stored and therefore cannot be resumed.
    public var assignment: Assignment? {
        guard !acceptanceCriteria.isEmpty else { return nil }
        return Assignment(id: assignmentID, role: role, goal: goal,
                          acceptanceCriteria: acceptanceCriteria,
                          deliverableType: deliverableType)
    }

    public init(assignmentID: String, role: Role, goal: String, attempts: Int,
                passed: Bool, needsHuman: Bool = false, cancelled: Bool = false,
                findings: [String],
                summary: String?, acceptanceCriteria: [Criterion] = [],
                deliverableType: String = "",
                workPackageID: String? = nil) {
        self.assignmentID = assignmentID
        self.role = role
        self.goal = goal
        self.attempts = attempts
        self.passed = passed
        self.needsHuman = needsHuman
        self.cancelled = cancelled
        self.findings = findings
        self.summary = summary
        self.acceptanceCriteria = acceptanceCriteria
        self.deliverableType = deliverableType
        self.workPackageID = workPackageID
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
        content.set("needs_human", row.needsHuman)
        content.set("cancelled", row.cancelled)
        content.set("findings", row.findings)
        content.setString("summary", row.summary)
        content.setString("deliverable_type", row.deliverableType)
        content.setString("work_package", row.workPackageID)
        // As JSON rather than two parallel arrays: a criterion and the evidence
        // it demands are one thing, and splitting them is how they drift apart.
        if let criteria = try? JSONEncoder().encode(row.acceptanceCriteria) {
            content.setString("criteria", String(decoding: criteria, as: UTF8.self))
        }
        content.setString("scope_kind", ScopeColumns.kind(scope))
        content.setString("project_id", ScopeColumns.projectID(scope))
        content.raw("updated_at", "time::now()")

        try await client.exec("UPSERT task CONTENT \(content.content) WHERE uid = type::string($uid)",
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
            let criteria = (row["criteria"]?.stringValue)
                .flatMap { try? JSONDecoder().decode([Criterion].self, from: Data($0.utf8)) }

            return LedgerRow(
                assignmentID: id, role: role, goal: goal,
                attempts: row["attempts"]?.intValue ?? 0,
                passed: row["passed"]?.boolValue ?? false,
                needsHuman: row["needs_human"]?.boolValue ?? false,
                cancelled: row["cancelled"]?.boolValue ?? false,
                findings: row["findings"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                summary: row["summary"]?.stringValue,
                acceptanceCriteria: criteria ?? [],
                deliverableType: row["deliverable_type"]?.stringValue ?? "",
                workPackageID: row["work_package"]?.stringValue)
        } ?? []
    }

    /// Every round of work recorded against one leaf of the plan, newest
    /// first. This is the link that makes the WBS answerable in both
    /// directions: from the plan, what happened; from the ledger, which
    /// promise it was against (§19.6).
    public func rows(workPackage: String, scope: Scope) async throws -> [LedgerRow] {
        try await rows(scope: scope).filter { $0.workPackageID == workPackage }
    }

    /// Everything that did not pass — the list a user opens the app to see
    /// after leaving a run going, escalations and interruptions alike.
    public func unfinished(scope: Scope) async throws -> [LedgerRow] {
        try await rows(scope: scope).filter { !$0.passed }
    }

    /// The subset a machine may pick up again: unfinished, not escalated, and
    /// carrying the criteria needed to review it.
    ///
    /// Escalated and cancelled work is excluded on purpose. §2.5 ends a run by
    /// asking a person, and an automatic retry is precisely the thing that
    /// decision was made instead of — run-until-done must not quietly overturn
    /// either of them.
    public func resumable(scope: Scope) async throws -> [LedgerRow] {
        try await unfinished(scope: scope)
            .filter { !$0.needsHuman && !$0.cancelled && $0.assignment != nil }
    }
}
