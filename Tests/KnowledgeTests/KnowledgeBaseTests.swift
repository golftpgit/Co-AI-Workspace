import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P2.7's Done-when, minus the pixels: "แก้ entity แล้วผลค้นหาเปลี่ยนตามจริง".
//
// An entity editor that does not change retrieval is a text field over a
// database — the whole reason a user corrects an entity is that the system
// then finds the document by that name.
// ─────────────────────────────────────────────────────────────

private func chunk(_ id: String, _ text: String, entities: [String] = [],
                   title: String = "เอกสาร", document: String = "doc_1",
                   tier: SourceTier = .t3, scope: Scope = .central) -> IndexedChunk {
    IndexedChunk(id: id, text: text, scope: scope,
                 provenance: Provenance(documentID: document, title: title,
                                        origin: .upload(filename: "\(document).pdf"),
                                        tier: tier),
                 entities: entities)
}

@Suite("Knowledge base")
struct KnowledgeBaseTests {
    @Test("correcting an entity changes what the document answers")
    func editingAnEntityChangesSearch() {
        var index = KnowledgeIndex()
        try! index.insert(chunk("c1", "รายงานประจำปีของหน่วยงานด้านสาธารณสุข"))
        try! index.insert(chunk("c2", "บันทึกการประชุมคณะกรรมการวิจัย", document: "doc_2"))

        // Nobody can find it by the name of the agency, because the text never
        // says which agency it is.
        #expect(index.search("กรมควบคุมโรค", scope: .central).isEmpty)

        let edited = index.updateEntities(of: "c1", to: ["กรมควบคุมโรค"])
        #expect(edited)

        let found = index.search("กรมควบคุมโรค", scope: .central)
        #expect(found.map(\.chunk.id) == ["c1"], "got \(found.map(\.chunk.id))")
    }

    @Test("removing an entity takes the answer away again")
    func removingAnEntityIsAlsoReflected() {
        var index = KnowledgeIndex()
        try! index.insert(chunk("c1", "รายงานประจำปี", entities: ["กรมควบคุมโรค"]))
        #expect(!index.search("กรมควบคุมโรค", scope: .central).isEmpty)

        index.updateEntities(of: "c1", to: [])
        #expect(index.search("กรมควบคุมโรค", scope: .central).isEmpty)
    }

    @Test("editing a chunk that is gone reports failure rather than doing nothing")
    func editingAMissingChunkFails() {
        var index = KnowledgeIndex()
        let edited = index.updateEntities(of: "nope", to: ["x"])
        #expect(edited == false)
    }

    @Test("the document list carries what the UI has to show")
    func documentListIsComplete() {
        var index = KnowledgeIndex()
        try! index.insert(chunk("c1", "ตอนที่หนึ่ง", entities: ["กรมควบคุมโรค"],
                                title: "รายงานประจำปี", tier: .t1))
        try! index.insert(chunk("c2", "ตอนที่สอง", title: "รายงานประจำปี", tier: .t1))
        try! index.insert(chunk("c3", "อีกเอกสารหนึ่ง", title: "บันทึกประชุม",
                                document: "doc_2", tier: .t4))

        let documents = index.documents()
        #expect(documents.count == 2)

        let report = documents.first { $0.title == "รายงานประจำปี" }
        #expect(report?.chunkCount == 2)
        #expect(report?.tier == .t1, "the tier badge has nothing to show")
        #expect(report?.entities == ["กรมควบคุมโรค"])
        #expect(report?.hasVectors == false, "the list should admit there are no vectors")
    }

    @Test("deleting a document takes all of it")
    func deletingADocumentRemovesEveryChunk() {
        var index = KnowledgeIndex()
        try! index.insert(chunk("c1", "ตอนที่หนึ่ง"))
        try! index.insert(chunk("c2", "ตอนที่สอง"))
        try! index.insert(chunk("c3", "อีกเอกสาร", document: "doc_2"))

        let removed = index.removeDocument("doc_1")
        #expect(removed == 2)
        #expect(index.count == 1)
        // A half-deleted document is a citation that leads nowhere.
        #expect(index.documents().map(\.documentID) == ["doc_2"])
    }

    @Test("export carries the text and the corrections, not the vectors")
    func exportOmitsVectors() async throws {
        var index = KnowledgeIndex()
        try index.insert(chunk("c1", "รายงานประจำปี", entities: ["กรมควบคุมโรค"]))

        let archive = index.export()
        #expect(archive.entries.count == 1)
        #expect(archive.entries[0].entities == ["กรมควบคุมโรค"])
        // Vectors are derived from text by a named model. Shipping them would
        // be wrong the moment the other machine ran a different one.
        let encoded = try JSONEncoder().encode(archive)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("embedding"))
    }

    @Test("import restores the corrections and is idempotent")
    func importRoundTrips() async throws {
        var source = KnowledgeIndex()
        try source.insert(chunk("c1", "รายงานประจำปี", entities: ["กรมควบคุมโรค"]))
        let archive = source.export()

        var destination = KnowledgeIndex()
        let added = try await destination.importArchive(archive,
                                                        embedder: Optional<NeverEmbedder>.none)
        #expect(added == 1)
        #expect(!destination.search("กรมควบคุมโรค", scope: .central).isEmpty,
                "the corrected entity did not survive the round trip")

        let again = try await destination.importArchive(archive,
                                                        embedder: Optional<NeverEmbedder>.none)
        #expect(again == 0, "importing twice duplicated the knowledge base")
    }

    @Test("an archive from a newer app is refused rather than half-read")
    func futureFormatIsRefused() async throws {
        let future = KnowledgeArchive(formatVersion: 99, exportedProfile: nil, entries: [])
        var index = KnowledgeIndex()
        await #expect(throws: ArchiveError.self) {
            _ = try await index.importArchive(future, embedder: Optional<NeverEmbedder>.none)
        }
    }
}
