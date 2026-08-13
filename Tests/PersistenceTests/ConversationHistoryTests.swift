import Testing
import Foundation
import AgentKit
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// The conversation history (ARCHITECTURE §19.2.1, P10.14).
//
// The requirement that decides the implementation is Thai search. Thai does not
// put spaces between words, so `CONTAINS` finds either everything or nothing —
// which is why this uses the same BM25 and the same tokenizer as the knowledge
// base rather than a LIKE query that would have looked fine in English.
// ─────────────────────────────────────────────────────────────

@Suite("Conversation history", .serialized)
struct ConversationHistoryTests {

    private func seed(_ store: ConversationStore, scope: Scope,
                      title: String, lines: [String]) async throws -> Conversation {
        let conversation = try await store.create(scope: scope, title: title)
        for (index, line) in lines.enumerated() {
            try await store.append(conversationID: conversation.id,
                                   role: index.isMultiple(of: 2) ? .user : .assistant,
                                   content: line)
        }
        return conversation
    }

    @Test("Thai words are found inside a sentence with no spaces around them",
          .timeLimit(.minutes(3)))
    func thaiSearchFindsWords() async throws {
        guard let server = try await makeServer(port: 18_631) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConversationStore(client: await server.client)

        let burnout = try await seed(store, scope: .central, title: "แบบวัด",
                                     lines: ["แบบวัดภาวะหมดไฟฉบับแปลไทยมีตัวไหนบ้าง",
                                             "พบสามฉบับ MBI CBI และ OLBI"])
        _ = try await seed(store, scope: .central, title: "อย่างอื่น",
                           lines: ["ช่วยดูสถิติของการคัดกรองเบาหวานหน่อย"])

        let hits = try await store.search("ภาวะหมดไฟ", scope: .central)
        #expect(hits.count == 1)
        #expect(hits.first?.conversation.id == burnout.id)
        // The snippet is what makes the result answer "where did I say that"
        // rather than "which conversations exist".
        #expect(hits.first?.snippet.contains("ภาวะหมดไฟ") == true)
    }

    @Test("a conversation with five matching messages is still one result",
          .timeLimit(.minutes(3)))
    func oneResultPerConversation() async throws {
        guard let server = try await makeServer(port: 18_632) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConversationStore(client: await server.client)

        _ = try await seed(store, scope: .central, title: "ซ้ำ ๆ",
                           lines: Array(repeating: "เรื่องภาวะหมดไฟอีกครั้ง", count: 5))

        #expect(try await store.search("ภาวะหมดไฟ", scope: .central).count == 1)
    }

    @Test("search stays inside the project unless asked to cross",
          .timeLimit(.minutes(3)))
    func scopedSearch() async throws {
        guard let server = try await makeServer(port: 18_633) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConversationStore(client: await server.client)
        let project = Scope.project(ProjectID("pj_hist"))

        _ = try await seed(store, scope: project, title: "ในโปรเจกต์",
                           lines: ["ผลความเที่ยงของมาตรวัดออกมาแล้ว"])
        _ = try await seed(store, scope: .central, title: "ทั่วไป",
                           lines: ["ความเที่ยงของเครื่องมือวัดคืออะไร"])

        #expect(try await store.search("ความเที่ยง", scope: project).count == 1)
        // nil scope is the "ค้นข้ามโปรเจกต์" button, and it is a different
        // question rather than a wider default.
        #expect(try await store.search("ความเที่ยง", scope: nil).count == 2)
    }

    @Test("a pinned conversation stays at the top without being touched",
          .timeLimit(.minutes(3)))
    func pinningOutranksRecency() async throws {
        guard let server = try await makeServer(port: 18_634) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConversationStore(client: await server.client)

        let old = try await store.create(scope: .central, title: "เก่าแต่สำคัญ")
        try await store.setPinned(old.id, true)
        let recent = try await store.create(scope: .central, title: "เพิ่งคุย")
        try await store.append(conversationID: recent.id, role: .user, content: "ใหม่")

        let listed = try await store.list(scope: .central)
        #expect(listed.first?.id == old.id)
        #expect(listed.first?.pinned == true)
        // Pinning must not count as activity: a pin that reordered by touching
        // `updated_at` would be indistinguishable from replying.
        #expect(listed.map(\.id) == [old.id, recent.id])
    }

    @Test("an empty query returns nothing rather than everything",
          .timeLimit(.minutes(2)))
    func emptyQueryIsNotAWildcard() async throws {
        guard let server = try await makeServer(port: 18_635) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConversationStore(client: await server.client)
        _ = try await seed(store, scope: .central, title: "อะไรก็ได้", lines: ["ข้อความหนึ่ง"])

        #expect(try await store.search("   ", scope: .central).isEmpty)
    }
}
