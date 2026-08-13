import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// Conversation persistence (ARCHITECTURE §7, IMPLEMENTATION P1.3).
// The database is the source of truth, never view state: the user's message
// is committed *before* the model is called, so a crash or an agent error
// can never make it look like they never spoke.
// ─────────────────────────────────────────────────────────────

public struct Conversation: Sendable, Identifiable, Equatable {
    public let id: String
    public var title: String?
    public let scope: Scope
    public let createdAt: Date
    public var updatedAt: Date
    /// Kept at the top of the list until unpinned. The one piece of ordering a
    /// person controls, because "most recent" is the wrong answer for the
    /// conversation somebody keeps coming back to.
    public var pinned: Bool

    public init(id: String, title: String?, scope: Scope,
                createdAt: Date, updatedAt: Date, pinned: Bool = false) {
        self.id = id
        self.title = title
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinned = pinned
    }
}

/// A conversation that matched a search, with the message that matched it.
///
/// The snippet is the point: a list of titles answers "which conversations
/// exist", and what somebody searching actually asked was "where did I say
/// that".
public struct ConversationMatch: Sendable, Equatable, Identifiable {
    public let conversation: Conversation
    public let snippet: String
    public let score: Double

    public var id: String { conversation.id }
}

public struct StoredMessage: Sendable, Identifiable, Equatable {
    public enum Role: String, Sendable, Codable, CaseIterable {
        case system, user, assistant, tool
    }

    public let id: String
    public let conversationID: String
    public let role: Role
    public let content: String
    public let createdAt: Date

    public init(id: String, conversationID: String, role: Role, content: String, createdAt: Date) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

/// Identity note (ARCHITECTURE App. C.0): SurrealDB record ids are typed —
/// handing `type::record()` a UUID-shaped string produces a UUID-typed id that
/// reads back as `conversation:u'…'`, so round-tripping it as text silently
/// stops matching. Rows therefore carry an explicit `uid` string of our own
/// and every lookup goes through it; record ids stay opaque to us.
public actor ConversationStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    // MARK: - conversations

    public func create(scope: Scope, title: String? = nil) async throws -> Conversation {
        let id = OpaqueID.make(OpaqueID.conversation)   // our own key; see note below
                                                       // title omitted when nil: NULL != NONE in v3
        // Same burst problem as `append`, one step earlier: creating a
        // conversation and writing its first message land back to back, and
        // "the store was busy" must not be how a conversation fails to exist.
        // The row carries our own `uid`, so a retry cannot produce two of it.
        // Retried inline rather than through the closure helper: the bindings
        // are `[String: Any]`, which cannot cross an isolation boundary.
        var results: [QueryResult] = []
        for attempt in 0..<3 {
            // Rebuilt per attempt: the bindings are `[String: Any]`, which the
            // compiler will not let cross into the actor twice from one value.
            var content = ContentBuilder()
            content.setString("uid", id)
            content.setString("title", title)
            content.setString("scope_kind", ScopeColumns.kind(scope))
            content.setString("project_id", ScopeColumns.projectID(scope))
            content.raw("created_at", "time::now()")
            content.raw("updated_at", "time::now()")
            do {
                results = try await client.exec(
                    "CREATE conversation CONTENT \(content.content)", vars: content.vars)
                break
            } catch let error as SurrealError {
                guard Self.isWriteConflict(error), attempt < 2 else { throw error }
                try? await Task.sleep(for: .milliseconds(40 * (attempt + 1)))
            }
        }

        guard let row = results.first?.rows.first ?? results.first?.result.objectValue else {
            throw SurrealError.decoding("CREATE conversation returned no row")
        }
        return try Self.conversation(from: row, fallbackID: id)
    }

    public func list(scope: Scope? = nil, limit: Int = 100) async throws -> [Conversation] {
        var vars: [String: Any] = ["limit": limit]
        var sql = "SELECT * FROM conversation"
        if let scope {
            vars["kind"] = ScopeColumns.kind(scope)
            if let pid = ScopeColumns.projectID(scope) {
                sql += " WHERE scope_kind = $kind AND project_id = $pid"
                vars["pid"] = pid
            } else {
                sql += " WHERE scope_kind = $kind"
            }
        }
        // Pinned first, then most recent. Two keys rather than one because
        // "recent" is the wrong answer for the conversation somebody keeps
        // coming back to, which is the whole point of a pin.
        sql += " ORDER BY pinned DESC, updated_at DESC LIMIT $limit"

        let results = try await client.query(sql, vars: vars)
        return (results.first?.rows ?? []).compactMap { try? Self.conversation(from: $0) }
    }

