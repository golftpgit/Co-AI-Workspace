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

public struct IndexedChunk: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let scope: Scope
    /// Not optional, and there is no initialiser that omits it.
    public let provenance: Provenance
    public let embedding: [Float]?
    /// SHA-256 of the whitespace-normalised text — how re-ingesting the same
    /// document stays a no-op (P2.3).
    public let contentHash: String
    /// Which vector space `embedding` belongs to. Present exactly when the
    /// vector is: a vector that cannot name its model cannot be checked.
    public let embeddingProfileID: String?
    /// People, places and organisations named in this chunk (§11.4). Indexed
    /// alongside the text, so correcting one changes what the chunk answers —
    /// which is the point of letting a user edit them at all (P2.7).
    public let entities: [String]

    /// What BM25 actually sees.
    var searchableText: String {
        entities.isEmpty ? text : text + " " + entities.joined(separator: " ")
    }

    /// The same chunk with its vector dropped — for a row loaded from storage
    /// whose vector was built by a model this index does not use. The text is
    /// what a re-embed needs, and it is still searchable lexically meanwhile.
    public func withoutEmbedding() -> IndexedChunk {
        IndexedChunk(id: id, text: text, scope: scope, provenance: provenance,
                     embedding: nil, embeddingProfileID: nil,
                     contentHash: contentHash, entities: entities)
    }

    /// The same chunk with different entities. Everything the graph and
    /// citations point at — id, text, provenance, vector — is carried over.
    public func withEntities(_ entities: [String]) -> IndexedChunk {
        IndexedChunk(id: id, text: text, scope: scope, provenance: provenance,
                     embedding: embedding, embeddingProfileID: embeddingProfileID,
                     contentHash: contentHash, entities: entities)
    }

    public init(id: String, text: String, scope: Scope,
                provenance: Provenance, embedding: [Float]? = nil,
                embeddingProfileID: String? = nil,
                contentHash: String? = nil, entities: [String] = []) {
        self.id = id
        self.text = text
        self.scope = scope
        self.provenance = provenance
        self.embedding = embedding
        self.embeddingProfileID = embeddingProfileID
        self.contentHash = contentHash ?? IngestionPipeline.contentHash(text)
        self.entities = entities
    }
}

/// A document as the knowledge base list shows it (§14.2).
public struct DocumentSummary: Sendable, Equatable, Identifiable {
    public let documentID: String
    public let title: String
    public let tier: SourceTier?
    public let origin: Origin
    public let scope: Scope
    public let chunkCount: Int
    public let entities: [String]
    /// False when the document was indexed with no embedder available — the
    /// list says so rather than letting the user wonder why search is weaker.
    public let hasVectors: Bool

    public var id: String { documentID }
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

    /// Public so anything that reviews retrieved results — the conflict
    /// detector, a future re-ranker — can build one without going through a
    /// search.
    public init(chunk: IndexedChunk, score: Double,
                lexicalRank: Int?, semanticRank: Int?) {
        self.chunk = chunk
        self.score = score
        self.lexicalRank = lexicalRank
        self.semanticRank = semanticRank
    }
}

public struct KnowledgeIndex: Sendable {
    /// RRF's smoothing constant. 60 is the value from the original paper and
    /// what the spike measured with; it decides how much a top-1 hit in one
    /// list outweighs a mid-list hit in the other.
    private let rrfK: Double
    private let tokenizer: Tokenizer
    private var chunks: [IndexedChunk] = []

    /// How close a chunk has to sit to the question before the vector half is
    /// allowed to answer with it.
    ///
    /// Cosine similarity has no natural zero: bge-m3 scores two unrelated Thai
    /// passages around 0.38 and two related ones around 0.76 (ARCH E.10), so a
    /// filter at zero admits everything. Without a line between them there is
    /// no "not found" — every query returns whatever is nearest, and a library
    /// holding one document answers every question with that document.
    ///
    /// Set below the midpoint because the cost is asymmetric: a weak hit the
    /// user can dismiss beats a real one silently withheld, and cross-lingual
    /// pairs (Thai question, English source) sit lower than same-language ones.
    ///
    /// A number measured on one model, so it travels with the index rather than
    /// being a constant every embedder is held to: a different model spreads
    /// its scores differently, and 0.50 means nothing to it.
    public static let bgeM3SemanticFloor = 0.50

    public let minimumSemanticSimilarity: Double

    /// What this index's vectors mean. `nil` is a lexical-only index — legal,
    /// and the state a machine with no embedding runtime works in — but it can
    /// never hold a vector, because a vector with no profile is unverifiable.
    public let profile: EmbeddingProfile?

    public init(profile: EmbeddingProfile? = nil,
                tokenizer: Tokenizer = Tokenizer(), rrfK: Double = 60,
                minimumSemanticSimilarity: Double = KnowledgeIndex.bgeM3SemanticFloor) {
        self.profile = profile
        self.tokenizer = tokenizer
        self.rrfK = rrfK
        self.minimumSemanticSimilarity = minimumSemanticSimilarity
    }

    public var count: Int { chunks.count }

    /// The stored text and provenance — the part of the knowledge base that is
    /// the source of truth rather than derived. A rebuild reads this and never
    /// the original documents (P2.8).
    public var allChunks: [IndexedChunk] { chunks }

