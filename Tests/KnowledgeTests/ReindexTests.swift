import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P2.8's second half: a better model can replace the one an index was built
// with, and a worse one cannot sneak in.
// ─────────────────────────────────────────────────────────────

/// Ranks by shared vocabulary — good enough that retrieval actually works.
private struct GoodEmbedder: Embedder {
    let identifier: String
    let profile: EmbeddingProfile
    private let tokenizer = Tokenizer()

    init(_ modelID: String) {
        identifier = modelID
        profile = EmbeddingProfile(modelID: modelID, revision: "test", dimensions: 32)
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: 32)
            for token in tokenizer.tokens(text) {
                var hash = 5_381
                for scalar in token.unicodeScalars { hash = (hash &* 33) &+ Int(scalar.value) }
                vector[Int(hash.magnitude % 32)] += 1
            }
            return vector
        }
    }
}

/// The model that must never reach the index: it answers, so nothing looks
/// broken, but every vector is the same and the ranking is arbitrary (E.11).
private struct DegradedEmbedder: Embedder {
    let identifier = "degraded"
    let profile = EmbeddingProfile(modelID: "degraded", revision: "test", dimensions: 32)

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [Float](repeating: 0.5, count: 32) }
    }
}

private let corpus: [(id: String, text: String)] = [
    ("insulin", "การให้อินซูลินแบบพื้นฐานร่วมกับยากินช่วยคุมน้ำตาลได้ดีขึ้น"),
    ("covid", "การระบาดของโควิดในประเทศไทยทำให้ระบบสาธารณสุขรับภาระหนัก"),
    ("vaccine", "วัคซีนชนิด mRNA กระตุ้นภูมิคุ้มกันได้ดีในผู้สูงอายุ"),
    ("metal", "การปนเปื้อนโลหะหนักในแหล่งน้ำดิบส่งผลต่อสุขภาพประชาชน"),
]

private let goldens = [
    GoldenQuery(query: "อินซูลิน", scope: .central, relevant: ["insulin"]),
    GoldenQuery(query: "โควิด", scope: .central, relevant: ["covid"]),
    GoldenQuery(query: "วัคซีน", scope: .central, relevant: ["vaccine"]),
]

private func buildIndex(with embedder: some Embedder) async throws -> KnowledgeIndex {
    // No similarity floor: the stubs below are bag-of-hashed-tokens vectors,
    // and the shipped cutoff is a number measured on bge-m3. Holding a toy
    // embedder to it would measure the constant, not the reindex gate.
    var index = KnowledgeIndex(profile: embedder.profile, minimumSemanticSimilarity: 0)
    for document in corpus {
        let vector = try await embedder.embed(document.text)
        try index.insert(IndexedChunk(
            id: document.id, text: document.text, scope: .central,
            provenance: Provenance(documentID: document.id, title: document.id,
                                   origin: .upload(filename: "\(document.id).pdf"), tier: .t2),
            embedding: vector, embeddingProfileID: embedder.profile.id,
            entities: ["กระทรวงสาธารณสุข"]))
    }
    return index
}

@Suite("Reindexing")
struct ReindexTests {
    @Test("a rebuild keeps everything the graph and citations point at")
    func rebuildPreservesIdentity() async throws {
        let old = GoodEmbedder("v1")
        let new = GoodEmbedder("v2")
        let index = try await buildIndex(with: old)

        let (rebuilt, completed) = try await Reindexer().rebuild(index, using: new)

        #expect(completed == corpus.count)
        #expect(rebuilt.map(\.id) == corpus.map(\.id), "chunk ids moved, which orphans the graph")
        for (before, after) in zip(index.allChunks, rebuilt) {
            #expect(after.text == before.text)
            #expect(after.provenance == before.provenance)
            #expect(after.contentHash == before.contentHash)
            #expect(after.entities == before.entities)
            #expect(after.embeddingProfileID == new.profile.id)
            #expect(after.embedding != nil)
        }
    }

    @Test("a rebuild can be interrupted and carried on")
    func rebuildResumes() async throws {
        let index = try await buildIndex(with: GoodEmbedder("v1"))
        let reindexer = Reindexer(batchSize: 1)
        let new = GoodEmbedder("v2")

        // 10,000 chunks is a long job; being killed halfway through should not
        // mean starting over.
        let (first, stopped) = try await reindexer.rebuild(index, using: new, limit: 2)
        #expect(stopped == 2)
        let (rest, finished) = try await reindexer.rebuild(index, using: new, resumeFrom: stopped)
        #expect(finished == corpus.count)
        #expect((first + rest).map(\.id) == corpus.map(\.id))
    }

