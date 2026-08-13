import Foundation

// ─────────────────────────────────────────────────────────────
// Schema bootstrap. Every statement is `IF NOT EXISTS` because SurrealDB
// v3.2 errors on redefinition — without this the app works on first launch
// and fails on the second (ARCHITECTURE App. C.0).
// ─────────────────────────────────────────────────────────────

public enum Schema {
    public static let namespace = "coai"
    public static let database = "workspace"

    /// Bumped whenever statements are added; recorded in `schema_meta` so a
    /// future migration can tell what the database was created with.
    /// 2: `task` gained `needs_human`, so an escalation can be told apart from
    /// an interrupted run — run-until-done resumes the second and never the
    /// first. The criteria and deliverable type it needs to rebuild an
    /// assignment ride along on the schemaless part of the row.
    /// 8: `conversation` can be pinned (§19.2.1, P10.14).
    /// 7: `span` carries `work_package` (§19.6, P10.15) — the link that turns
    /// "how long did this take" into "how long did *this promise* take", and
    /// with it four of the six tolerances from enforced-but-unread into read.
    /// 6: `register` and `baseline` exist (§19.11, P10.7–P10.8). The baseline's
    /// version is unique per project, so an agreement is superseded rather than
    /// rewritten — the database refuses the second write of a version.
    /// 5: `exception` exists (§19.10, P10.6). An open one stops the project,
    /// and a stop that does not survive a restart is a pause.
    /// 4: `work_package` exists and `task` points at one (§19.6, P10.4) — the
    /// plan and the record of doing it are finally two ends of one link.
    /// 3: `project` exists (§19.1, P10.1). Every other table already carried
    /// `project_id`; there was simply nothing on the other end of it, so two
    /// projects were indistinguishable and the app wrote the literal id
    /// "default" into all of them.
    public static let version = 8

