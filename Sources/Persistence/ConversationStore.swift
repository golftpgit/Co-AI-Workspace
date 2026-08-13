import Foundation
import AgentKit

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

    public init(id: String, title: String?, scope: Scope, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
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
        let id = OpaqueID.make(OpaqueID.conversation)
        var content = ContentBuilder()
        content.setString("uid", id)               // our own key; see note below
        content.setString("title", title)          // omitted when nil: NULL != NONE in v3
        content.setString("scope_kind", ScopeColumns.kind(scope))
        content.setString("project_id", ScopeColumns.projectID(scope))
        content.raw("created_at", "time::now()")
        content.raw("updated_at", "time::now()")

        let results = try await client.exec(
            "CREATE conversation CONTENT \(content.content)",
            vars: content.vars)

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
        sql += " ORDER BY updated_at DESC LIMIT $limit"

        let results = try await client.query(sql, vars: vars)
        return (results.first?.rows ?? []).compactMap { try? Self.conversation(from: $0) }
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
        try await client.exec("""
        CREATE message CONTENT {
            uid: type::string($id), conversation_id: type::string($cid),
            role: type::string($role), content: type::string($content), created_at: time::now()
        };
        UPDATE conversation SET updated_at = time::now() WHERE uid = type::string($cid);
        """, vars: ["id": id, "cid": conversationID, "role": role.rawValue, "content": content])

        return StoredMessage(id: id, conversationID: conversationID,
                             role: role, content: content, createdAt: Date())
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
                            updatedAt: date(row["updated_at"]) ?? Date())
    }

    private static func date(_ value: SurrealValue?) -> Date? {
        SurrealTime.date(from: value?.stringValue)
    }
}
