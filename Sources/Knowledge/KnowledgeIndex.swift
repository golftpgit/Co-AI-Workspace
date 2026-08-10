import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Hybrid search: BM25 + vector, fused with RRF (ARCHITECTURE §11, P2.4).
//
// Fusion happens here rather than in SurrealQL — proved out in the spike and
// kept deliberately: the database returns two ranked lists, the app decides how
// to combine them, and that decision stays testable without a database.
//
// Two invariants the type system carries rather than the caller:
//  • every indexed chunk has provenance (P2.5), so every result can be cited;
//  • every query is scoped, so central / project / policy knowledge cannot
//    leak into each other.
// ─────────────────────────────────────────────────────────────

public struct IndexedChunk: Sendable, Equatable {
    public let id: String
    public let text: String
    public let scope: Scope
    /// Not optional, and there is no initialiser that omits it.
    public let provenance: Provenance
    public let embedding: [Float]?
    /// SHA-256 of the whitespace-normalised text — how re-ingesting the same
    /// document stays a no-op (P2.3).
    public let contentHash: String
    /// People, places and organisations named in this chunk (§11.4).
    public let entities: [String]

    public init(id: String, text: String, scope: Scope,
                provenance: Provenance, embedding: [Float]? = nil,
                contentHash: String? = nil, entities: [String] = []) {
        self.id = id
        self.text = text
        self.scope = scope
        self.provenance = provenance
        self.embedding = embedding
        self.contentHash = contentHash ?? IngestionPipeline.contentHash(text)
        self.entities = entities
    }
}

public struct SearchResult: Sendable, Equatable {
    public let chunk: IndexedChunk
    public let score: Double
    /// What each half contributed, so a surprising ranking can be explained
    /// instead of argued about.
    public let lexicalRank: Int?
    public let semanticRank: Int?

    public var provenance: Provenance { chunk.provenance }
    public var tier: SourceTier? { chunk.provenance.tier }
}

public struct KnowledgeIndex: Sendable {
    /// RRF's smoothing constant. 60 is the value from the original paper and
    /// what the spike measured with; it decides how much a top-1 hit in one
    /// list outweighs a mid-list hit in the other.
    private let rrfK: Double
    private let tokenizer: Tokenizer
    private var chunks: [IndexedChunk] = []

    public init(tokenizer: Tokenizer = Tokenizer(), rrfK: Double = 60) {
        self.tokenizer = tokenizer
        self.rrfK = rrfK
    }

    public var count: Int { chunks.count }

    public mutating func insert(_ chunk: IndexedChunk) {
        chunks.append(chunk)
    }

    public mutating func insert(contentsOf newChunks: [IndexedChunk]) {
        chunks.append(contentsOf: newChunks)
    }

    /// Exact-duplicate check, scope-independent on purpose: the same passage
    /// filed under two scopes is two rows because they are answerable in
    /// different contexts, but the same passage arriving twice into the same
    /// index is one.
    public func contains(contentHash: String) -> Bool {
        chunks.contains { $0.contentHash == contentHash }
    }

    /// The re-scan case: same passage, different OCR noise, so the hash misses
    /// it. Compared only within a scope, since crossing scopes is a leak.
    public func containsNearDuplicate(of embedding: [Float], scope: Scope,
                                      threshold: Double) -> Bool {
        chunks.contains { chunk in
            guard chunk.scope == scope, let existing = chunk.embedding else { return false }
            return cosineSimilarity(existing, embedding) >= threshold
        }
    }

    /// Lexical only — for callers with no embedder available, and the path the
    /// system falls back to when the embedding endpoint is down.
    public func search(_ query: String, scope: Scope, limit: Int = 10) -> [SearchResult] {
        let visible = chunks.filter { $0.scope == scope }
        let lexical = rankLexically(query, in: visible)
        return lexical.prefix(limit).enumerated().map { index, entry in
            SearchResult(chunk: entry.chunk, score: entry.score,
                         lexicalRank: index + 1, semanticRank: nil)
        }
    }

    /// The real thing: both halves, fused. A chunk with no embedding still
    /// competes on the lexical side rather than disappearing.
    public func search(_ query: String, scope: Scope, embedder: some Embedder,
                       limit: Int = 10) async throws -> [SearchResult] {
        let visible = chunks.filter { $0.scope == scope }
        guard !visible.isEmpty else { return [] }

        let lexical = rankLexically(query, in: visible)
        let queryVector = try await embedder.embed(query)
        let semantic = rankSemantically(queryVector, in: visible)

        var fused: [String: (chunk: IndexedChunk, score: Double, lex: Int?, sem: Int?)] = [:]
        for (index, entry) in lexical.enumerated() {
            let rank = index + 1
            fused[entry.chunk.id] = (entry.chunk, 1 / (rrfK + Double(rank)), rank, nil)
        }
        for (index, entry) in semantic.enumerated() {
            let rank = index + 1
            let contribution = 1 / (rrfK + Double(rank))
            if let existing = fused[entry.chunk.id] {
                fused[entry.chunk.id] = (existing.chunk, existing.score + contribution,
                                         existing.lex, rank)
            } else {
                fused[entry.chunk.id] = (entry.chunk, contribution, nil, rank)
            }
        }

        return fused.values
            .sorted { $0.score == $1.score ? $0.chunk.id < $1.chunk.id : $0.score > $1.score }
            .prefix(limit)
            .map { SearchResult(chunk: $0.chunk, score: $0.score,
                                lexicalRank: $0.lex, semanticRank: $0.sem) }
    }

    // MARK: - the two halves

    private func rankLexically(_ query: String,
                               in visible: [IndexedChunk]) -> [(chunk: IndexedChunk, score: Double)] {
        var index = BM25Index(tokenizer: tokenizer)
        for chunk in visible { index.index(id: chunk.id, text: chunk.text) }

        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        return index.search(query, limit: visible.count).compactMap { scored in
            byID[scored.id].map { (chunk: $0, score: scored.score) }
        }
    }

    private func rankSemantically(_ queryVector: [Float],
                                  in visible: [IndexedChunk]) -> [(chunk: IndexedChunk, score: Double)] {
        visible
            .compactMap { chunk -> (chunk: IndexedChunk, score: Double)? in
                guard let embedding = chunk.embedding else { return nil }
                return (chunk: chunk, score: cosineSimilarity(queryVector, embedding))
            }
            .filter { $0.score > 0 }
            .sorted { $0.score == $1.score ? $0.chunk.id < $1.chunk.id : $0.score > $1.score }
    }
}