    @Test("an equally good model is accepted and becomes the live index")
    func goodMigrationIsAccepted() async throws {
        let old = GoodEmbedder("v1")
        let index = try await buildIndex(with: old)
        let new = GoodEmbedder("v2")

        let (migrated, report) = try await Reindexer().migrate(
            index, to: new, previousEmbedder: old, goldens: goldens)

        #expect(report.accepted, "\(report.summary)")
        #expect(migrated.profile?.id == new.profile.id)
        #expect(migrated.count == corpus.count)
        #expect(report.after.recallAt1 == 1.0, "\(report.summary)")
    }

    /// The case that nearly slipped through. A model returning one identical
    /// vector for every chunk scored recall@1 1.00 on the fused gate, because
    /// BM25 answered every golden query by itself. The gate now scores the
    /// vector half where nothing can carry it.
    @Test("a model whose vectors say nothing is refused, even when fused search still works")
    func degradedMigrationIsRejected() async throws {
        let old = GoodEmbedder("v1")
        let index = try await buildIndex(with: old)

        let (kept, report) = try await Reindexer().migrate(
            index, to: DegradedEmbedder(), previousEmbedder: old, goldens: goldens)

        #expect(!report.accepted, "\(report.summary)")
        // Fused retrieval really is fine — which is exactly why the fused
        // number could not be the whole gate.
        #expect(report.after.recallAt1 == 1.0, "\(report.summary)")
        // Still serving from the model that works — nothing was thrown away.
        #expect(kept.profile?.id == old.profile.id)
        #expect(kept.allChunks.allSatisfy { $0.embeddingProfileID == old.profile.id })
    }

    @Test("the vector half is scored where BM25 cannot carry it")
    func semanticOnlyScoringExposesADeadModel() async throws {
        let good = GoodEmbedder("v1")
        let index = try await buildIndex(with: good)
        let reindexer = Reindexer()

        let semantic = try await reindexer.evaluate(index, against: goldens,
                                                    embedder: good, mode: .semanticOnly)
        #expect(semantic.recallAt1 > 0, "\(semantic.summary)")

        // Same corpus, vectors that carry nothing: fused still looks perfect.
        var dead = KnowledgeIndex(profile: DegradedEmbedder().profile,
                                  minimumSemanticSimilarity: 0)
        for chunk in index.allChunks {
            try dead.insert(IndexedChunk(
                id: chunk.id, text: chunk.text, scope: chunk.scope,
                provenance: chunk.provenance,
                embedding: try await DegradedEmbedder().embed(chunk.text),
                embeddingProfileID: DegradedEmbedder().profile.id))
        }
        let deadFused = try await reindexer.evaluate(dead, against: goldens,
                                                     embedder: DegradedEmbedder())
        #expect(deadFused.recallAt1 == 1.0, "BM25 alone should still answer: \(deadFused.summary)")
    }

    @Test("with nothing to measure against, nothing is switched")
    func noGoldensMeansNoSwitch() async throws {
        let old = GoodEmbedder("v1")
        let index = try await buildIndex(with: old)

        let (kept, report) = try await Reindexer().migrate(
            index, to: GoodEmbedder("v2"), previousEmbedder: old, goldens: [])

        #expect(!report.accepted)
        #expect(kept.profile?.id == old.profile.id)
        #expect(report.reason.contains("nothing was measured"), "\(report.reason)")
    }

    @Test("scoring reports what a user would feel")
    func scoringIsMeaningful() async throws {
        let embedder = GoodEmbedder("v1")
        let index = try await buildIndex(with: embedder)

        let score = try await Reindexer().evaluate(index, against: goldens, embedder: embedder)
        #expect(score.queries == 3)
        #expect(score.recallAt1 == 1.0, "\(score.summary)")
        #expect(score.recallAt5 == 1.0, "\(score.summary)")
        #expect(score.mrr == 1.0, "\(score.summary)")
    }

    @Test("the rebuild never reads the source documents")
    func rebuildIsTextOnly() async throws {
        // Provenance still says the file it came from, but the file is gone:
        // re-embedding must work from stored text, or a model change would
        // mean re-scanning every document that was ever ingested.
        let index = try await buildIndex(with: GoodEmbedder("v1"))
        #expect(index.allChunks.allSatisfy {
            if case .upload(let filename) = $0.provenance.origin {
                return !FileManager.default.fileExists(atPath: filename)
            }
            return false
        })

        let (rebuilt, _) = try await Reindexer().rebuild(index, using: GoodEmbedder("v2"))
        #expect(rebuilt.count == corpus.count)
    }
}
