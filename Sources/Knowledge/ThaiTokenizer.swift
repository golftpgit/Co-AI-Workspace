import Foundation
import NaturalLanguage

// ─────────────────────────────────────────────────────────────
// Tokenisation for the whole knowledge base (ARCHITECTURE E.3, P2.2).
//
// One tokenizer, used for both indexing and querying — if the two ever differ
// the index silently stops matching. `NLTokenizer` does the segmentation and
// the dictionary merge layer repairs the loanwords it shatters.
// ─────────────────────────────────────────────────────────────

public struct Tokenizer: Sendable {
    /// Bump whenever segmentation changes: the terms in an index were produced
    /// by one version of this, and a query tokenised differently stops matching
    /// them. Recorded in `EmbeddingProfile`.
    public static let version = 1

    public let dictionary: TermDictionary
    /// Off only so tests can measure what the merge layer is worth.
    public let mergesDictionaryTerms: Bool

    public init(dictionary: TermDictionary = .seed, mergesDictionaryTerms: Bool = true) {
        self.dictionary = dictionary
        self.mergesDictionaryTerms = mergesDictionaryTerms
    }

    /// Index and query terms. Lower-cased, punctuation dropped; Thai and Latin
    /// text may be mixed inside one document and are handled in one pass.
    public func tokens(_ text: String) -> [String] {
        let ranges = merge(spans(of: text), in: text)
        return ranges.compactMap { range in
            let token = text[range]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return token.isEmpty ? nil : token
        }
    }

    // MARK: - segmentation

    private func spans(of text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        // Forcing Thai wins on the mixed Thai/English documents this system
        // actually holds: Latin words survive it, whereas letting the guess
        // land on English shreds every Thai sentence in a bilingual abstract.
        if text.unicodeScalars.contains(where: { (0x0E00...0x0E7F).contains($0.value) }) {
            tokenizer.setLanguage(.thai)
        }
        tokenizer.string = text

        var spans: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            spans.append(range)
            return true
        }
        return spans
    }

    // MARK: - merge layer

    /// Replaces every run of tokens that a dictionary term covers with the term
    /// itself. A term is only applied when its boundaries line up with token
    /// boundaries: a partial overlap means the segmenter read the surrounding
    /// text differently, and swallowing its neighbours would corrupt more than
    /// it fixes.
    private func merge(_ spans: [Range<String.Index>],
                       in text: String) -> [Range<String.Index>] {
        guard mergesDictionaryTerms, !spans.isEmpty else { return spans }
        let terms = dictionary.matches(in: text)
        guard !terms.isEmpty else { return spans }

        var merged: [Range<String.Index>] = []
        var index = 0
        while index < spans.count {
            let span = spans[index]
            guard let term = terms.first(where: { $0.lowerBound == span.lowerBound }),
                  let last = spans[index...].lastIndex(where: { $0.upperBound == term.upperBound })
            else {
                merged.append(span)
                index += 1
                continue
            }
            merged.append(term)
            index = last + 1
        }
        return merged
    }
}
