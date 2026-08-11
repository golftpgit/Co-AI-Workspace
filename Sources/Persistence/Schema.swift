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
    public static let version = 1

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
