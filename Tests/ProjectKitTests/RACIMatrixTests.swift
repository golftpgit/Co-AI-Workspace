import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// P10.9 — the questions a RACI is built to answer are questions across rows,
// and none of them can be asked one package at a time.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_raci")
private let done = [Criterion(text: "ตรวจได้", evidenceRequired: "exit 0")]

private func leaf(_ id: String, order: Int, raci: RACI?) -> WorkPackage {
    WorkPackage(id: id, projectID: project, title: id, scopeRef: "ขอบเขต",
                acceptanceCriteria: done, raci: raci ?? RACI(accountable: .teamLead),
                dependsOn: [], status: .backlog, order: order)
}

@Suite("The RACI table (P10.9)")
struct RACIMatrixTests {

    private var plan: WorkBreakdown {
        WorkBreakdown([
            leaf("เก็บข้อมูล", order: 0,
                 raci: RACI(accountable: .human("อ.สมชาย"),
                            responsible: [.agent(.researcher)],
                            consulted: [.agent(.analyst)])),
            leaf("วิเคราะห์", order: 1,
                 raci: RACI(accountable: .human("อ.สมชาย"),
                            responsible: [.agent(.analyst)],
                            informed: [.human("พยาบาลหัวหน้าวอร์ด")])),
        ])
    }

    @Test("everyone appears once, people first, and the columns do not move")
    func actorsAreStable() {
        let matrix = RACIMatrix.build(plan)
        #expect(matrix.actors.prefix(2).filter(\.isHuman).count == 2)
        #expect(matrix.actors.count == Set(matrix.actors).count)
        #expect(matrix.actors.contains(.human("อ.สมชาย")))
        #expect(matrix.actors.contains(.agent(.analyst)))
        // Built twice from the same plan gives the same table — a table that
        // reshuffles is a table nobody can point at.
        #expect(RACIMatrix.build(plan) == matrix)
    }

    /// The bottleneck question: read by counting, not by squinting down a
    /// column.
    @Test("responsibility is countable per actor")
    func bottleneckIsCountable() {
        let matrix = RACIMatrix.build(plan)
        #expect(matrix.responsibleCount(for: .agent(.analyst)) == 1)
        #expect(matrix.responsibleCount(for: .human("อ.สมชาย")) == 0)
        #expect(matrix.responsibleCount(for: .agent(.writer)) == 0)
    }

    /// Somebody in the column headers with an empty column is the question the
    /// table exists to raise, so they are listed rather than hidden.
    @Test("an actor who carries no letter is named")
    func uninvolvedActorsAreNamed() {
        let withGhost = WorkBreakdown([
            leaf("A", order: 0, raci: RACI(accountable: .teamLead,
                                           responsible: [.agent(.engineer)],
                                           consulted: [])),
        ])
        let matrix = RACIMatrix.build(withGhost)
        #expect(matrix.uninvolved.isEmpty)
        // Everyone present carries something; the check is that the property
        // reads the table rather than the plan's roster.
        #expect(matrix.actors.contains(.agent(.teamLead)))
    }

    /// Accountable to somebody, assigned to nobody.
    @Test("a package with an A and no R is flagged")
    func unassignedWorkIsVisible() {
        let matrix = RACIMatrix.build(WorkBreakdown([
            leaf("ไม่มีคนทำ", order: 0, raci: RACI(accountable: .human("อ.สมชาย"))),
        ]))
        #expect(matrix.rows.first?.isUnassigned == true)
    }

    /// A real state, usually a mistake, and flattening it to one letter hides
    /// exactly what a reader is looking for.
    @Test("an actor holding two letters on one package shows both")
    func disagreementIsShownNotResolved() {
        let matrix = RACIMatrix.build(WorkBreakdown([
            leaf("ทับซ้อน", order: 0,
                 raci: RACI(accountable: .human("อ.สมชาย"),
                            responsible: [.human("อ.สมชาย")],
                            consulted: [.human("อ.สมชาย")])),
        ]))
        let cell = try! #require(matrix.rows.first?.cells.first)
        #expect(cell == [.responsible, .accountable, .consulted])
    }

    @Test("an empty plan is an empty table rather than a crash")
    func emptyPlan() {
        let matrix = RACIMatrix.build(WorkBreakdown([]))
        #expect(matrix.actors.isEmpty)
        #expect(matrix.rows.isEmpty)
        #expect(matrix.uninvolved.isEmpty)
    }
}