    /// Throws rather than dropping the vector: an index that quietly accepts a
    /// chunk without its vector looks healthy and answers worse, which is the
    /// failure mode this whole file exists to prevent.
    public mutating func insert(_ chunk: IndexedChunk) throws {
        if chunk.embedding != nil {
            guard let indexProfile = profile else {
                throw IndexProfileError.lexicalIndexCannotHoldVectors
            }
            guard let chunkProfile = chunk.embeddingProfileID else {
                throw IndexProfileError.vectorWithoutProfile
            }
            guard chunkProfile == indexProfile.id else {
                throw IndexProfileError.foreignVector(indexProfile: indexProfile.id,
                                                      chunkProfile: chunkProfile)
            }
        }
        chunks.append(chunk)
    }

    public mutating func insert(contentsOf newChunks: [IndexedChunk]) throws {
        for chunk in newChunks { try insert(chunk) }
    }

    /// Corrects the entities on a chunk. Returns false when the chunk is gone,
    /// so a UI editing a stale row finds out rather than silently doing nothing.
    @discardableResult
    public mutating func updateEntities(of chunkID: String, to entities: [String]) -> Bool {
        guard let position = chunks.firstIndex(where: { $0.id == chunkID }) else { return false }
        chunks[position] = chunks[position].withEntities(entities)
        return true
    }

    /// Removes a whole document. Chunk-level deletion is deliberately not
    /// offered: half a document in the index is a citation that leads nowhere.
    @discardableResult
    public mutating func removeDocument(_ documentID: String) -> Int {
        let before = chunks.count
        chunks.removeAll { $0.provenance.documentID == documentID }
        return before - chunks.count
    }

    /// One row per ingested document, for the knowledge base list (§14.2).
    public func documents(in scope: Scope? = nil) -> [DocumentSummary] {
        let visible = scope.map { s in chunks.filter { $0.scope == s } } ?? chunks
        return Dictionary(grouping: visible, by: { $0.provenance.documentID })
            .map { id, chunks in
                DocumentSummary(
                    documentID: id,
                    title: chunks[0].provenance.title,
                    tier: chunks[0].provenance.tier,
                    origin: chunks[0].provenance.origin,
                    scope: chunks[0].scope,
                    chunkCount: chunks.count,
                    entities: Array(Set(chunks.flatMap(\.entities))).sorted(),
                    hasVectors: chunks.contains { $0.embedding != nil })
            }
            .sorted { $0.title < $1.title }
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
        // The query side of the same invariant: a question embedded by another
        // model lands somewhere else in space, and the nearest neighbours it
        // finds are arbitrary.
        guard let indexProfile = profile else {
            throw IndexProfileError.lexicalIndexCannotHoldVectors
        }
        guard embedder.profile.id == indexProfile.id else {
            throw IndexProfileError.queriedWithAnotherModel(indexProfile: indexProfile.id,
                                                            queryProfile: embedder.profile.id)
        }

        let visible = chunks.filter { $0.scope == scope }
        guard !visible.isEmpty else { return [] }

        let lexical = rankLexically(query, in: visible)
        let queryVector = try await embedder.embed(query)
        let semantic = rankSemantically(queryVector, in: visible,
                                        floor: minimumSemanticSimilarity)

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

    /// Vector half alone. Not for serving — fused results are better — but a
    /// broken embedding model is invisible in a fused ranking that BM25 is
    /// carrying, so anything checking the model's health has to look here
    /// (P2.8's reindex gate).
    public func searchSemantically(_ query: String, scope: Scope, embedder: some Embedder,
                                   limit: Int = 10) async throws -> [SearchResult] {
        guard let indexProfile = profile else {
            throw IndexProfileError.lexicalIndexCannotHoldVectors
        }
        guard embedder.profile.id == indexProfile.id else {
            throw IndexProfileError.queriedWithAnotherModel(indexProfile: indexProfile.id,
                                                            queryProfile: embedder.profile.id)
        }
        let visible = chunks.filter { $0.scope == scope }
        let queryVector = try await embedder.embed(query)
        // No floor here on purpose: this exists to inspect the model, and a
        // health check that cannot see weak scores cannot tell a broken model
        // from an empty library.
        return rankSemantically(queryVector, in: visible, floor: 0)
            .prefix(limit).enumerated().map {
            SearchResult(chunk: $1.chunk, score: $1.score,
                         lexicalRank: nil, semanticRank: $0 + 1)
        }
    }

    // MARK: - the two halves

    private func rankLexically(_ query: String,
                               in visible: [IndexedChunk]) -> [(chunk: IndexedChunk, score: Double)] {
        var index = BM25Index(tokenizer: tokenizer)
        for chunk in visible { index.index(id: chunk.id, text: chunk.searchableText) }

        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        return index.search(query, limit: visible.count).compactMap { scored in
            byID[scored.id].map { (chunk: $0, score: scored.score) }
        }
    }

    private func rankSemantically(_ queryVector: [Float], in visible: [IndexedChunk],
                                  floor: Double) -> [(chunk: IndexedChunk, score: Double)] {
        visible
            .compactMap { chunk -> (chunk: IndexedChunk, score: Double)? in
                guard let embedding = chunk.embedding else { return nil }
                return (chunk: chunk, score: cosineSimilarity(queryVector, embedding))
            }
            .filter { $0.score >= floor }
            .sorted { $0.score == $1.score ? $0.chunk.id < $1.chunk.id : $0.score > $1.score }
    }
}
