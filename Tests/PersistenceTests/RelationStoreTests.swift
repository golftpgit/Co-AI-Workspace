import Testing
import Foundation
import AgentKit
import Knowledge
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// Graph edges survive a restart, and never outlive the document that supports
// them (§11.4).
// ─────────────────────────────────────────────────────────────

private func relation(_ subject: String, _ predicate: String, _ object: String,
                      chunk: String = "c1", document: String = "doc_1") -> StoredRelation {
    StoredRelation(subject: subject, predicate: predicate, object: object,
                   chunkID: chunk, documentID: document)
}

@Suite("Relation store", .serialized)
struct RelationStoreTests {
    @Test("an edge comes back with the chunk that supports it",
          .timeLimit(.minutes(2)))
    func relationRoundTrips() async throws {
        guard let server = try await makeServer(port: 18_480) else { return }
        defer { Task { await server.shutdown() } }
        let store = RelationStore(client: await server.client)

        try await store.save([relation("กรมควบคุมโรค", "เผยแพร่", "แนวทางการรักษา")],
                             scope: .central)

        let loaded = try await store.load(scope: .central)
        #expect(loaded.count == 1)
        #expect(loaded.first?.subject == "กรมควบคุมโรค")
        #expect(loaded.first?.predicate == "เผยแพร่")
        // Without this the edge cannot be checked against anything.
        #expect(loaded.first?.chunkID == "c1")
    }

    @Test("saving the same edge twice keeps one row", .timeLimit(.minutes(2)))
    func savingTwiceIsIdempotent() async throws {
        guard let server = try await makeServer(port: 18_481) else { return }
        defer { Task { await server.shutdown() } }
        let store = RelationStore(client: await server.client)

        let edge = relation("อินซูลิน", "ใช้รักษา", "เบาหวาน")
        try await store.save([edge], scope: .central)
        try await store.save([edge], scope: .central)
        // Re-ingesting a document must not multiply its graph.
        #expect(try await store.load(scope: .central).count == 1)
    }

    @Test("deleting a document takes its edges with it", .timeLimit(.minutes(2)))
    func edgesDieWithTheirDocument() async throws {
        guard let server = try await makeServer(port: 18_482) else { return }
        defer { Task { await server.shutdown() } }
        let store = RelationStore(client: await server.client)

        try await store.save([
            relation("ก", "เกี่ยวข้องกับ", "ข", chunk: "c1", document: "doc_1"),
            relation("ค", "เกี่ยวข้องกับ", "ง", chunk: "c2", document: "doc_2"),
        ], scope: .central)

        try await store.deleteDocument("doc_1")
        let remaining = try await store.load(scope: .central)
        // An edge whose evidence is gone is still queried, and nothing points
        // at why it is there.
        #expect(remaining.map(\.subject) == ["ค"])
    }

    @Test("neighbours answer in both directions", .timeLimit(.minutes(2)))
    func neighboursAreUndirected() async throws {
        guard let server = try await makeServer(port: 18_483) else { return }
        defer { Task { await server.shutdown() } }
        let store = RelationStore(client: await server.client)

        try await store.save([
            relation("อินซูลิน", "ใช้รักษา", "เบาหวาน", chunk: "c1"),
            relation("เมตฟอร์มิน", "ใช้รักษา", "เบาหวาน", chunk: "c2"),
            relation("กรมควบคุมโรค", "เผยแพร่", "แนวทาง", chunk: "c3"),
        ], scope: .central)

        // A graph view asks "what touches this", not "what does this point at".
        let around = try await store.neighbours(of: "เบาหวาน", scope: .central)
        #expect(around.count == 2)
        #expect(Set(around.map(\.subject)) == ["อินซูลิน", "เมตฟอร์มิน"])
    }

    @Test("a project's graph stays inside its project", .timeLimit(.minutes(2)))
    func scopesAreSeparate() async throws {
        guard let server = try await makeServer(port: 18_484) else { return }
        defer { Task { await server.shutdown() } }
        let store = RelationStore(client: await server.client)

        try await store.save([relation("ก", "เกี่ยวข้องกับ", "ข")],
                             scope: .project(ProjectID("alpha")))
        #expect(try await store.load(scope: .project(ProjectID("alpha"))).count == 1)
        #expect(try await store.load(scope: .central).isEmpty)
    }
}
