import Testing
import Foundation
import AgentKit
import Instruments
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// The qualitative half against a real SurrealDB (ARCHITECTURE §20.3, P11.8).
//
// The arithmetic is checked in M15 against fixtures that can be done on paper.
// What has to be checked here is the thing only a database can get wrong: that a
// coder revising a passage replaces their own decision and nobody else's, so the
// κ read back tomorrow is computed over one row per person per passage.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_coding")

private func codebook() -> Codebook {
    Codebook(projectID: project, title: Bilingual("สมุดรหัสการคงอยู่"),
             codes: [Code(id: "cd_burden", name: Bilingual("ภาระงาน"),
                          definition: "ปริมาณงานต่อเวร"),
                     Code(id: "cd_team", name: Bilingual("ทีม"),
                          definition: "การช่วยเหลือกัน")],
             documentOrder: ["doc1", "doc2"])
}

@Suite("Codebook store", .serialized)
struct CodebookStoreTests {

    @Test("a codebook, its passages and its codings all come back", .timeLimit(.minutes(2)))
    func roundTrip() async throws {
        guard let server = try await makeServer(port: 18_652) else { return }
        defer { Task { await server.shutdown() } }
        let store = CodebookStore(client: await server.client)

        let book = codebook()
        try await store.save(book)
        let units = (0..<4).map {
            CodingUnit(id: "cu_\($0)", documentID: $0 < 2 ? "doc1" : "doc2",
                       range: ($0 * 10)..<($0 * 10 + 10), text: "ช่วงที่ \($0)")
        }
        for unit in units { try await store.save(unit, codebook: book.id) }
        for unit in units {
            for coder in ["ก", "ข"] {
                try await store.save(CodeAssignment(unitID: unit.id, coder: coder,
                                                    codeID: "cd_burden"),
                                     codebook: book.id)
            }
        }

        let loaded = try #require(try await store.all(project: project).first)
        #expect(loaded.id == book.id)
        #expect(loaded.codes.count == 2)
        #expect(loaded.documentOrder == ["doc1", "doc2"])

        let backUnits = try await store.units(codebook: book.id)
        #expect(backUnits.count == 4)
        // Stable order, so two runs of the same κ are the same κ.
        #expect(backUnits.map(\.id) == ["cu_0", "cu_1", "cu_2", "cu_3"])

        let backAssignments = try await store.assignments(codebook: book.id)
        #expect(backAssignments.count == 8)

        // And the whole point: it reaches the arithmetic.
        let report = try #require(CodingAnalysis.reliability(
            units: backUnits, assignments: backAssignments, codebook: loaded))
        #expect(report.comparableUnits == 4)
        #expect(abs(report.overall.kappa - 1) < 1e-12)
    }

    @Test("a coder changing their mind replaces their own row, not the other coder's",
          .timeLimit(.minutes(2)))
    func revisionReplacesOneRow() async throws {
        guard let server = try await makeServer(port: 18_653) else { return }
        defer { Task { await server.shutdown() } }
        let store = CodebookStore(client: await server.client)

        let book = codebook()
        try await store.save(book)
        let unit = CodingUnit(id: "cu_1", documentID: "doc1", range: 0..<10, text: "ช่วงเดียว")
        try await store.save(unit, codebook: book.id)
        try await store.save(CodeAssignment(unitID: unit.id, coder: "ก", codeID: "cd_burden"),
                             codebook: book.id)
        try await store.save(CodeAssignment(unitID: unit.id, coder: "ข", codeID: "cd_team"),
                             codebook: book.id)

        // ก reads it again and decides it was the other thing.
        try await store.save(CodeAssignment(unitID: unit.id, coder: "ก", codeID: "cd_team"),
                             codebook: book.id)

        let back = try await store.assignments(codebook: book.id)
        #expect(back.count == 2, "a revision must not leave two rows for one coder")
        #expect(back.first { $0.coder == "ก" }?.codeID == "cd_team")
        #expect(back.first { $0.coder == "ข" }?.codeID == "cd_team")
    }

    @Test("two codebooks in one project do not read each other's codings",
          .timeLimit(.minutes(2)))
    func codebooksAreSeparate() async throws {
        guard let server = try await makeServer(port: 18_654) else { return }
        defer { Task { await server.shutdown() } }
        let store = CodebookStore(client: await server.client)

        let first = codebook()
        var second = codebook()
        second = Codebook(projectID: project, title: Bilingual("รอบสอง"),
                          codes: first.codes)
        try await store.save(first)
        try await store.save(second)

        let unit = CodingUnit(id: "cu_a", documentID: "doc1", range: 0..<10, text: "ช่วง")
        try await store.save(unit, codebook: first.id)
        try await store.save(CodeAssignment(unitID: unit.id, coder: "ก", codeID: "cd_burden"),
                             codebook: first.id)

        #expect(try await store.units(codebook: second.id).isEmpty)
        #expect(try await store.assignments(codebook: second.id).isEmpty)
        #expect(try await store.all(project: project).count == 2)
    }
}
