import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P2.4 + P2.5: fusion behaves like fusion, scope does not leak, and every row
// that comes back can be cited.
// ─────────────────────────────────────────────────────────────

/// Deterministic stand-in for a real embedding model: hashes tokens into a
/// fixed number of buckets. Crude, but it makes "these two texts share
/// vocabulary" a real signal, and it never needs a server to be running.
private struct BagOfWordsEmbedder: Embedder {
    let identifier = "bag-of-words"
    let dimensions = 64
    private let tokenizer = Tokenizer()

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimensions)
            for token in tokenizer.tokens(text) {
                var hash = 5381
                for scalar in token.unicodeScalars { hash = (hash &* 33) &+ Int(scalar.value) }
                // `magnitude`, not `abs`: the wraparound above can land on
                // Int.min, and abs(Int.min) traps.
                vector[Int(hash.magnitude % UInt(dimensions))] += 1
            }
            return vector
        }
    }
}

private func provenance(_ id: String, tier: SourceTier = .t3) -> Provenance {
    Provenance(documentID: id, title: "เอกสาร \(id)",
               origin: .upload(filename: "\(id).pdf"), tier: tier)
}

private func chunk(_ id: String, _ text: String,
                   scope: Scope = .central, embedded: Bool = true) async throws -> IndexedChunk {
    let embedding = embedded ? try await BagOfWordsEmbedder().embed(text) : nil
    return IndexedChunk(id: id, text: text, scope: scope,
                        provenance: provenance(id), embedding: embedding)
}

@Suite("Hybrid search")
struct HybridSearchTests {
    @Test("every result carries provenance and a tier")
    func resultsAreCitable() async throws {
        var index = KnowledgeIndex()
        index.insert(try await chunk("a", "การให้อินซูลินช่วยคุมระดับน้ำตาลในเลือด"))
        index.insert(try await chunk("b", "วัคซีนชนิด mRNA กระตุ้นภูมิคุ้มกันในผู้สูงอายุ"))

        let results = try await index.search("อินซูลิน", scope: .central,
                                             embedder: BagOfWordsEmbedder())
        #expect(!results.isEmpty)
        for result in results {
            #expect(!result.provenance.documentID.isEmpty)
            #expect(result.tier != nil, "an uploaded document reached the index with no tier")
        }
    }

    @Test("an external source keeps the tier it was given")
    func externalProvenanceKeepsItsTier() {
        // Regression: the initialiser used to recurse into itself, because
        // `SourceTier` converts implicitly to `SourceTier?` and made the two
        // overloads the same call. Nothing external could be built at all.
        let source = Provenance(documentID: "d1", title: "แนวทางเวชปฏิบัติ",
                                origin: .upload(filename: "guideline.pdf"), tier: .t1)
        #expect(source.tier == .t1)
        #expect(source.isExternallySourced)
    }

    @Test("system-authored knowledge has provenance but claims no tier")
    func authoredHasNoTier() {
        let authored = Provenance.authored(documentID: "run_7", title: "สรุปผลวิเคราะห์",
                                           runID: "analysis_7")
        #expect(authored.tier == nil)
        #expect(authored.isExternallySourced == false)
        // It still says where it came from — that is the point of §11.3.
        #expect(authored.origin == .userAuthored(runID: "analysis_7"))
    }

    @Test("scope does not leak")
    func scopeIsolation() async throws {
        var index = KnowledgeIndex()
        index.insert(try await chunk("central", "การให้อินซูลินในผู้ป่วยเบาหวาน"))
        index.insert(try await chunk("projectA", "การให้อินซูลินในโครงการวิจัย ก",
                                     scope: .project(ProjectID("A"))))
        index.insert(try await chunk("projectB", "การให้อินซูลินในโครงการวิจัย ข",
                                     scope: .project(ProjectID("B"))))
        index.insert(try await chunk("policy", "ห้ามให้อินซูลินโดยไม่มีคำสั่งแพทย์",
                                     scope: .policy))

        let inA = try await index.search("อินซูลิน", scope: .project(ProjectID("A")),
                                         embedder: BagOfWordsEmbedder()).map(\.chunk.id)
        #expect(inA == ["projectA"], "got \(inA)")

        let central = try await index.search("อินซูลิน", scope: .central,
                                             embedder: BagOfWordsEmbedder()).map(\.chunk.id)
        #expect(central == ["central"], "got \(central)")

        // Policy knowledge is its own scope precisely so it is never mixed in
        // with ordinary retrieval (§11, P2.6).
        let policy = try await index.search("อินซูลิน", scope: .policy,
                                            embedder: BagOfWordsEmbedder()).map(\.chunk.id)
        #expect(policy == ["policy"], "got \(policy)")
    }

    @Test("fusion beats either half alone")
    func rrfPrefersAgreement() async throws {
        var index = KnowledgeIndex()
        // "both" is the only chunk that both halves like: it shares the query's
        // vocabulary *and* its wording. "lexicalOnly" repeats one query word
        // many times; "semanticOnly" paraphrases without repeating it.
        index.insert(try await chunk("both", "วัคซีน mRNA กระตุ้นภูมิคุ้มกันในผู้สูงอายุ"))
        index.insert(try await chunk("lexicalOnly", "วัคซีน วัคซีน วัคซีน วัคซีน วัคซีน"))
        index.insert(try await chunk("semanticOnly", "การกระตุ้นภูมิคุ้มกันในผู้สูงอายุด้วยยา"))

        let fused = try await index.search("วัคซีน mRNA กระตุ้นภูมิคุ้มกันในผู้สูงอายุ",
                                           scope: .central, embedder: BagOfWordsEmbedder())
        #expect(fused.first?.chunk.id == "both", "ranking: \(fused.map(\.chunk.id))")
        // And the ranking explains itself.
        #expect(fused.first?.lexicalRank != nil)
        #expect(fused.first?.semanticRank != nil)
    }

    @Test("a chunk with no embedding still competes")
    func missingEmbeddingStillRanks() async throws {
        var index = KnowledgeIndex()
        index.insert(try await chunk("embedded", "การระบาดของโควิดในประเทศไทย"))
        index.insert(try await chunk("plain", "มาตรการควบคุมโควิดของกระทรวงสาธารณสุข",
                                     embedded: false))

        let results = try await index.search("โควิด", scope: .central,
                                             embedder: BagOfWordsEmbedder())
        #expect(results.map(\.chunk.id).contains("plain"),
                "a chunk without a vector vanished instead of competing lexically")
        let plain = results.first { $0.chunk.id == "plain" }
        #expect(plain?.semanticRank == nil)
        #expect(plain?.lexicalRank != nil)
    }

    @Test("lexical-only search works when no embedder is available")
    func lexicalFallback() async throws {
        var index = KnowledgeIndex()
        index.insert(try await chunk("a", "การระบาดของโควิดในประเทศไทย"))
        index.insert(try await chunk("b", "การให้อินซูลินในผู้ป่วยเบาหวาน"))

        let results = index.search("โควิด", scope: .central)
        #expect(results.map(\.chunk.id) == ["a"], "got \(results.map(\.chunk.id))")
        #expect(results.first?.tier == .t3)
    }
}