    public func setPinned(_ id: String, _ pinned: Bool) async throws {
        try await client.exec("""
        UPDATE conversation SET pinned = $pinned, updated_at = updated_at
        WHERE uid = type::string($id)
        """, vars: ["id": id, "pinned": pinned])
    }

    /// Searches what was *said*, not what conversations are called.
    ///
    /// Same BM25 and the same tokenizer as the knowledge base — which is the
    /// whole reason this is not a `CONTAINS` query: Thai has no spaces, so
    /// substring matching finds either everything or nothing, and neither is a
    /// search (§11 / P2.2).
    ///
    /// `scope` nil searches everywhere, which is the "ค้นข้ามโปรเจกต์" button.
    public func search(_ query: String, scope: Scope?,
                       limit: Int = 20, conversationLimit: Int = 300) async throws -> [ConversationMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let conversations = try await list(scope: scope, limit: conversationLimit)
        guard !conversations.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        // One query for the messages of every visible conversation, then the
        // ranking happens here — the same shape the knowledge index uses.
        let rows = try await client.query("""
            SELECT uid, conversation_id, content FROM message
            WHERE conversation_id IN $ids AND role != 'system'
            LIMIT 20000
            """, vars: ["ids": conversations.map(\.id)]).first?.rows ?? []

        var index = BM25Index()
        var text: [String: (conversation: String, content: String)] = [:]
        for row in rows {
            guard let id = row["uid"]?.stringValue,
                  let conversation = row["conversation_id"]?.stringValue,
                  let content = row["content"]?.stringValue, !content.isEmpty else { continue }
            index.index(id: id, text: content)
            text[id] = (conversation, content)
        }

        var best: [String: (score: Double, snippet: String)] = [:]
        for scored in index.search(trimmed, limit: rows.count) {
            guard let hit = text[scored.id] else { continue }
            // Best message per conversation: five hits in one conversation is
            // one answer to "where did I say that", not five.
            if let existing = best[hit.conversation], existing.score >= scored.score { continue }
            best[hit.conversation] = (scored.score, Self.snippet(hit.content))
        }

        return best.compactMap { id, hit in
            byID[id].map { ConversationMatch(conversation: $0, snippet: hit.snippet, score: hit.score) }
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    private static func snippet(_ content: String, limit: Int = 140) -> String {
        let flat = content.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    public func rename(_ id: String, title: String) async throws {
        try await client.exec("""
        UPDATE conversation SET title = type::string($title), updated_at = time::now() WHERE uid = type::string($id)
        """, vars: ["id": id, "title": title])
    }

    /// Moves a conversation into another scope (§19.1, P10.3).
    ///
    /// Only the conversation row moves: messages are keyed by
    /// `conversation_id`, so they travel with it rather than being rewritten.
    /// Knowledge ingested along the way stays in `central` on purpose — a
    /// project can read central, so moving the chunks would take shared
    /// material *away* from General to no benefit.
    public func reassign(_ id: String, to scope: Scope) async throws {
        var vars: [String: Any] = ["id": id, "kind": ScopeColumns.kind(scope)]
        var sql = "UPDATE conversation SET scope_kind = type::string($kind), "
        if let projectID = ScopeColumns.projectID(scope) {
            sql += "project_id = type::string($pid), "
            vars["pid"] = projectID
        } else {
            // NONE, not NULL: v3 rejects a JSON null bound into an
            // `option<string>` field (App. C.0), and leaving a stale project id
            // behind would make the row answer to two scopes.
            sql += "project_id = NONE, "
        }
        sql += "updated_at = time::now() WHERE uid = type::string($id)"
        try await client.exec(sql, vars: vars)
    }

    public func delete(_ id: String) async throws {
        try await client.exec("DELETE message WHERE conversation_id = type::string($id)", vars: ["id": id])
        try await client.exec("DELETE conversation WHERE uid = type::string($id)", vars: ["id": id])
    }

    // MARK: - messages

    /// Appends and touches the conversation. Awaited, never fire-and-forget:
    /// the turn is not "done" until the write has actually landed.
    ///
    /// `content` goes through `type::string()` because it is the user's text
    /// and we do not get to constrain its shape: a message that happens to
    /// read `note:1` is bound as a record link otherwise, and the write fails
    /// on a `TYPE string` field (App. C.0) — losing exactly the message P1.3
    /// promises to keep.
    @discardableResult
    public func append(conversationID: String,
                       role: StoredMessage.Role,
                       content: String) async throws -> StoredMessage {
        let id = OpaqueID.make(OpaqueID.message)
        // Two statements, one busy store: SurrealKV rejects a write that
        // conflicts with another in flight, and appending a message is the one
        // call that arrives in bursts — a streamed answer and the user's next
        // line land within milliseconds of each other. Found by the history
        // tests failing only while the machine was busy, which is exactly when
        // losing a message would matter.
        //
        // The retry is bounded and only for the conflict: an error that means
        // something else must not be swallowed by a loop.
        try await retryingWriteConflict {
            try await client.exec("""
            CREATE message CONTENT {
                uid: type::string($id), conversation_id: type::string($cid),
                role: type::string($role), content: type::string($content), created_at: time::now()
            };
            UPDATE conversation SET updated_at = time::now() WHERE uid = type::string($cid);
            """, vars: ["id": id, "cid": conversationID, "role": role.rawValue, "content": content])
        }

        return StoredMessage(id: id, conversationID: conversationID,
                             role: role, content: content, createdAt: Date())
    }

    /// Retries a write that lost a race, and nothing else.
    private func retryingWriteConflict(_ body: () async throws -> Void) async throws {
        for attempt in 0..<3 {
            do {
                try await body()
                return
            } catch let error as SurrealError {
                guard Self.isWriteConflict(error), attempt < 2 else { throw error }
                try? await Task.sleep(for: .milliseconds(40 * (attempt + 1)))
            }
        }
    }

    /// The store telling us it lost a race, which is the one error worth
    /// trying again. Anything else is a fact about the statement.
    private static func isWriteConflict(_ error: SurrealError) -> Bool {
        guard case .server(_, let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("conflict")
    }

    /// Full history in order — loaded from the database on every turn rather
    /// than trusting whatever the UI happens to be holding.
    public func history(conversationID: String, limit: Int = 500) async throws -> [StoredMessage] {
        let results = try await client.query("""
        SELECT * FROM message WHERE conversation_id = $cid ORDER BY created_at ASC LIMIT $limit
        """, vars: ["cid": conversationID, "limit": limit])

        return (results.first?.rows ?? []).compactMap { row in
            guard let cid = row["conversation_id"]?.stringValue,
                  let roleRaw = row["role"]?.stringValue,
                  let role = StoredMessage.Role(rawValue: roleRaw),
                  let content = row["content"]?.stringValue else { return nil }
            return StoredMessage(id: row["uid"]?.stringValue ?? OpaqueID.make(OpaqueID.message),
                                 conversationID: cid,
                                 role: role,
                                 content: content,
                                 createdAt: Self.date(row["created_at"]) ?? Date())
        }
    }

    public func messageCount(conversationID: String) async throws -> Int {
        let results = try await client.query("""
        SELECT count() FROM message WHERE conversation_id = type::string($cid) GROUP ALL
        """, vars: ["cid": conversationID])
        return results.first?.rows.first?["count"]?.intValue ?? 0
    }

    // MARK: - decoding helpers

    private static func conversation(from row: [String: SurrealValue],
                                     fallbackID: String? = nil) throws -> Conversation {
        guard let scope = ScopeColumns.scope(kind: row["scope_kind"]?.stringValue,
                                             projectID: row["project_id"]?.stringValue) else {
            throw SurrealError.decoding("conversation row missing a usable scope")
        }
        let id = row["uid"]?.stringValue ?? fallbackID
        guard let id else { throw SurrealError.decoding("conversation row missing uid") }
        return Conversation(id: id,
                            title: row["title"]?.stringValue,
                            scope: scope,
                            createdAt: date(row["created_at"]) ?? Date(),
                            updatedAt: date(row["updated_at"]) ?? Date(),
                            pinned: row["pinned"]?.boolValue ?? false)
    }

    private static func date(_ value: SurrealValue?) -> Date? {
        SurrealTime.date(from: value?.stringValue)
    }
}
