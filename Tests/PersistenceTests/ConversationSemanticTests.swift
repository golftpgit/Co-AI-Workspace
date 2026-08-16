import Testing
import Foundation
import AgentKit
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// P10.14's outstanding item — conversation search was BM25 alone, so a search
// for "ยาปฏิชีวนะก่อนผ่าตัด" could not find the conversation somebody called
// "เตรียมผู้ป่วยก่อนเข้าห้องผ่าตัด".
//
// The fusion runs on vectors stored when a conversation gets its name — one
// embedding per conversation, not one per message. What that buys is finding a
// conversation by what it is about; what it cannot do is find a phrase buried
// in the middle of a long one, and the word search is what does that.
// ─────────────────────────────────────────────────────────────

private func conversation(_ id: String) -> Conversation {
    Conversation(id: id, title: id, scope: .central,
                 createdAt: Date(), updatedAt: Date())
}

private func match(_ id: String, score: Double) -> (id: String, match: ConversationMatch) {
    (id, ConversationMatch(conversation: conversation(id), snippet: "…", score: score))
}

@Suite("Conversation search, fused")
struct ConversationSemanticTests {

    private let byID = ["a": conversation("a"), "b": conversation("b"),
                        "c": conversation("c")]

    @Test("cosine is the same measure everywhere")
    func cosineIsOrdinary() {
        #expect(abs(ConversationStore.cosine([1, 0], [1, 0]) - 1) < 1e-9)
        #expect(abs(ConversationStore.cosine([1, 0], [0, 1])) < 1e-9)
        // Mismatched or empty vectors are not "perfectly similar".
        #expect(ConversationStore.cosine([1, 0], [1, 0, 0]) == 0)
        #expect(ConversationStore.cosine([], []) == 0)
    }

    /// The case the feature exists for: nothing was typed that matches, and the
    /// subject does.
    @Test("a conversation the words missed can be found by its subject")
    func semanticOnlyHitsAppear() {
        let fused = ConversationStore.fuse(
            lexical: [match("a", score: 3)],
            vectors: ["b": [1, 0]],
            queryVector: [1, 0],
            conversations: byID, limit: 10)

        #expect(fused.map(\.conversation.id).sorted() == ["a", "b"])
        // And it says how it was found, rather than quoting the first line as
        // though it were the hit.
        let subject = fused.first { $0.conversation.id == "b" }
        #expect(subject?.snippet.contains("ตรงกับเรื่องที่คุยกัน") == true)
    }

    @Test("a conversation both halves found outranks one that only one found")
    func agreementWins() {
        let fused = ConversationStore.fuse(
            lexical: [match("a", score: 1), match("b", score: 9)],
            vectors: ["a": [1, 0], "b": [0, 1]],
            queryVector: [1, 0],
            conversations: byID, limit: 10)
        // `a` is second on words and first on subject; `b` is first on words
        // and below the floor on subject. Fusion puts `a` on top.
        #expect(fused.first?.conversation.id == "a")
    }

    /// Every vector is a little like every other one, so a ranking with no
    /// floor is a list of every conversation in mildly arbitrary order.
    @Test("a weak similarity does not put a conversation in the results")
    func floorKeepsNoiseOut() {
        let fused = ConversationStore.fuse(
            lexical: [],
            vectors: ["b": [1, 0.2]],
            queryVector: [-1, 0.1],
            conversations: byID, limit: 10)
        #expect(fused.isEmpty)
    }

    @Test("with no vectors stored the ranking is exactly the word search")
    func noVectorsChangesNothing() {
        let lexical = [match("a", score: 3), match("b", score: 2), match("c", score: 1)]
        let fused = ConversationStore.fuse(lexical: lexical, vectors: [:],
                                           queryVector: [1, 0],
                                           conversations: byID, limit: 10)
        #expect(fused.map(\.conversation.id) == ["a", "b", "c"])
    }

    @Test("the fusion constant is the knowledge index's, not a second one")
    func oneFusionRule() {
        // Two rules for "how do a word search and a vector search combine"
        // drift, and the second one is the one nobody tuned.
        #expect(ConversationStore.rrfK == 60)
    }
}
