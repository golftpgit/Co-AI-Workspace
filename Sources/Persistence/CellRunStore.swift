import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// What a cell answered, kept (ARCHITECTURE §12.4 · §20.8, P11.9).
//
// A manuscript's numbers are resolved against runs, so the runs have to outlive
// the session that produced them: the analysis happens in March and the chapter
// is written in June.
//
// One row per (notebook, cell), replaced on each run. Keeping every run would
// make "which of these is the number in the manuscript" a question, and the
// answer this design wants is that there is only ever the latest — a figure in
// a draft points at what the cell says *now*, or it does not resolve at all.
// The history that matters is elsewhere: the span the run wrote (§12.2) records
// that it happened, and the source is on the row.
// ─────────────────────────────────────────────────────────────

public actor CellRunStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    public func save(_ run: CellRun, scope: Scope) async throws {
        let json = String(decoding: try Coding.encoder.encode(run), as: UTF8.self)
        var content = ContentBuilder()
        content.setString("uid", run.id)
        content.setString("notebook_id", run.notebookID)
        content.setString("scope", scope.storageKey)
        content.setString("run", json)
        content.raw("ran_at", "time::now()")

        try await client.exec(
            "UPSERT cell_run CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    public func runs(notebook: String) async throws -> [CellRun] {
        try await client.query("""
            SELECT * FROM cell_run WHERE notebook_id = type::string($nid)
            """, vars: ["nid": notebook])
            .first?.rows.compactMap { row in
                guard let json = row["run"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(CellRun.self, from: Data(json.utf8))
            } ?? []
    }

    /// Everything recorded in one workspace — what a manuscript spanning several
    /// notebooks binds against.
    public func runs(scope: Scope) async throws -> [CellRun] {
        try await client.query("""
            SELECT * FROM cell_run WHERE scope = type::string($scope)
            """, vars: ["scope": scope.storageKey])
            .first?.rows.compactMap { row in
                guard let json = row["run"]?.stringValue else { return nil }
                return try? Coding.decoder.decode(CellRun.self, from: Data(json.utf8))
            } ?? []
    }
}
