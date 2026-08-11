import Foundation

// ─────────────────────────────────────────────────────────────
// Lexical half of hybrid search (ARCHITECTURE §11, P2.4 fuses it with the
// vector half). It lives here in P2.2 because it is how the merge layer is
// measured rather than asserted: retrieval quality is the only thing that
// makes a tokenizer better or worse.
// ─────────────────────────────────────────────────────────────

public struct ScoredDocument: Sendable, Equatable {
    public let id: String
    public let score: Double
}

public struct BM25Index: Sendable {
    // Okapi BM25 defaults; b=0.75 keeps length normalisation on, which matters
    // because chunks vary from a one-line policy rule to a full paragraph.
    private let k1 = 1.2
    private let b = 0.75

    private let tokenizer: Tokenizer
    private var documents: [(id: String, terms: [String], length: Double)] = []
    private var documentFrequency: [String: Int] = [:]
    private var averageLength: Double = 0

    public init(tokenizer: Tokenizer = Tokenizer()) {
        self.tokenizer = tokenizer
    }

    public var count: Int { documents.count }

    public mutating func index(id: String, text: String) {
        let terms = tokenizer.tokens(text)
        documents.append((id: id, terms: terms, length: Double(terms.count)))
        for term in Set(terms) { documentFrequency[term, default: 0] += 1 }
        averageLength = documents.reduce(0) { $0 + $1.length } / Double(documents.count)
    }

    /// Highest scoring first. Documents that match nothing are left out rather
    /// than returned with a zero — a caller ranking an empty match would be
    /// showing noise as a result.
    public func search(_ query: String, limit: Int = 10) -> [ScoredDocument] {
        let queryTerms = tokenizer.tokens(query)
        guard !queryTerms.isEmpty, !documents.isEmpty else { return [] }

        return documents.map { document in
            var score = 0.0
            for term in Set(queryTerms) {
                let frequency = Double(document.terms.filter { $0 == term }.count)
                guard frequency > 0 else { continue }
                let n = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (Double(documents.count) - n + 0.5) / (n + 0.5))
                let norm = frequency + k1 * (1 - b + b * document.length / averageLength)
                score += idf * (frequency * (k1 + 1)) / norm
            }
            return ScoredDocument(id: document.id, score: score)
        }
        .filter { $0.score > 0 }
        .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }
}
