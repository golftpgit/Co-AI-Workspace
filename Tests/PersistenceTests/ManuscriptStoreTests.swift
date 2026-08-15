import Testing
import Foundation
import AgentKit
import DocGen
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// The manuscript against a real SurrealDB (ARCHITECTURE §20.8, P11.9).
//
// Against a real one rather than a fake because the thing most likely to be
// wrong here is not the logic. §20.8's whole promise is about time passing —
// a number bound in March still points at the right cell in April — and a
// store that silently loses the binding is a promise broken in exactly the
// case nobody tests by hand.
// ─────────────────────────────────────────────────────────────

private func draft(title: String, project: String = "burnout") -> Manuscript {
    var manuscript = Manuscript(scope: .project(ProjectID(project)), title: title,
                                authors: ["พนุพงศ์ ต."])
    let reference = ResultReference(notebookID: "nb1", cellID: "c1", column: "mean_age",
                                    row: 0, label: "ค่าเฉลี่ยอายุ")
    manuscript.sections[.results] = [
        ManuscriptSection(heading: "4.1 ลักษณะของกลุ่มตัวอย่าง",
                          prose: ["กลุ่มตัวอย่างเป็นพยาบาลวิชาชีพ"],
                          reported: [ReportedSentence("อายุเฉลี่ยเท่ากับ {ค่าเฉลี่ยอายุ} ปี",
                                                      references: [reference])]),
    ]
    return manuscript
}

@Suite("Manuscript store", .serialized)
struct ManuscriptStoreTests {

    // The binding is the manuscript. A round trip that keeps the prose and
    // loses which cell the number came from would look fine on screen and be
    // the exact failure §20.8 exists to prevent.
    @Test("a saved manuscript comes back with its result bindings intact",
          .timeLimit(.minutes(2)))
    func bindingsSurvive() async throws {
        guard let server = try await makeServer(port: 18_661) else { return }
        defer { Task { await server.shutdown() } }
        let store = ManuscriptStore(client: await server.client)

        let manuscript = draft(title: "ภาวะหมดไฟในพยาบาล")
        try await store.save(manuscript)

        let loaded = try await store.load(scope: .project(ProjectID("burnout")))
        let restored = try #require(loaded.first?.manuscript)
        #expect(restored.id == manuscript.id)
        #expect(restored.title == "ภาวะหมดไฟในพยาบาล")

        let reference = try #require(restored.references.first)
        #expect(reference.cellID == "c1")
        #expect(reference.column == "mean_age")
        #expect(reference.label == "ค่าเฉลี่ยอายุ")
        // And the sentence still has the slot the number goes into.
        #expect(restored.sections[.results]?.first?.reported.first?.text
            .contains("{ค่าเฉลี่ยอายุ}") == true)
    }

    // Somebody else's thesis appearing in this project's list is worse than an
    // empty list — §19.1's rule, and the reason there is no fallback to General.
    @Test("a manuscript belongs to its project and does not leak into another",
          .timeLimit(.minutes(2)))
    func scopedToItsProject() async throws {
        guard let server = try await makeServer(port: 18_662) else { return }
        defer { Task { await server.shutdown() } }
        let store = ManuscriptStore(client: await server.client)

        try await store.save(draft(title: "เล่มของโครงการ ก", project: "alpha"))
        try await store.save(draft(title: "เล่มของโครงการ ข", project: "beta"))

        let alpha = try await store.load(scope: .project(ProjectID("alpha")))
        #expect(alpha.count == 1)
        #expect(alpha.first?.manuscript.title == "เล่มของโครงการ ก")
        #expect(try await store.load(scope: .central).isEmpty)
    }

    // Saving twice is what an editor does on every keystroke-ish change, so it
    // has to update rather than accumulate drafts.
    @Test("saving the same manuscript again replaces it rather than adding a second",
          .timeLimit(.minutes(2)))
    func saveIsAnUpsert() async throws {
        guard let server = try await makeServer(port: 18_663) else { return }
        defer { Task { await server.shutdown() } }
        let store = ManuscriptStore(client: await server.client)

        var manuscript = draft(title: "ร่างแรก")
        try await store.save(manuscript)
        manuscript.title = "ร่างที่แก้แล้ว"
        try await store.save(manuscript)

        let loaded = try await store.load(scope: .project(ProjectID("burnout")))
        #expect(loaded.count == 1)
        #expect(loaded.first?.manuscript.title == "ร่างที่แก้แล้ว")
    }

    @Test("a deleted manuscript is gone", .timeLimit(.minutes(2)))
    func deleteRemoves() async throws {
        guard let server = try await makeServer(port: 18_664) else { return }
        defer { Task { await server.shutdown() } }
        let store = ManuscriptStore(client: await server.client)

        let manuscript = draft(title: "เล่มที่จะลบ")
        try await store.save(manuscript)
        try await store.delete(manuscript.id)

        #expect(try await store.load(scope: .project(ProjectID("burnout"))).isEmpty)
    }
}
