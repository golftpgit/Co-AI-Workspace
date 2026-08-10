import Foundation
import NaturalLanguage

// ─────────────────────────────────────────────────────────────
// Splitting a document into what actually gets embedded and indexed
// (ARCHITECTURE §11, P2.2).
//
// Two rules decide everything here:
//  • a chunk never cuts a sentence in half — a fragment retrieves badly and
//    reads worse when it is quoted back as evidence;
//  • chunks overlap, so a fact that straddles a boundary is still whole in one
//    of them.
// ─────────────────────────────────────────────────────────────

public struct Chunk: Sendable, Equatable {
    public let index: Int
    public let text: String
    /// Token count under the same tokenizer the index uses, so budgets here and
    /// scores there are talking about the same units.
    public let tokenCount: Int

    public init(index: Int, text: String, tokenCount: Int) {
        self.index = index
        self.text = text
        self.tokenCount = tokenCount
    }
}

public struct Chunker: Sendable {
    /// Bump whenever boundaries change. Chunk ids are derived from position, so
    /// a different split renames every chunk — which orphans the entity/relation
    /// graph and every citation anchored to one. Recorded in
    /// `EmbeddingProfile` so an index can refuse to mix the two.
    public static let version = 1

    public let maxTokens: Int
    public let overlapTokens: Int
    private let tokenizer: Tokenizer

    public init(maxTokens: Int = 320, overlapTokens: Int = 48,
                tokenizer: Tokenizer = Tokenizer()) {
        precondition(overlapTokens < maxTokens, "overlap must leave room to advance")
        self.maxTokens = maxTokens
        self.overlapTokens = overlapTokens
        self.tokenizer = tokenizer
    }

    public func chunks(of text: String) -> [Chunk] {
        let sentences = self.sentences(in: text)
        guard !sentences.isEmpty else { return [] }

        var chunks: [Chunk] = []
        var current: [(text: String, tokens: Int)] = []
        var currentTokens = 0

        func flush() {
            guard !current.isEmpty else { return }
            let body = current.map(\.text).joined(separator: " ")
            chunks.append(Chunk(index: chunks.count, text: body, tokenCount: currentTokens))
        }

        for sentence in sentences {
            let tokens = tokenizer.tokens(sentence).count
            // A single sentence over budget is kept whole and over budget: the
            // alternative is cutting mid-thought, and the embedder truncating
            // its tail is the lesser damage.
            if currentTokens + tokens > maxTokens, !current.isEmpty {
                flush()
                current = tail(of: current)
                currentTokens = current.reduce(0) { $0 + $1.tokens }
            }
            current.append((text: sentence, tokens: tokens))
            currentTokens += tokens
        }
        flush()
        return chunks
    }

    /// The sentences carried into the next chunk as overlap, newest last.
    /// Best-effort: a sentence longer than the overlap budget is not carried,
    /// because the only way to carry part of it is to cut it.
    private func tail(of sentences: [(text: String, tokens: Int)]) -> [(text: String, tokens: Int)] {
        var carried: [(text: String, tokens: Int)] = []
        var total = 0
        for sentence in sentences.reversed() {
            if total + sentence.tokens > overlapTokens { break }
            carried.insert(sentence, at: 0)
            total += sentence.tokens
        }
        return carried
    }

    private func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }
}
