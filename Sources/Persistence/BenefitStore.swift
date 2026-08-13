import Foundation
import AgentKit
import ProjectKit

// ─────────────────────────────────────────────────────────────
// Benefits, tailoring records, and the two facts the closing gate borrows from
// other stores (ARCHITECTURE §19.12–§19.16, P10.10/P10.13).
//
// Same arrangement as `RegisterStore`: the columns a query needs as primitives,
// the value itself as a blob. `measured` is a column rather than a field of the
// blob because "which benefits does somebody still owe a number for" is the one
// question asked across projects — at closing, and again three months later.
// ─────────────────────────────────────────────────────────────

public actor BenefitStore: BenefitPersisting {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    public func save(_ benefit: Benefit) async throws {
        let json = String(decoding: try Coding.encoder.encode(benefit), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", benefit.id)
        content.setString("project_id", benefit.projectID.rawValue)
        content.set("measured", benefit.isMeasured)
        content.setString("benefit", json)
        content.raw("updated_at", "time::now()")

        try await client.exec(
            "UPSERT benefit CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: ProjectID) async throws -> [Benefit] {
        try await client.query(
            "SELECT * FROM benefit WHERE project_id = type::string($pid) ORDER BY updated_at DESC",
            vars: ["pid": project.rawValue])
            .first?.rows.compactMap { row in
                guard let json = row["benefit"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(Benefit.self, from: Data(json.utf8))
            } ?? []
    }

    public func delete(_ id: String, project: ProjectID) async throws {
        try await client.exec("""
            DELETE benefit WHERE uid = type::string($uid)
              AND project_id = type::string($pid)
            """, vars: ["uid": id, "pid": project.rawValue])
    }
}

/// Tailoring records. No update and no delete: a governance decision that can be
/// edited away afterwards is not a record of anything (§19.15).
public actor TailoringStore: TailoringPersisting {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    public func save(_ record: TailoringRecord) async throws {
        let json = String(decoding: try Coding.encoder.encode(record), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", record.id)
        content.setString("project_id", record.projectID.rawValue)
        content.setString("practice", record.practice.rawValue)
        content.setString("record", json)
        content.raw("decided_at", "time::now()")

        try await client.exec(
            "UPSERT tailoring_record CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func all(project: ProjectID) async throws -> [TailoringRecord] {
        try await client.query("""
            SELECT * FROM tailoring_record WHERE project_id = type::string($pid)
            ORDER BY decided_at DESC
            """, vars: ["pid": project.rawValue])
            .first?.rows.compactMap { row in
                guard let json = row["record"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(TailoringRecord.self, from: Data(json.utf8))
            } ?? []
    }
}

/// The two questions G4 asks of stores that predate it (§19.12 conditions 4–5).
///
/// An adapter rather than a conformance bolted onto `ConflictStore` and
/// `AnalysisPlanStore`: neither of those has any business knowing that a project
/// lifecycle exists, and the gate needs both answers or neither.
///
/// Both methods swallow their errors into "nothing found", which would normally
/// be the wrong call — but the gate treats a `nil` count as unchecked and a `0`
/// as clear, so a store that throws must not be able to report zero. That is why
/// the failure is logged and re-thrown as an absent adapter instead: the
/// optional lives at the `ProjectService` boundary, not here.
public struct ClosingLedger: ClosingLedgerReading {
    private let conflicts: ConflictStore
    private let plans: AnalysisPlanStore

    public init(conflicts: ConflictStore, plans: AnalysisPlanStore) {
        self.conflicts = conflicts
        self.plans = plans
    }

    public func openConflictCount(scope: Scope) async -> Int {
        ((try? await conflicts.open(scope: scope)) ?? []).count
    }

    /// Decisions still marked `agent_suggested` across the project's analysis
    /// plans. An approved plan has none by construction (§12.4), so this counts
    /// exactly the assumptions an agent made that nobody has confirmed.
    public func unconfirmedAssumptionCount(scope: Scope) async -> Int {
        let stored = (try? await plans.load(scope: scope)) ?? []
        return stored.reduce(0) { $0 + $1.plan.agentSuggestions.count }
    }
}
