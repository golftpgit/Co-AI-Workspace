import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// The durable span sink (ARCHITECTURE §16, IMPLEMENTATION P1.6).
// Live Monitor, the process list and the audit view are all filters over
// this one table — v1 kept two in-memory sources that drifted apart and
// lost events whenever the user switched views (bug B5).
// ─────────────────────────────────────────────────────────────

public actor SurrealSpanSink: SpanSink {
    private let client: SurrealClient
    /// Spans are written on the hot path of every tool call, so a write must
    /// never take the whole turn down; failures degrade to the console.
    private let fallback = ConsoleSpanSink()

    public init(client: SurrealClient) {
        self.client = client
    }

    public func record(_ span: Span) async {
        var content = ContentBuilder()
        // Optional fields are omitted rather than bound as NULL, and the
        // statement is UPSERT so the first write creates the row (App. C.0).
        content.set("uid", span.id.rawValue)   // see identity note in ConversationStore
        content.set("parent", span.parent?.rawValue)
        content.set("name", span.name)
        content.set("role", span.role?.rawValue)
        content.set("scope_kind", span.scope.map(ScopeColumns.kind))
        content.set("project_id", span.scope.flatMap(ScopeColumns.projectID))
        content.set("status", span.status.rawValue)
        content.set("started_at", SurrealTime.string(from: span.startedAt))
        content.set("ended_at", span.endedAt.map(SurrealTime.string(from:)))
        content.set("prompt_tokens", span.promptTokens)
        content.set("completion_tokens", span.completionTokens)
        content.set("detail", span.detail)

        do {
            try await client.exec(
                "UPSERT type::record('span', $id) CONTENT \(content.content)",
                vars: content.vars(merging: ["id": span.id.rawValue]))
        } catch {
            fallback.record(span)
        }
    }

    // MARK: - reads (the Live Monitor / audit queries)

    /// Most recent spans, newest first. `parent` filters to one run's subtree.
    public func recent(limit: Int = 200) async throws -> [Span] {
        let results = try await client.query(
            "SELECT * FROM span ORDER BY started_at DESC LIMIT $limit",
            vars: ["limit": limit])
        return (results.first?.rows ?? []).compactMap(Self.span(from:))
    }

    public func children(of parent: SpanID) async throws -> [Span] {
        let results = try await client.query(
            "SELECT * FROM span WHERE parent = $parent ORDER BY started_at ASC",
            vars: ["parent": parent.rawValue])
        return (results.first?.rows ?? []).compactMap(Self.span(from:))
    }

    /// Spans still marked running — what the process view shows as live work.
    public func active() async throws -> [Span] {
        let results = try await client.query(
            "SELECT * FROM span WHERE status = 'running' ORDER BY started_at ASC")
        return (results.first?.rows ?? []).compactMap(Self.span(from:))
    }

    private static func date(_ v: SurrealValue?) -> Date? {
        SurrealTime.date(from: v?.stringValue)
    }

    private static func span(from row: [String: SurrealValue]) -> Span? {
        guard let name = row["name"]?.stringValue,
              let statusRaw = row["status"]?.stringValue,
              let status = SpanStatus(rawValue: statusRaw) else { return nil }

        let id = row["uid"]?.stringValue ?? OpaqueID.make(OpaqueID.span)

        return Span(id: SpanID(id),
                    parent: row["parent"]?.stringValue.map(SpanID.init),
                    name: name,
                    role: row["role"]?.stringValue.flatMap(Role.init(rawValue:)),
                    scope: ScopeColumns.scope(kind: row["scope_kind"]?.stringValue,
                                              projectID: row["project_id"]?.stringValue),
                    status: status,
                    startedAt: date(row["started_at"]) ?? Date(),
                    endedAt: date(row["ended_at"]),
                    promptTokens: row["prompt_tokens"]?.intValue,
                    completionTokens: row["completion_tokens"]?.intValue,
                    detail: row["detail"]?.stringValue)
    }
}
