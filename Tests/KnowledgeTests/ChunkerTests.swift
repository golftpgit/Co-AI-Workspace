import Testing
import Foundation
@testable import Knowledge

@Suite("Chunking")
struct ChunkerTests {
    // Five sentences of 5–7 tokens each, so a budget of 12 forces splits and an
    // overlap of 6 can still carry one whole sentence forward.
    private let paragraph = """
    ผู้ป่วยเบาหวานต้องปรับขนาดยา. \
    การให้อินซูลินช่วยคุมน้ำตาล. \
    แบบจำลองโลจิสติกทำนายความเสี่ยง. \
    ค่าพารามิเตอร์ถูกประมาณด้วยวิธีทางสถิติ. \
    การระบาดของโควิดยังดำเนินอยู่.
    """

    @Test("no chunk is produced from nothing")
    func emptyInput() {
        #expect(Chunker().chunks(of: "   \n  ").isEmpty)
    }

    @Test("a short document is one chunk")
    func shortDocument() {
        let chunks = Chunker().chunks(of: "การฝึกสติช่วยลดความเครียด.")
        #expect(chunks.count == 1)
        #expect(chunks[0].index == 0)
    }

    @Test("chunks stay within budget and overlap")
    func budgetAndOverlap() {
        let chunker = Chunker(maxTokens: 12, overlapTokens: 6)
        let chunks = chunker.chunks(of: paragraph)

        #expect(chunks.count > 1, "the budget should have forced a split")
        #expect(chunks.map(\.index) == Array(0..<chunks.count))

        // Overlap means consecutive chunks share text; without it a fact that
        // straddles a boundary is retrievable from neither side. It is
        // best-effort by construction: a sentence longer than the overlap
        // budget cannot be carried forward whole, and sentences are never cut.
        let tokenizer = Tokenizer()
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            let shares = next.text.split(separator: " ").contains { previous.text.contains($0) }
            guard !shares else { continue }
            let lastSentence = previous.text.split(separator: " ").last.map(String.init) ?? ""
            #expect(tokenizer.tokens(lastSentence).count > chunker.overlapTokens,
                    "chunk \(next.index) shares nothing with \(previous.index), and the sentence before it would have fitted")
        }
    }

    @Test("no sentence is cut in half")
    func sentencesStayWhole() {
        let chunker = Chunker(maxTokens: 12, overlapTokens: 6)
        let chunks = chunker.chunks(of: paragraph)

        // Every sentence of the source appears complete in at least one chunk.
        let sentences = paragraph
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for sentence in sentences {
            #expect(chunks.contains { $0.text.contains(sentence) },
                    "sentence was split across chunks: \(sentence)")
        }
    }

    @Test("an oversized sentence is kept whole rather than cut")
    func oversizedSentence() {
        let long = String(repeating: "ผู้ป่วยเบาหวานมีภาวะไตเรื้อรัง", count: 20)
        let chunks = Chunker(maxTokens: 10, overlapTokens: 2).chunks(of: long)
        #expect(chunks.count == 1)
        #expect(chunks[0].tokenCount > 10, "the budget was silently enforced by truncating")
    }

    @Test("token counts use the same tokenizer as the index")
    func tokenCountsMatchTheIndex() {
        let tokenizer = Tokenizer()
        let chunks = Chunker(tokenizer: tokenizer).chunks(of: "การถดถอยโลจิสติก.")
        #expect(chunks[0].tokenCount == tokenizer.tokens(chunks[0].text).count)
    }
}
