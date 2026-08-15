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
        content.setString("deliverable_kind", span.deliverableKind)

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
                    workPackage: row["work_package"]?.stringValue,
                    deliverableKind: row["deliverable_kind"]?.stringValue)
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

    /// How many times each tool ran for this project, and for how long
    /// (§19.2.3, P10.15).
    ///
    /// The budget popover asks for a split "by role and by tool", and money is
    /// only ever charged per model call — so this is the honest half of the
    /// second question: not what each tool cost, which nothing records, but what
    /// each tool *did*. A popover that split a bill by tool would be inventing
    /// the split.
    public func toolActivity(project: ProjectID) async throws -> [(tool: String, calls: Int,
                                                                  seconds: TimeInterval)] {
        let rows = try await client.query("""
            SELECT name, started_at, ended_at FROM span
            WHERE project_id = type::string($pid) AND string::starts_with(name, 'tool:')
            """, vars: ["pid": project.rawValue]).first?.rows ?? []

        var calls: [String: Int] = [:]
        var seconds: [String: TimeInterval] = [:]
        for row in rows {
            guard let name = row["name"]?.stringValue else { continue }
            let tool = String(name.dropFirst("tool:".count))
            calls[tool, default: 0] += 1
            if let started = Self.date(row["started_at"]), let ended = Self.date(row["ended_at"]) {
                seconds[tool, default: 0] += max(0, ended.timeIntervalSince(started))
            }
        }
        return calls.map { (tool: $0.key, calls: $0.value, seconds: seconds[$0.key] ?? 0) }
            .sorted { $0.calls > $1.calls }
    }

    /// How well each role uses each tool (§21.1 layer 3, P12.8).
    ///
    /// Across projects on purpose, like the forecast band below: proficiency
    /// built from one project's spans is a statement about that project. The
    /// detail line comes back too, because it is the only thing that separates
    /// "the rules stopped this" from "this role got it wrong" — see
    /// `ToolProficiencyReader`.
    public func toolProficiency(limit: Int = 2_000) async throws -> [ToolProficiency] {
        let rows = try await client.query("""
            SELECT name, role, status, detail FROM span
            WHERE string::starts_with(name, 'tool:') AND role != NONE
            ORDER BY started_at DESC LIMIT $limit
            """, vars: ["limit": limit]).first?.rows ?? []

        let attempts = rows.compactMap { row -> ToolProficiencyReader.Attempt? in
            guard let name = row["name"]?.stringValue,
                  let rawRole = row["role"]?.stringValue,
                  let role = Role(rawValue: rawRole),
                  let status = row["status"]?.stringValue else { return nil }
            // A call still running is not yet an outcome. Counting it as a
            // failure would make a busy moment look like a bad one.
            guard status != SpanStatus.running.rawValue,
                  status != SpanStatus.awaitingApproval.rawValue else { return nil }
            return ToolProficiencyReader.Attempt(
                role: role,
                tool: String(name.dropFirst("tool:".count)),
                succeeded: status == SpanStatus.succeeded.rawValue,
                detail: row["detail"]?.stringValue)
        }
        return ToolProficiencyReader.aggregate(attempts)
    }

    /// How long finished assignments of this kind took, for the forecast band.
    ///
    /// This is the population the band was always supposed to be made of, and
    /// until assignments were recorded as spans there was nothing to make it
    /// from. Three properties matter and each is a `WHERE` clause:
    ///
    ///  • **the whole assignment, not one attempt.** The parent span spans every
    ///    round including the reworked ones, because a plan estimate that only
    ///    counted first-time-right work would promise a schedule nobody hits;
    ///  • **succeeded only.** Cancelled work stopped for a reason that has
    ///    nothing to do with how long it takes, and an escalation is how long it
    ///    took to *give up*. Both would drag the band away from the question;
    ///  • **across projects.** The whole point of a p90 is that it comes from
    ///    more than the project asking for it.
    public func durations(forDeliverableKind kind: String) async throws -> [TimeInterval] {
        let normalised = Assignment.deliverableKind(kind)
        guard !normalised.isEmpty else { return [] }
        let rows = try await client.query("""
            SELECT started_at, ended_at FROM span
            WHERE name = type::string($name) AND deliverable_kind = type::string($kind)
              AND status = 'succeeded' AND ended_at != NONE
            LIMIT 500
            """, vars: ["name": Span.assignmentName, "kind": normalised]).first?.rows ?? []
        return Self.seconds(rows)
    }

    /// Finished assignments in one project, in the order they ran — the rows a
    /// schedule with a real time axis is drawn from (§19.7, P10.9).
    ///
    /// A bar needs a start, an end and something to sit on. The first two have
    /// existed on every span since P1.6; the third is `work_package`, and rows
    /// without one come back all the same. Work outside the plan is real work,
    /// and a chart that hid it would make the plan look like the whole story.
    public func assignments(project: ProjectID) async throws -> [Span] {
        let rows = try await client.query("""
            SELECT * FROM span
            WHERE project_id = type::string($pid) AND name = type::string($name)
            ORDER BY started_at ASC
            """, vars: ["pid": project.rawValue,
                        "name": Span.assignmentName]).first?.rows ?? []
        return rows.compactMap(Self.span(from:))
    }

    /// Durations of finished turns by the same role — the *fallback* population
    /// for the forecast band.
    ///
    /// **Turn spans only.** Without the name filter this returned every span
    /// carrying the role — which is overwhelmingly `tool:kb_search` and the
    /// like, so the "how long does this kind of work take" band was being
    /// computed from the duration of individual tool calls and drawn on a
    /// schedule. A p90 of search calls is not an estimate for a work package,
    /// and it read as one.
    ///
    /// A turn is still not an assignment: one is a message-and-tools round trip,
    /// the other is a promise reviewed against criteria. Now that assignments
    /// are recorded, this is what a young install falls back to before it has
    /// three of anything — and the caller has to say so on screen, because a
    /// band whose population is a different unit of work is exactly the kind of
    /// number this project keeps having to go back and label.
    public func durations(forRole role: Role) async throws -> [TimeInterval] {
        let rows = try await client.query("""
            SELECT started_at, ended_at FROM span
            WHERE role = type::string($role) AND name = type::string($name)
              AND status = 'succeeded' AND ended_at != NONE
            LIMIT 500
            """, vars: ["role": role.rawValue,
                        "name": Span.turnName]).first?.rows ?? []
        return Self.seconds(rows)
    }

    private static func seconds(_ rows: [[String: SurrealValue]]) -> [TimeInterval] {
        rows.compactMap { row in
            guard let started = date(row["started_at"]),
                  let ended = date(row["ended_at"]) else { return nil }
            return max(0, ended.timeIntervalSince(started))
        }
    }
}
