import Testing
import Foundation
import AgentKit
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// What the sidebar search returns on a conversation that has been used.
//
// The existing history tests seed two or three short lines and pass. Typing the
// same kind of Thai word into the real app returned the conversation with the
// snippet *"— ตรงกับเรื่องที่คุยกัน ไม่ใช่คำที่พิมพ์ —"* — the label the code
// uses for **found by subject, no matching sentence to quote** — even for words
// sitting verbatim in a stored message. The word search had produced nothing
// and the vector half was covering for it, which is the failure mode a fallback
// is supposed to prevent and also the one that hides it.
//
// The difference between the test corpus and the real one is not the language,
// it is the *shape*: a conversation somebody has actually used contains a few
// short lines and a lot of long ones. So that is what this seeds — the real
// messages next to the long filler that was really in there — because a search
// test whose corpus is three tidy sentences is a test of the tokenizer, not of
// the search.
// ─────────────────────────────────────────────────────────────

@Suite("Sidebar search over a used conversation", .serialized)
struct SearchOnRealCorpusTests {

    /// The long messages a real conversation accumulates. Same text repeated,
    /// which is what a summarised context turn actually looks like.
    private var filler: String {
        String(repeating: "รายละเอียดการทำงานรอบก่อนหน้าที่ยาวมากและไม่จำเป็นต้องอ่านซ้ำ ", count: 40)
    }

    private func seed(_ store: ConversationStore) async throws -> Conversation {
        let conversation = try await store.create(
            scope: .central, title: "ยาปฏิชีวนะก่อนผ่าตัดควรให้ก่อนลงมีดกี่นาที")
        _ = try await store.append(conversationID: conversation.id, role: .user,
                                   content: "ยาปฏิชีวนะก่อนผ่าตัดควรให้ก่อนลงมีดกี่นาที")
        for index in 0..<20 {
            _ = try await store.append(conversationID: conversation.id,
                                       role: index.isMultiple(of: 2) ? .user : .assistant,
                                       content: filler)
        }
        return conversation
    }

    @Test("a word that is in a message is quoted back, not answered with 'by subject'",
          .timeLimit(.minutes(4)))
    func lexicalHitSurvivesALongConversation() async throws {
        guard let server = try await makeServer(port: 18_733) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConversationStore(client: await server.client)
        let conversation = try await seed(store)

        // With a vector too, because that is how the app calls it — and the
        // vector half is exactly what was masking this.
        let vector = [Float](repeating: 0.1, count: 8)
        try await store.saveEmbedding(vector, for: conversation.id)

        let matches = try await store.search("ผ่าตัด", scope: .central, queryVector: vector)
        #expect(matches.count == 1)
        let snippet = matches.first?.snippet ?? ""
        #expect(snippet.contains("ผ่าตัด"),
                "ค้นเจอคำที่อยู่ในข้อความจริง แต่ไม่ได้ยกประโยคนั้นมา — ได้ “\(snippet)”")
    }

    @Test("a word that is nowhere finds nothing by words, and says so",
          .timeLimit(.minutes(4)))
    func absentWordIsNotAWordMatch() async throws {
        guard let server = try await makeServer(port: 18_734) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConversationStore(client: await server.client)
        _ = try await seed(store)

        // No vector: the word search alone must be able to say "no".
        let matches = try await store.search("หมดไฟ", scope: .central)
        #expect(matches.isEmpty, "คำที่ไม่มีอยู่จริงไม่ควรตรงกับอะไรเลยในการค้นด้วยคำ")
    }
}
