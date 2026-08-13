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
        content.setString("uid", span.id.rawValue)   // see identity note in ConversationStore
        content.setString("parent", span.parent?.rawValue)
        // Span names and details are `tool:run_shell`, `llm:gx10`, "escalated
        // past on-device:refused" — exactly the shape v3 reads as a record
        // link, so they must be pinned to `string` (App. C.0). Without this
        // every span the gate, the router and the broker emit is dropped.
        content.setString("name", span.name)
        content.setString("role", span.role?.rawValue)
        content.setString("scope_kind", span.scope.map(ScopeColumns.kind))
        content.setString("project_id", span.scope.flatMap(ScopeColumns.projectID))
        content.setString("status", span.status.rawValue)
        content.set("started_at", SurrealTime.string(from: span.startedAt))
        content.set("ended_at", span.endedAt.map(SurrealTime.string(from:)))
        content.set("prompt_tokens", span.promptTokens)
        content.set("completion_tokens", span.completionTokens)
        content.setString("detail", span.detail)
        content.setString("work_package", span.workPackage)

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
            "SELECT * FROM span WHERE parent = type::string($parent) ORDER BY started_at ASC",
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
                    detail: row["detail"]?.stringValue,
                    workPackage: row["work_package"]?.stringValue)
    }

    // MARK: - measurements (§19.7, §19.10, P10.15)

    /// How long has been spent against each leaf of the plan, in seconds.
    ///
    /// Summed rather than wall-clocked from first to last: a package worked on
    /// across three days did not take three days, and the number people act on
    /// has to be the one they would recognise.
    public func elapsedByWorkPackage(project: ProjectID) async throws -> [String: TimeInterval] {
        let rows = try await client.query("""
            SELECT work_package, started_at, ended_at FROM span
            WHERE project_id = type::string($pid) AND work_package != NONE
            """, vars: ["pid": project.rawValue]).first?.rows ?? []

        var totals: [String: TimeInterval] = [:]
        for row in rows {
            guard let package = row["work_package"]?.stringValue,
                  let started = Self.date(row["started_at"]),
                  let ended = Self.date(row["ended_at"]) else { continue }
            totals[package, default: 0] += max(0, ended.timeIntervalSince(started))
        }
        return totals
    }

    /// Durations of finished work of the same shape, for the forecast band.
    /// Deliberately across projects: the whole point of a p90 is that it comes
    /// from more than the project asking for it.
    public func durations(forRole role: Role) async throws -> [TimeInterval] {
        let rows = try await client.query("""
            SELECT started_at, ended_at FROM span
            WHERE role = type::string($role) AND status = 'succeeded' AND ended_at != NONE
            LIMIT 500
            """, vars: ["role": role.rawValue]).first?.rows ?? []

        return rows.compactMap { row in
            guard let started = Self.date(row["started_at"]),
                  let ended = Self.date(row["ended_at"]) else { return nil }
            return max(0, ended.timeIntervalSince(started))
        }
    }
}
