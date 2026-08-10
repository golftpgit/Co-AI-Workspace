import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// The index knows what it was built with, and refuses anything else.
//
// This is the invariant that keeps an embedding model out of the tier system:
// the chat model may change every turn, while changing this one silently
// invalidates every vector in the knowledge base.
// ─────────────────────────────────────────────────────────────

private struct StubEmbedder: Embedder {
    let identifier: String
    let profile: EmbeddingProfile

    init(_ modelID: String, dimensions: Int = 4) {
        self.identifier = modelID
        self.profile = EmbeddingProfile(modelID: modelID, revision: "test",
                                        dimensions: dimensions)
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: profile.dimensions)
            vector[text.count % profile.dimensions] = 1
            return vector
        }
    }
}

private func chunk(_ id: String, embedding: [Float]?, profileID: String?) -> IndexedChunk {
    IndexedChunk(id: id, text: "การให้อินซูลินในผู้ป่วยเบาหวาน", scope: .central,
                 provenance: Provenance(documentID: id, title: id,
                                        origin: .upload(filename: "\(id).pdf"), tier: .t3),
                 embedding: embedding, embeddingProfileID: profileID)
}

@Suite("Embedding profile")
struct EmbeddingProfileTests {
    @Test("the same configuration is the same profile, any difference is not")
    func identityIsDerived() {
        let base = EmbeddingProfile.bgeM3
        #expect(base.id == EmbeddingProfile.bgeM3.id)

        // Each of these produces vectors that do not belong in an index built
        // with the others.
        #expect(base.id != EmbeddingProfile(modelID: "bge-m3", revision: "f16",
                                            dimensions: 1_024).id)
        #expect(base.id != EmbeddingProfile(modelID: "bge-m3", revision: "q8_0",
                                            dimensions: 768).id)
        #expect(base.id != EmbeddingProfile(modelID: "bge-m3", revision: "q8_0",
                                            dimensions: 1_024, pooling: .mean).id)
        #expect(base.id != EmbeddingProfile(modelID: "bge-m3", revision: "q8_0",
                                            dimensions: 1_024, normalised: false).id)
    }

    @Test("changing how text is split invalidates the index too")
    func chunkingIsPartOfIdentity() {
        // The expensive one: new boundaries mean new chunk ids, so the
        // entity/relation graph and every citation anchor move with them.
        let current = EmbeddingProfile.bgeM3
        let resplit = EmbeddingProfile(modelID: "bge-m3", revision: "q8_0", dimensions: 1_024,
                                       chunkerVersion: Chunker.version + 1)
        #expect(current.id != resplit.id)

        let retokenised = EmbeddingProfile(modelID: "bge-m3", revision: "q8_0", dimensions: 1_024,
                                           tokenizerVersion: Tokenizer.version + 1)
        #expect(current.id != retokenised.id)
    }

    @Test("a vector from another model is refused, not silently dropped")
    func foreignVectorIsRefused() {
        let mine = StubEmbedder("bge-m3")
        let theirs = StubEmbedder("some-other-model")
        var index = KnowledgeIndex(profile: mine.profile)

        #expect(throws: IndexProfileError.self) {
            try index.insert(chunk("a", embedding: [1, 0, 0, 0], profileID: theirs.profile.id))
        }
        #expect(index.count == 0)
    }

    @Test("a vector that cannot name its model is refused")
    func anonymousVectorIsRefused() {
        var index = KnowledgeIndex(profile: StubEmbedder("bge-m3").profile)
        #expect(throws: IndexProfileError.self) {
            try index.insert(chunk("a", embedding: [1, 0, 0, 0], profileID: nil))
        }
    }

    @Test("a lexical-only index cannot be given vectors")
    func lexicalIndexRejectsVectors() {
        var index = KnowledgeIndex()
        let profile = StubEmbedder("bge-m3").profile
        #expect(throws: IndexProfileError.self) {
            try index.insert(chunk("a", embedding: [1, 0, 0, 0], profileID: profile.id))
        }
        // But it still holds text, which is the whole point of the fallback.
        #expect(throws: Never.self) {
            try index.insert(chunk("b", embedding: nil, profileID: nil))
        }
        #expect(index.count == 1)
    }

    @Test("searching with a different model is refused")
    func queryingWithAnotherModelIsRefused() async throws {
        let mine = StubEmbedder("bge-m3")
        var index = KnowledgeIndex(profile: mine.profile)
        try index.insert(chunk("a", embedding: [1, 0, 0, 0], profileID: mine.profile.id))

        // A question embedded by another model lands somewhere else in the
        // space; its nearest neighbours are arbitrary rather than wrong-looking.
        await #expect(throws: IndexProfileError.self) {
            _ = try await index.search("อินซูลิน", scope: .central,
                                       embedder: StubEmbedder("some-other-model"))
        }
        // The lexical half never needed the model, so it still works.
        #expect(!index.search("อินซูลิน", scope: .central).isEmpty)
    }

    @Test("the pinned profile is what P2.1 measured")
    func pinnedProfileMatchesTheDecision() {
        // ARCHITECTURE E.10 locked the dimension before indexing began; this is
        // the assertion that notices if someone edits it casually.
        #expect(EmbeddingProfile.bgeM3.dimensions == 1_024)
        #expect(EmbeddingProfile.bgeM3.modelID == "bge-m3")
    }
}
