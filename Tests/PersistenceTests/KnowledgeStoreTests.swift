import Testing
import Foundation
import AgentKit
import Knowledge
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// The knowledge base survives a restart (P2.7).
//
// Against a real SurrealDB like every other store test: what is being checked
// is whether the *engine* keeps what we gave it, which no mock can answer.
// ─────────────────────────────────────────────────────────────

private func chunk(_ id: String, _ text: String,
                   document: String = "doc_1", title: String = "รายงานประจำปี",
                   tier: SourceTier = .t2, scope: Scope = .central,
                   entities: [String] = [], embedding: [Float]? = nil,
                   profileID: String? = nil, page: Int? = nil) -> IndexedChunk {
    IndexedChunk(
        id: id, text: text, scope: scope,
        provenance: Provenance(documentID: document, title: title,
                               origin: .upload(filename: "\(document).pdf"), tier: tier,
                               authors: ["สมชาย ใจดี"], year: 2026, page: page,
                               section: page == nil ? nil : "OCR"),
        embedding: embedding, embeddingProfileID: profileID, entities: entities)
}

private let profile = EmbeddingProfile(modelID: "bge-m3", revision: "mlx-8bit",
                                       dimensions: 4)

@Suite("Knowledge store", .serialized)
struct KnowledgeStoreTests {
    @Test("a chunk comes back whole after a restart", .timeLimit(.minutes(2)))
    func chunkRoundTrips() async throws {
        guard let server = try await makeServer(port: 18_460) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        let original = chunk("c1", "การให้อินซูลินในผู้ป่วยเบาหวาน",
                             entities: ["กรมควบคุมโรค"],
                             embedding: [0.1, 0.2, 0.3, 0.4],
                             profileID: profile.id, page: 3)
        try await store.save(original)

        let loaded = try await store.load(scope: .central)
        #expect(loaded.count == 1)
        let row = try #require(loaded.first)

        #expect(row.id == original.id)
        #expect(row.text == original.text)
        #expect(row.contentHash == original.contentHash)
        #expect(row.entities == ["กรมควบคุมโรค"])
        #expect(row.embedding == [0.1, 0.2, 0.3, 0.4])
        // Without this the vectors are unusable on the next launch: an index
        // cannot accept a vector that will not say which model made it.
        #expect(row.embeddingProfileID == profile.id)

        #expect(row.provenance.tier == .t2)
        #expect(row.provenance.title == "รายงานประจำปี")
        #expect(row.provenance.page == 3)
        #expect(row.provenance.section == "OCR")
        #expect(row.provenance.authors == ["สมชาย ใจดี"])
        #expect(row.provenance.year == 2026)
        #expect(row.provenance.origin == .upload(filename: "doc_1.pdf"))
    }

    @Test("what is loaded can go straight back into an index", .timeLimit(.minutes(2)))
    func loadedChunksRebuildTheIndex() async throws {
        guard let server = try await makeServer(port: 18_461) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        try await store.save([
            chunk("c1", "การให้อินซูลินในผู้ป่วยเบาหวาน",
                  embedding: [1, 0, 0, 0], profileID: profile.id),
            chunk("c2", "การระบาดของโควิดในประเทศไทย", document: "doc_2",
                  embedding: [0, 1, 0, 0], profileID: profile.id),
        ])

        var index = KnowledgeIndex(profile: profile)
        try index.insert(contentsOf: try await store.load(scope: .central))

        // The whole point of persisting: the app opens and the knowledge is
        // searchable without re-reading a single source document.
        #expect(index.count == 2)
        #expect(index.search("อินซูลิน", scope: .central).map(\.chunk.id) == ["c1"])
        #expect(index.documents().count == 2)
    }

    @Test("saving the same chunk twice keeps one row", .timeLimit(.minutes(2)))
    func savingTwiceIsIdempotent() async throws {
        guard let server = try await makeServer(port: 18_462) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        let same = chunk("c1", "การให้อินซูลินในผู้ป่วยเบาหวาน")
        try await store.save(same)
        try await store.save(same)

        #expect(try await store.count() == 1)
    }

    @Test("an entity correction survives the restart", .timeLimit(.minutes(2)))
    func entityEditsPersist() async throws {
        guard let server = try await makeServer(port: 18_463) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        try await store.save(chunk("c1", "รายงานประจำปีของหน่วยงานด้านสาธารณสุข"))
        try await store.updateEntities(chunkID: "c1", to: ["กรมควบคุมโรค"])

        var index = KnowledgeIndex()
        try index.insert(contentsOf: try await store.load(scope: .central))
        // An editor whose corrections vanish on restart is worse than no
        // editor: the user believes the base knows something it does not.
        #expect(!index.search("กรมควบคุมโรค", scope: .central).isEmpty)
    }

    @Test("scopes stay apart in storage too", .timeLimit(.minutes(2)))
    func scopesDoNotMix() async throws {
        guard let server = try await makeServer(port: 18_464) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        try await store.save([
            chunk("c1", "ความรู้ส่วนกลาง"),
            chunk("c2", "ความรู้ของโครงการ", document: "doc_2",
                  scope: .project(ProjectID("alpha"))),
            chunk("c3", "ห้ามลบฐานข้อมูลผลการทดลอง", document: "doc_3", scope: .policy),
        ])

        #expect(try await store.load(scope: .central).map(\.id) == ["c1"])
        #expect(try await store.load(scope: .project(ProjectID("alpha"))).map(\.id) == ["c2"])
        #expect(try await store.load(scope: .policy).map(\.id) == ["c3"])
        #expect(try await store.load(scope: .project(ProjectID("beta"))).isEmpty)
    }