    /// Split into statements that are executed one at a time: a single
    /// failing statement should name itself, not abort a 40-line blob.
    public static let statements: [String] = [
        // ── conversations (P1.3) ──
        "DEFINE TABLE IF NOT EXISTS conversation SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON conversation TYPE string",
        "DEFINE INDEX IF NOT EXISTS conversation_uid ON conversation FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS title ON conversation TYPE option<string>",
        "DEFINE FIELD IF NOT EXISTS scope_kind ON conversation TYPE string",
        "DEFINE FIELD IF NOT EXISTS project_id ON conversation TYPE option<string>",
        "DEFINE FIELD IF NOT EXISTS created_at ON conversation TYPE datetime",
        "DEFINE FIELD IF NOT EXISTS updated_at ON conversation TYPE datetime",
        "DEFINE INDEX IF NOT EXISTS conversation_updated ON conversation FIELDS updated_at",
        "DEFINE FIELD IF NOT EXISTS pinned ON conversation TYPE bool DEFAULT false",

        "DEFINE TABLE IF NOT EXISTS message SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON message TYPE string",
        "DEFINE FIELD IF NOT EXISTS conversation_id ON message TYPE string",
        "DEFINE FIELD IF NOT EXISTS role ON message TYPE string",
        "DEFINE FIELD IF NOT EXISTS content ON message TYPE string",
        "DEFINE FIELD IF NOT EXISTS created_at ON message TYPE datetime",
        "DEFINE INDEX IF NOT EXISTS message_conversation ON message FIELDS conversation_id, created_at",

        // ── spans (P1.6) — one stream for Live Monitor, processes and audit ──
        "DEFINE TABLE IF NOT EXISTS span SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON span TYPE string",
        "DEFINE FIELD IF NOT EXISTS name ON span TYPE string",
        "DEFINE FIELD IF NOT EXISTS status ON span TYPE string",
        "DEFINE FIELD IF NOT EXISTS started_at ON span TYPE datetime",
        "DEFINE INDEX IF NOT EXISTS span_started ON span FIELDS started_at",
        "DEFINE INDEX IF NOT EXISTS span_parent ON span FIELDS parent",
        "DEFINE FIELD IF NOT EXISTS scope_kind ON span TYPE option<string>",
        "DEFINE FIELD IF NOT EXISTS project_id ON span TYPE option<string>",
        "DEFINE FIELD IF NOT EXISTS work_package ON span TYPE option<string>",
        "DEFINE INDEX IF NOT EXISTS span_work_package ON span FIELDS work_package",

        // ── schema metadata ──
        // Knowledge base (P2.7). Text and provenance are the source of truth;
        // the vector is derived and can be rebuilt from them, which is why a
        // model change is a re-embed rather than a migration (P2.8).
        "DEFINE TABLE IF NOT EXISTS chunk SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON chunk TYPE string",
        "DEFINE INDEX IF NOT EXISTS chunk_uid ON chunk FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS document_id ON chunk TYPE string",
        "DEFINE INDEX IF NOT EXISTS chunk_document ON chunk FIELDS document_id",
        "DEFINE FIELD IF NOT EXISTS content_hash ON chunk TYPE string",
        // Re-ingesting the same passage must not add a second row, and the
        // database is the last place that can still enforce it.
        "DEFINE INDEX IF NOT EXISTS chunk_hash ON chunk FIELDS content_hash UNIQUE",
        "DEFINE FIELD IF NOT EXISTS scope_kind ON chunk TYPE string",
        "DEFINE FIELD IF NOT EXISTS project_id ON chunk TYPE option<string>",
        "DEFINE INDEX IF NOT EXISTS chunk_scope ON chunk FIELDS scope_kind, project_id",
        "DEFINE FIELD IF NOT EXISTS embedding_profile ON chunk TYPE option<string>",
        "DEFINE FIELD IF NOT EXISTS created_at ON chunk TYPE datetime",

        // Conflict ledger (P3.6). A decision that does not survive a restart
        // is a question the user gets asked again, which is the one thing
        // §11.6 promises will not happen.
        // Knowledge graph edges (§11.4). Each one names the chunk that
        // supports it, so a relation can always be checked against the text.
        // Task ledger (§2.2). Who was asked to do what, how many tries it
        // took, and what the reviewer said — answerable without replaying a
        // session.
        "DEFINE TABLE IF NOT EXISTS task SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON task TYPE string",
        "DEFINE INDEX IF NOT EXISTS task_uid ON task FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS role ON task TYPE string",
        "DEFINE FIELD IF NOT EXISTS passed ON task TYPE bool",
        "DEFINE FIELD IF NOT EXISTS attempts ON task TYPE int",
        "DEFINE FIELD IF NOT EXISTS scope_kind ON task TYPE string",
        "DEFINE FIELD IF NOT EXISTS project_id ON task TYPE option<string>",
        "DEFINE INDEX IF NOT EXISTS task_open ON task FIELDS passed",
        "DEFINE FIELD IF NOT EXISTS needs_human ON task TYPE bool",
        // §19.6 — which leaf of the plan this round of work was against. The
        // ledger already answered "what happened"; this makes it answer
        // "against which promise".
        "DEFINE FIELD IF NOT EXISTS work_package ON task TYPE option<string>",
        "DEFINE INDEX IF NOT EXISTS task_work_package ON task FIELDS work_package",
        "DEFINE FIELD IF NOT EXISTS updated_at ON task TYPE datetime",

        "DEFINE TABLE IF NOT EXISTS relation SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON relation TYPE string",
        "DEFINE INDEX IF NOT EXISTS relation_uid ON relation FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS chunk_id ON relation TYPE string",
        "DEFINE INDEX IF NOT EXISTS relation_chunk ON relation FIELDS chunk_id",
        "DEFINE FIELD IF NOT EXISTS document_id ON relation TYPE string",
        "DEFINE FIELD IF NOT EXISTS scope_kind ON relation TYPE string",
        "DEFINE FIELD IF NOT EXISTS project_id ON relation TYPE option<string>",
        "DEFINE FIELD IF NOT EXISTS created_at ON relation TYPE datetime",

        "DEFINE TABLE IF NOT EXISTS conflict SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON conflict TYPE string",
        "DEFINE INDEX IF NOT EXISTS conflict_uid ON conflict FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS question ON conflict TYPE string",
        "DEFINE FIELD IF NOT EXISTS scope_kind ON conflict TYPE string",
        "DEFINE FIELD IF NOT EXISTS project_id ON conflict TYPE option<string>",
        "DEFINE FIELD IF NOT EXISTS decided ON conflict TYPE bool",
        "DEFINE INDEX IF NOT EXISTS conflict_open ON conflict FIELDS decided",
        "DEFINE FIELD IF NOT EXISTS created_at ON conflict TYPE datetime",

        // §12.4 — the pre-registration. The counts are denormalised so "which
        // plans are still waiting for me" is a query rather than a decode of
        // every row.
        "DEFINE TABLE IF NOT EXISTS analysis_plan SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON analysis_plan TYPE string",
        "DEFINE INDEX IF NOT EXISTS analysis_plan_uid ON analysis_plan FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS title ON analysis_plan TYPE string",
        "DEFINE FIELD IF NOT EXISTS scope_kind ON analysis_plan TYPE string",
        "DEFINE FIELD IF NOT EXISTS project_id ON analysis_plan TYPE option<string>",
        "DEFINE FIELD IF NOT EXISTS approved ON analysis_plan TYPE bool",
        "DEFINE INDEX IF NOT EXISTS analysis_plan_approved ON analysis_plan FIELDS approved",
        "DEFINE FIELD IF NOT EXISTS updated_at ON analysis_plan TYPE datetime",

        // ── projects (§19.1, P10.1) ──
        // The row that everything else's `project_id` finally points at.
        // `open` is denormalised so the sidebar can list what is live without
        // decoding every stored project.
        "DEFINE TABLE IF NOT EXISTS project SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON project TYPE string",
        "DEFINE INDEX IF NOT EXISTS project_uid ON project FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS name ON project TYPE string",
        "DEFINE FIELD IF NOT EXISTS kind ON project TYPE string",
        "DEFINE FIELD IF NOT EXISTS stage ON project TYPE string",
        "DEFINE FIELD IF NOT EXISTS open ON project TYPE bool",
        "DEFINE INDEX IF NOT EXISTS project_open ON project FIELDS open",
        "DEFINE FIELD IF NOT EXISTS updated_at ON project TYPE datetime",

        // ── work breakdown (§19.6, P10.4) ──
        // Flat with parent pointers: the tree is derived, because a plan being
        // edited is a list and only a list can be indexed.
        "DEFINE TABLE IF NOT EXISTS work_package SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON work_package TYPE string",
        "DEFINE INDEX IF NOT EXISTS work_package_uid ON work_package FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS project_id ON work_package TYPE string",
        "DEFINE INDEX IF NOT EXISTS work_package_project ON work_package FIELDS project_id",
        "DEFINE FIELD IF NOT EXISTS parent ON work_package TYPE option<string>",
        "DEFINE FIELD IF NOT EXISTS title ON work_package TYPE string",
        "DEFINE FIELD IF NOT EXISTS status ON work_package TYPE string",
        "DEFINE FIELD IF NOT EXISTS updated_at ON work_package TYPE datetime",

        // ── exceptions (§19.10, P10.6) ──
        "DEFINE TABLE IF NOT EXISTS exception SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON exception TYPE string",
        "DEFINE INDEX IF NOT EXISTS exception_uid ON exception FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS project_id ON exception TYPE string",
        "DEFINE FIELD IF NOT EXISTS dimension ON exception TYPE string",
        "DEFINE FIELD IF NOT EXISTS open ON exception TYPE bool",
        "DEFINE INDEX IF NOT EXISTS exception_open ON exception FIELDS project_id, open",
        "DEFINE FIELD IF NOT EXISTS updated_at ON exception TYPE datetime",

        // ── registers and baselines (§19.11, P10.7–P10.8) ──
        "DEFINE TABLE IF NOT EXISTS register SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON register TYPE string",
        "DEFINE INDEX IF NOT EXISTS register_uid ON register FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS project_id ON register TYPE string",
        "DEFINE FIELD IF NOT EXISTS kind ON register TYPE string",
        "DEFINE FIELD IF NOT EXISTS open ON register TYPE bool",
        "DEFINE INDEX IF NOT EXISTS register_project ON register FIELDS project_id, kind",
        "DEFINE FIELD IF NOT EXISTS updated_at ON register TYPE datetime",

        "DEFINE TABLE IF NOT EXISTS baseline SCHEMALESS",
        "DEFINE FIELD IF NOT EXISTS uid ON baseline TYPE string",
        "DEFINE INDEX IF NOT EXISTS baseline_uid ON baseline FIELDS uid UNIQUE",
        "DEFINE FIELD IF NOT EXISTS project_id ON baseline TYPE string",
        "DEFINE FIELD IF NOT EXISTS version ON baseline TYPE int",
        // What makes an agreement immutable: the same version cannot be
        // written twice, so superseding is the only way to change one.
        "DEFINE INDEX IF NOT EXISTS baseline_version ON baseline FIELDS project_id, version UNIQUE",
        "DEFINE FIELD IF NOT EXISTS frozen_at ON baseline TYPE datetime",

        "DEFINE TABLE IF NOT EXISTS schema_meta SCHEMALESS",
    ]
}

extension SurrealClient {
    /// Connects, authenticates, selects the namespace and applies the schema.
    /// Safe to run on every launch.
    public func bootstrap(user: String, password: String) async throws {
        try await signin(user: user, pass: password)
        try await use(namespace: Schema.namespace, database: Schema.database)
        for statement in Schema.statements {
            do {
                try await exec(statement)
            } catch {
                throw SurrealError.server(code: -1, message: "schema statement failed: \(statement) — \(error)")
            }
        }
        // UPSERT, not UPDATE: v3 refuses to UPDATE a record that does not exist.
        try await exec("""
        UPSERT schema_meta:current CONTENT { version: $version, applied_at: time::now() }
        """, vars: ["version": Schema.version])
    }

    /// Version recorded in the database, or nil when it has never been applied.
    public func schemaVersion() async throws -> Int? {
        let results = try await query("SELECT version FROM schema_meta:current")
        return results.first?.rows.first?["version"]?.intValue
    }
}
