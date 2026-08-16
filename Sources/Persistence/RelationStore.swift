import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// The knowledge graph's edges, stored (ARCHITECTURE §11.4).
//
// A relation is derived — a model read a chunk and said what it connects — so
// it is regenerable, and it is deleted with the document that supports it.
// That deletion matters more than it looks: an edge whose chunk is gone is an
// assertion with nothing behind it, and the graph would keep answering with it.
// ─────────────────────────────────────────────────────────────

public struct StoredRelation: Sendable, Equatable, Identifiable {
    public let subject: String
    public let predicate: String
    public let object: String
    public let chunkID: String
    public let documentID: String

    public var id: String { "\(chunkID)|\(subject)|\(predicate)|\(object)" }

    public init(subject: String, predicate: String, object: String,
                chunkID: String, documentID: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.chunkID = chunkID
        self.documentID = documentID
    }
}

public actor RelationStore {
    private let client: SurrealClient

    public init(client: SurrealClient) {
        self.client = client
    }

    /// Saves what the extractor read, minus anything a person has already
    /// rejected (§11.4).
    ///
    /// The filter is here rather than at the call site because re-ingesting a
    /// document is the moment a correction gets undone, and every path that
    /// writes relations goes through this one.
    public func save(_ relations: [StoredRelation], scope: Scope) async throws {
        let rejected = try await rejections()
        for relation in relations where !rejected.contains(relation.id) {
            var content = ContentBuilder()
            content.setString("uid", relation.id)
            content.setString("subject", relation.subject)
            content.setString("predicate", relation.predicate)
            content.setString("object", relation.object)
            content.setString("chunk_id", relation.chunkID)
            content.setString("document_id", relation.documentID)
            content.setString("scope_kind", ScopeColumns.kind(scope))
            content.setString("project_id", ScopeColumns.projectID(scope))
            content.raw("created_at", "time::now()")

            try await client.exec("UPSERT relation CONTENT \(content.content) WHERE uid = type::string($uid)",
                                  vars: content.vars)
        }
    }

    public func load(scope: Scope) async throws -> [StoredRelation] {
        var vars: [String: Any] = ["kind": ScopeColumns.kind(scope)]
        var sql = "SELECT * FROM relation WHERE scope_kind = $kind"
        if let projectID = ScopeColumns.projectID(scope) {
            sql += " AND project_id = $pid"
            vars["pid"] = projectID
        }

        return try await client.query(sql, vars: vars).first?.rows.compactMap { row in
            guard let subject = row["subject"]?.stringValue,
                  let predicate = row["predicate"]?.stringValue,
                  let object = row["object"]?.stringValue,
                  let chunkID = row["chunk_id"]?.stringValue,
                  let documentID = row["document_id"]?.stringValue else { return nil }
            return StoredRelation(subject: subject, predicate: predicate, object: object,
                                  chunkID: chunkID, documentID: documentID)
        } ?? []
    }

    /// Deletes one edge, and records that a person deleted it.
    ///
    /// **Deleting a relation deletes a reading, not the sentence.** The chunk
    /// stays exactly where it was; what goes is the model's claim about what
    /// it connects. The rejection is what makes the correction stick: without
    /// it, re-reading the document puts the same arrow back and the person's
    /// work is undone by an ingest they did not know had happened.
    public func reject(_ relation: StoredRelation) async throws {
        try await client.exec("DELETE relation WHERE uid = type::string($uid)",
                              vars: ["uid": relation.id])
        var content = ContentBuilder()
        content.setString("uid", relation.id)
        content.raw("rejected_at", "time::now()")
        try await client.exec(
            "UPSERT relation_rejection CONTENT \(content.content) WHERE uid = type::string($uid)",
            vars: content.vars)
    }

    /// The edges a person has thrown out, by id.
    public func rejections() async throws -> Set<String> {
        let rows = try await client.query("SELECT uid FROM relation_rejection")
            .first?.rows ?? []
        return Set(rows.compactMap { $0["uid"]?.stringValue })
    }

    /// Called when a document leaves the knowledge base. An edge that outlives
    /// its evidence is worse than a missing edge: it is still queried, and
    /// nothing points at why it is there.
    public func deleteDocument(_ documentID: String) async throws {
        try await client.exec("DELETE relation WHERE document_id = type::string($id)",
                              vars: ["id": documentID])
    }

    /// Everything one entity is connected to, in either direction — the query
    /// a graph view is built on.
    public func neighbours(of entity: String, scope: Scope) async throws -> [StoredRelation] {
        try await load(scope: scope).filter {
            $0.subject.caseInsensitiveCompare(entity) == .orderedSame
                || $0.object.caseInsensitiveCompare(entity) == .orderedSame
        }
    }
}

public extension StoredRelation {
    /// The shape `EntityGraph` reads. Mapped here rather than there because
    /// Persistence knows about Knowledge and not the reverse (§0.2's module
    /// rule, and the same reason Roster carries a manifest's knowledge view as
    /// text).
    var forGraph: EntityGraph.Relation {
        EntityGraph.Relation(subject: subject, predicate: predicate, object: object,
                             chunkID: chunkID, documentID: documentID)
    }
}
