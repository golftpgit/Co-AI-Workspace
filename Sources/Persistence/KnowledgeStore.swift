import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// The knowledge base, made durable (ARCHITECTURE §11.5, P2.7).
//
// What is stored and what is not follows the split the whole design rests on:
// text, provenance and the entities a human corrected are the source of truth
// and are written; the vector is derived, and is written only so that opening
// the app does not mean re-embedding everything. When the model changes, the
// vectors are rebuilt from the stored text and nothing else moves (P2.8).
//
// The row carries its embedding profile, so a vector built by another model
// can be recognised on load instead of being fed to an index that would rank
// nonsense with it.
// ─────────────────────────────────────────────────────────────

public actor KnowledgeStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    // MARK: - writing

    /// Idempotent by content hash: the same passage arriving twice is one row,
    /// enforced by a unique index rather than by the caller remembering to
    /// check (P2.3 checks too — this is the layer that cannot be bypassed).
    public func save(_ chunk: IndexedChunk) async throws {
        var content = ContentBuilder()
        content.setString("uid", chunk.id)
        content.setString("document_id", chunk.provenance.documentID)
        content.setString("content_hash", chunk.contentHash)
        content.setString("text", chunk.text)
        content.setString("scope_kind", ScopeColumns.kind(chunk.scope))
        content.setString("project_id", ScopeColumns.projectID(chunk.scope))
        content.setString("title", chunk.provenance.title)
        content.setString("tier", chunk.provenance.tier?.rawValue)
        content.setString("origin", Self.encode(chunk.provenance.origin))
        content.set("page", chunk.provenance.page)
        content.setString("section", chunk.provenance.section)
        content.set("authors", chunk.provenance.authors)
        content.set("year", chunk.provenance.year)
        content.setString("supersedes", chunk.provenance.supersedes)
        content.set("accessed_at", ISO8601DateFormatter().string(from: chunk.provenance.accessedAt))
        content.set("entities", chunk.entities)
        content.set("embedding", chunk.embedding?.map(Double.init))
        content.setString("embedding_profile", chunk.embeddingProfileID)
        content.raw("created_at", "time::now()")

        // UPSERT, not UPDATE: v3's UPDATE errors when the row is not there yet
        // (App. C.0), and re-saving an edited chunk has to work either way.
        try await client.exec(
            "UPSERT chunk CONTENT \(content.content) WHERE uid = $uid",
            vars: content.vars)
    }

    public func save(_ chunks: [IndexedChunk]) async throws {
        for chunk in chunks { try await save(chunk) }
    }

    /// Entity corrections are a write of their own: they change what the
    /// document answers, and losing them on restart would make the editor a
    /// lie (P2.7).
    public func updateEntities(chunkID: String, to entities: [String]) async throws {
        try await client.exec(
            "UPDATE chunk SET entities = $entities WHERE uid = $uid",
            vars: ["uid": chunkID, "entities": entities])
    }

    public func deleteDocument(_ documentID: String) async throws {
        try await client.exec("DELETE chunk WHERE document_id = $id",
                              vars: ["id": documentID])
    }

    // MARK: - reading

    /// Loads a scope's chunks. Scoped rather than "everything", because the
    /// scopes exist so central, project and policy knowledge never mix.
    public func load(scope: Scope, limit: Int = 100_000) async throws -> [IndexedChunk] {
        var vars: [String: Any] = ["kind": ScopeColumns.kind(scope), "limit": limit]
        var sql = "SELECT * FROM chunk WHERE scope_kind = $kind"
        if let projectID = ScopeColumns.projectID(scope) {
            sql += " AND project_id = $pid"
            vars["pid"] = projectID
        }
        sql += " ORDER BY created_at ASC LIMIT $limit"

        let results = try await client.query(sql, vars: vars)
        return (results.first?.rows ?? []).compactMap(Self.chunk(from:))
    }

    public func count() async throws -> Int {
        let results = try await client.query("SELECT count() AS total FROM chunk GROUP ALL")
        return results.first?.rows.first?["total"]?.intValue ?? 0
    }

    // MARK: - decoding

    private static func chunk(from row: [String: SurrealValue]) -> IndexedChunk? {
        guard let id = row["uid"]?.stringValue,
              let text = row["text"]?.stringValue,
              let documentID = row["document_id"]?.stringValue,
              let scope = ScopeColumns.scope(kind: row["scope_kind"]?.stringValue,
                                             projectID: row["project_id"]?.stringValue)
        else { return nil }

        let origin = decodeOrigin(row["origin"]?.stringValue) ?? .upload(filename: documentID)
        let accessedAt = row["accessed_at"]?.stringValue
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let entities = row["entities"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let embedding = row["embedding"]?.arrayValue?.compactMap { value in value.doubleValue.map(Float.init) }

        // A row whose tier is missing is not silently promoted to trustworthy:
        // `authored` is the only provenance that legitimately has no tier, and
        // anything else without one is treated as the least credible rather
        // than as unknown.
        let provenance: Provenance
        if let tier = row["tier"]?.stringValue.flatMap(SourceTier.init(rawValue:)) {
            provenance = Provenance(
                documentID: documentID,
                title: row["title"]?.stringValue ?? documentID,
                origin: origin, tier: tier,
                authors: row["authors"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                year: row["year"]?.intValue,
                page: row["page"]?.intValue,
                section: row["section"]?.stringValue,
                accessedAt: accessedAt,
                supersedes: row["supersedes"]?.stringValue)
        } else if case .userAuthored(let runID) = origin {
            provenance = Provenance.authored(
                documentID: documentID,
                title: row["title"]?.stringValue ?? documentID,
                runID: runID,
                page: row["page"]?.intValue,
                section: row["section"]?.stringValue,
                accessedAt: accessedAt,
                supersedes: row["supersedes"]?.stringValue)
        } else {
            provenance = Provenance(
                documentID: documentID,
                title: row["title"]?.stringValue ?? documentID,
                origin: origin, tier: .t5,
                accessedAt: accessedAt)
        }

        return IndexedChunk(
            id: id, text: text, scope: scope, provenance: provenance,
            embedding: embedding,
            embeddingProfileID: embedding == nil ? nil : row["embedding_profile"]?.stringValue,
            contentHash: row["content_hash"]?.stringValue,
            entities: entities)
    }

    /// Origin is one field rather than a nested object: v3 re-types bound
    /// strings by shape, and a flat `kind|value` avoids handing it anything
    /// that looks like a record link (App. C.0).
    private static func encode(_ origin: Origin) -> String {
        switch origin {
        case .upload(let filename): "upload|\(filename)"
        case .web(let url): "web|\(url.absoluteString)"
        case .database(let name): "database|\(name)"
        case .userAuthored(let runID): "authored|\(runID)"
        }
    }

    private static func decodeOrigin(_ raw: String?) -> Origin? {
        guard let raw, let separator = raw.firstIndex(of: "|") else { return nil }
        let kind = String(raw[raw.startIndex..<separator])
        let value = String(raw[raw.index(after: separator)...])
        switch kind {
        case "upload": return .upload(filename: value)
        case "web": return URL(string: value).map { .web(url: $0) }
        case "database": return .database(name: value)
        case "authored": return .userAuthored(runID: value)
        default: return nil
        }
    }
}