    @Test("deleting a document takes every chunk of it", .timeLimit(.minutes(2)))
    func deleteRemovesTheWholeDocument() async throws {
        guard let server = try await makeServer(port: 18_465) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        try await store.save([
            chunk("c1", "ตอนที่หนึ่ง"),
            chunk("c2", "ตอนที่สอง"),
            chunk("c3", "เอกสารอื่น", document: "doc_2"),
        ])
        try await store.deleteDocument("doc_1")

        let remaining = try await store.load(scope: .central)
        #expect(remaining.map(\.id) == ["c3"])
    }

    @Test("a chunk with no vector is stored and reloaded as such",
          .timeLimit(.minutes(2)))
    func vectorlessChunkStaysVectorless() async throws {
        guard let server = try await makeServer(port: 18_466) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        try await store.save(chunk("c1", "ยังไม่มีโมเดลตอน ingest"))
        let row = try #require(try await store.load(scope: .central).first)

        #expect(row.embedding == nil)
        #expect(row.embeddingProfileID == nil)
        // And it is still legal in a lexical-only index, which is the state a
        // machine with no embedding runtime works in.
        var index = KnowledgeIndex()
        #expect(throws: Never.self) { try index.insert(row) }
    }
}

// ─────────────────────────────────────────────────────────────
// P11.8's promise, at the layer that was quietly breaking it (U33-3, U33-4).
//
// Driving a real interview into the knowledge base showed it listed as **T5**
// — the least credible tier — and that is where these came from. The index
// tests were right: `TranscriptIngest` produces chunks with no tier and with a
// character span each. Nothing had ever asked what came *back* out of the
// database, and the answer was: no span at all, and a tier the transcript
// never had.
//
// The consequence is not cosmetic. §11.3's corroboration rule reads T5 as "a
// web page nobody vouches for", so a participant's own words were being ranked
// as the weakest evidence in the project — and the citation that was supposed
// to point at a paragraph pointed at a two-hour interview, from the first
// relaunch onwards.
// ─────────────────────────────────────────────────────────────

@Suite("Knowledge store — fieldwork survives the round trip", .serialized)
struct FieldworkProvenanceRoundTripTests {

    private func transcriptChunk() -> IndexedChunk {
        let provenance = Provenance.fieldwork(
            documentID: "ts_int01", title: "INT-01", participantCode: "P-7QK2",
            collectedAt: Date(timeIntervalSince1970: 1_770_000_000),
            passage: TextSpan(start: 44, end: 115))
        return IndexedChunk(id: "ts_int01#c0",
                            text: "ผู้ให้ข้อมูล: เวรหนึ่งดูคนไข้สิบสองเตียง ทำไม่ทันจริง ๆ ค่ะ",
                            scope: .project(ProjectID("pj_q")),
                            provenance: provenance, embedding: nil,
                            embeddingProfileID: nil,
                            contentHash: "hash_int01_c0")
    }

    @Test("an interview does not come back as the least credible source",
          .timeLimit(.minutes(2)))
    func fieldworkKeepsNoTier() async throws {
        guard let server = try await makeServer(port: 18_671) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        try await store.save(transcriptChunk())
        let loaded = try await store.load(scope: .project(ProjectID("pj_q")))
        let restored = try #require(loaded.first)

        #expect(restored.provenance.tier == nil,
                "a transcript came back tiered — §11.3 would rank it as a weak web page")
        #expect(restored.provenance.isExternallySourced == false)
        // And the participant code, which is the only identity a transcript carries.
        guard case .fieldwork(let code) = restored.provenance.origin else {
            Issue.record("the origin changed on the way through the database")
            return
        }
        #expect(code == "P-7QK2")
    }

    // The whole of P11.8's second clause: a citation points back at the passage.
    @Test("the character span survives, so a chunk still cites its own paragraph",
          .timeLimit(.minutes(2)))
    func passageSurvives() async throws {
        guard let server = try await makeServer(port: 18_672) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        try await store.save(transcriptChunk())
        let restored = try #require(
            try await store.load(scope: .project(ProjectID("pj_q"))).first)

        let passage = try #require(restored.provenance.passage,
                                   "the offsets were dropped — the chunk now cites the whole interview")
        #expect(passage.start == 44)
        #expect(passage.end == 115)
    }

    // Rows written before this existed have no span columns, and must still load.
    @Test("a chunk with no passage still loads, with no passage", .timeLimit(.minutes(2)))
    func absentPassageIsNotAnError() async throws {
        guard let server = try await makeServer(port: 18_673) else { return }
        defer { Task { await server.shutdown() } }
        let store = KnowledgeStore(client: await server.client)

        let paper = IndexedChunk(
            id: "doc_1#c0", text: "ผลการทดลอง", scope: .central,
            provenance: Provenance(documentID: "doc_1", title: "เอกสาร",
                                   origin: .upload(filename: "a.pdf"), tier: .t3),
            embedding: nil, embeddingProfileID: nil, contentHash: "h1")
        try await store.save(paper)

        let restored = try #require(try await store.load(scope: .central).first)
        #expect(restored.provenance.passage == nil)
        #expect(restored.provenance.tier == .t3)
    }
}
