import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Changing the embedding model without losing the knowledge base
// (ARCHITECTURE §11, P2.8).
//
// The whole design rests on one split: the text of a chunk and its provenance
// are the source of truth and never regenerated; vectors are derived and
// disposable. So a better model arriving next year is a rebuild, not a
// migration — and specifically not a re-scan, because the text that OCR
// produced is already stored.
//
// Two rules the rebuild obeys:
//   • chunk ids, text, provenance and entities are carried over untouched —
//     the entity graph and every citation anchor point at those ids;
//   • nothing is switched over until it has been *measured* against the index
//     it replaces. A model that retrieves worse must be found here, not by a
//     user who stops finding their documents.
// ─────────────────────────────────────────────────────────────

/// A query whose right answer is known, used to compare two indexes.
/// Built from real retrievals a user confirmed (§16 golden tasks).
public struct GoldenQuery: Sendable, Equatable {
    public let query: String
    public let scope: Scope
    /// Chunks that should come back. Ids, because they survive re-embedding.
    public let relevant: Set<String>

    public init(query: String, scope: Scope, relevant: Set<String>) {
        self.query = query
        self.scope = scope
        self.relevant = relevant
    }
}

public struct RetrievalScore: Sendable, Equatable {
    public let recallAt1: Double
    public let recallAt5: Double
    public let mrr: Double
    public let queries: Int

    public var summary: String {
        String(format: "recall@1 %.2f · recall@5 %.2f · MRR %.2f (%d queries)",
               recallAt1, recallAt5, mrr, queries)
    }
}

public struct ReindexReport: Sendable {
    public let from: String
    public let to: String
    public let chunksReembedded: Int
    public let chunksCarriedWithoutVector: Int
    public let before: RetrievalScore
    public let after: RetrievalScore
    /// False when the new index retrieves measurably worse. The old index is
    /// still the live one in that case; nothing has been thrown away.
    public let accepted: Bool
    public let reason: String

    public var summary: String {
        "\(accepted ? "accepted" : "REJECTED") \(from) → \(to): "
            + "before [\(before.summary)] after [\(after.summary)] — \(reason)"
    }
}

public struct Reindexer: Sendable {
    /// How much worse the new index may be before the switch is refused.
    /// Zero would reject noise; this allows a rounding-level difference and
    /// nothing more.
    public let tolerance: Double
    public let batchSize: Int

    public init(tolerance: Double = 0.01, batchSize: Int = 32) {
        self.tolerance = tolerance
        self.batchSize = batchSize
    }

    // MARK: - rebuild

