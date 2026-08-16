import Testing
import Foundation
import AgentKit
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// A field added to a table that already has rows in it.
//
// Found by driving the real app, not by a test: every message typed into a
// conversation created before `pinned` existed failed to save, and what the
// screen said was
//
//   บันทึกข้อความไม่สำเร็จ: Couldn't coerce value for field `pinned`
//   of `conversation:…`: Expected `bool` but found `NONE`
//
// `DEFINE FIELD … TYPE bool DEFAULT false` reads like it handles this and does
// not: **`DEFAULT` fills a value in when a row is created, and an old row was
// created already.** So the field is `NONE` on every pre-existing row, and the
// coercion runs on the *next update of that row* — which is any update, not
// just one that touches `pinned`. The failure therefore lands nowhere near the
// change that caused it, on a machine that has been running the app for a
// while, and never on a fresh install or in CI.
//
// The rule this pins down is that **defining a non-optional field is only half
// of adding one**; the other half is filling it in on the rows that are already
// there. Two tests, because both halves fail independently: one for the old
// row, one for the new row that must not depend on `DEFAULT` semantics either.
// ─────────────────────────────────────────────────────────────

@Suite("Fields added to tables that already have rows", .serialized)
struct OldRowFieldTests {

    /// A row as it existed before the field was defined. Reproduced by removing
    /// the field, writing the row, and putting the field back — which is the
    /// order the real database went through, rather than an approximation of it.
    private func conversationFromBeforeTheField(_ server: TestServer) async throws -> String {
        let client = await server.client
        try await client.exec("REMOVE FIELD IF EXISTS pinned ON conversation")
        let store = ConversationStore(client: client)
        let conversation = try await store.create(scope: .central, title: "ก่อนจะมีการปักหมุด")
        try await client.exec("DEFINE FIELD IF NOT EXISTS pinned ON conversation TYPE bool DEFAULT false")
        return conversation.id
    }

    @Test("a message can still be saved into a conversation older than the pinned field",
          .timeLimit(.minutes(3)))
    func appendIntoPreExistingConversation() async throws {
        guard let server = try await makeServer(port: 18_730) else { return }
        defer { Task { await server.shutdown() } }
        let id = try await conversationFromBeforeTheField(server)

        // Backfill is what `bootstrap` owes an existing database. Applying the
        // schema again is exactly what happens on the next launch, so the fix
        // has to live there and not in a script somebody remembers to run.
        try await server.client.bootstrap(user: "root", password: "root")

        let store = ConversationStore(client: await server.client)
        // The append does not mention `pinned` at all — it updates `updated_at`.
        // That is the point: the coercion runs over the whole row.
        let message = try await store.append(conversationID: id, role: .user,
                                             content: "ยาปฏิชีวนะก่อนผ่าตัดให้ก่อนลงมีดกี่นาที")
        #expect(message.content.contains("ยาปฏิชีวนะ"))

        let stored = try await store.history(conversationID: id)
        #expect(stored.count == 1, "ข้อความหายไป — บันทึกไม่ผ่านการ coerce ของฟิลด์ที่แถวเก่าไม่มี")
    }

    @Test("an old conversation still sorts and reads back, and is not pinned",
          .timeLimit(.minutes(3)))
    func listIncludesPreExistingConversation() async throws {
        guard let server = try await makeServer(port: 18_731) else { return }
        defer { Task { await server.shutdown() } }
        let id = try await conversationFromBeforeTheField(server)
        try await server.client.bootstrap(user: "root", password: "root")

        let store = ConversationStore(client: await server.client)
        // `ORDER BY pinned DESC` over a column that is NONE on some rows is the
        // second way this shows up, and a quieter one: no error, just an order
        // nobody can explain.
        let listed = try await store.list(scope: .central)
        let old = listed.first { $0.id == id }
        #expect(old != nil, "บทสนทนาเก่าหายไปจากรายการ")
        #expect(old?.pinned == false, "แถวเก่าต้องอ่านได้ว่า 'ไม่ได้ปักหมุด' ไม่ใช่ค่าว่าง")

        // And it can still be pinned afterwards, which is the write that reads
        // the old value before setting the new one.
        try await store.setPinned(id, true)
        let after = try await store.list(scope: .central).first { $0.id == id }
        #expect(after?.pinned == true)
    }

    @Test("a newly created conversation carries the field itself, not by DEFAULT",
          .timeLimit(.minutes(3)))
    func createWritesTheFieldExplicitly() async throws {
        guard let server = try await makeServer(port: 18_732) else { return }
        defer { Task { await server.shutdown() } }
        let client = await server.client
        let store = ConversationStore(client: client)
        let conversation = try await store.create(scope: .central, title: "ใหม่")

        // Read the raw row rather than the decoded value: the decoder defaults
        // a missing `pinned` to false, so asking it would pass either way and
        // prove nothing about what is on disk.
        let rows = try await client.query(
            "SELECT pinned FROM conversation WHERE uid = type::string($id)",
            vars: ["id": conversation.id])
        let value = rows.first?.rows.first?["pinned"]
        #expect(value?.boolValue == false,
                "แถวใหม่ต้องมีค่า pinned จริงในฐานข้อมูล ไม่ใช่พึ่ง DEFAULT ของสคีมา")
    }
}
