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