    /// Re-embeds every chunk from the text already stored. Source documents are
    /// never touched: OCR, parsing and chunking all happened once.
    ///
    /// `resumeFrom` makes a 10,000-chunk rebuild interruptible — it returns the
    /// chunks it produced along with how far it got, so a caller that is killed
    /// can carry on rather than start again.
    public func rebuild(_ index: KnowledgeIndex,
                        using embedder: some Embedder,
                        resumeFrom: Int = 0,
                        limit: Int? = nil,
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async throws
        -> (chunks: [IndexedChunk], completed: Int) {
        let all = index.allChunks
        let end = min(limit.map { resumeFrom + $0 } ?? all.count, all.count)
        guard resumeFrom < end else { return ([], resumeFrom) }

        var rebuilt: [IndexedChunk] = []
        var cursor = resumeFrom

        while cursor < end {
            let batch = Array(all[cursor..<min(cursor + batchSize, end)])
            let vectors = try await embedder.embed(batch.map(\.text))
            guard vectors.count == batch.count else { throw EmbeddingError.empty }

            for (chunk, vector) in zip(batch, vectors) {
                rebuilt.append(IndexedChunk(
                    id: chunk.id,                       // the graph hangs off this
                    text: chunk.text,
                    scope: chunk.scope,
                    provenance: chunk.provenance,
                    embedding: vector,
                    embeddingProfileID: embedder.profile.id,
                    contentHash: chunk.contentHash,
                    entities: chunk.entities))
            }
            cursor += batch.count
            progress?(cursor, all.count)
        }
        return (rebuilt, cursor)
    }

    // MARK: - measure

    public enum Mode: Sendable {
        /// What a user gets: BM25 and vectors fused.
        case fused
        /// Vectors alone. A broken embedding model is invisible in a fused
        /// score that BM25 is carrying — measured and confirmed while building
        /// this gate, see the tests. Health checks must look here.
        case semanticOnly
    }

    /// Scores an index against known-good retrievals. Lexical-only when no
    /// embedder is given, which is also how a rebuild's *before* picture is
    /// taken when the old model is already gone.
    public func evaluate(_ index: KnowledgeIndex,
                         against goldens: [GoldenQuery],
                         embedder: (some Embedder)?,
                         mode: Mode = .fused) async throws -> RetrievalScore {
        guard !goldens.isEmpty else {
            return RetrievalScore(recallAt1: 0, recallAt5: 0, mrr: 0, queries: 0)
        }

        var hitsAt1 = 0.0, hitsAt5 = 0.0, reciprocal = 0.0
        for golden in goldens {
            let results: [SearchResult]
            if let embedder, index.profile?.id == embedder.profile.id {
                results = switch mode {
                case .fused:
                    try await index.search(golden.query, scope: golden.scope,
                                           embedder: embedder, limit: 10)
                case .semanticOnly:
                    try await index.searchSemantically(golden.query, scope: golden.scope,
                                                       embedder: embedder, limit: 10)
                }
            } else {
                results = index.search(golden.query, scope: golden.scope, limit: 10)
            }
            let ids = results.map(\.chunk.id)
            if let first = ids.first, golden.relevant.contains(first) { hitsAt1 += 1 }
            if ids.prefix(5).contains(where: golden.relevant.contains) { hitsAt5 += 1 }
            if let rank = ids.firstIndex(where: golden.relevant.contains) {
                reciprocal += 1 / Double(rank + 1)
            }
        }
        let n = Double(goldens.count)
        return RetrievalScore(recallAt1: hitsAt1 / n, recallAt5: hitsAt5 / n,
                              mrr: reciprocal / n, queries: goldens.count)
    }

    // MARK: - migrate

    /// Rebuild, measure, and only then hand back the new index. The old one is
    /// returned unchanged if the new model is worse, so the caller can keep
    /// serving from it — this is the step that makes swapping models safe
    /// rather than brave.
    public func migrate(_ index: KnowledgeIndex,
                        to embedder: some Embedder,
                        previousEmbedder: (some Embedder)? = Optional<NeverEmbedder>.none,
                        goldens: [GoldenQuery],
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async throws
        -> (index: KnowledgeIndex, report: ReindexReport) {
        let before = try await evaluate(index, against: goldens, embedder: previousEmbedder)

        let (rebuilt, _) = try await rebuild(index, using: embedder, progress: progress)
        var candidate = KnowledgeIndex(profile: embedder.profile)
        try candidate.insert(contentsOf: rebuilt)

        let after = try await evaluate(candidate, against: goldens, embedder: embedder)

        // recall@1 is the number a user feels; MRR catches a model that keeps
        // finding the document but pushes it down the page.
        let lostRecall = before.recallAt1 - after.recallAt1
        let lostMRR = before.mrr - after.mrr
        let fusedHeld = lostRecall <= tolerance && lostMRR <= tolerance

        // The fused score alone is not enough, and this was measured rather
        // than assumed: an embedder returning one identical vector for every
        // chunk passed the fused gate at recall@1 1.00, because BM25 was
        // carrying every query on its own. The vector half has to be scored
        // where nothing can carry it.
        let semantic = try await evaluate(candidate, against: goldens,
                                          embedder: embedder, mode: .semanticOnly)
        let diagnosis = try await diagnose(embedder)
        let semanticWorks = diagnosis.isUsable && semantic.recallAt1 > 0

        let accepted = !goldens.isEmpty && fusedHeld && semanticWorks

        let reason: String
        if goldens.isEmpty {
            reason = "no golden queries: nothing was measured, so nothing is switched"
        } else if !diagnosis.isUsable {
            reason = "the new model is \(diagnosis) — its vectors carry no information"
        } else if semantic.recallAt1 <= 0 {
            reason = "vectors alone retrieve nothing (\(semantic.summary)); "
                + "the fused score was being carried by BM25"
        } else if !fusedHeld {
            reason = String(format: "retrieval dropped: recall@1 -%.2f, MRR -%.2f (tolerance %.2f)",
                            lostRecall, lostMRR, tolerance)
        } else {
            reason = "retrieval held within tolerance \(tolerance); "
                + "vectors alone score \(semantic.summary)"
        }

        let report = ReindexReport(
            from: index.profile?.id ?? "lexical-only",
            to: embedder.profile.id,
            chunksReembedded: rebuilt.count,
            chunksCarriedWithoutVector: index.count - rebuilt.count,
            before: before, after: after, accepted: accepted, reason: reason)

        return (accepted ? candidate : index, report)
    }
}

/// Stands in for "there is no previous embedder" so `migrate` can keep a
/// concrete generic parameter instead of an existential.
public struct NeverEmbedder: Embedder {
    public let identifier = "none"
    public let profile = EmbeddingProfile(modelID: "none", revision: "none", dimensions: 0)
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        throw EmbeddingError.empty
    }
}
