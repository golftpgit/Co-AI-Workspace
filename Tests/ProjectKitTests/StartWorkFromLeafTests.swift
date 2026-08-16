import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// P10.4's missing half — a leaf could describe itself as an assignment since
// P10.4 and nothing could start one, so the plan and the team were joined by a
// field nobody could act on.
//
// The rule the button rests on lives on the type, not on the screen: a leaf
// that cannot say what done means cannot be handed to anybody.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_start")

private func leaf(criteria: [Criterion], role: Role? = nil,
                  deliverable: String = "") -> WorkPackage {
    WorkPackage(id: "wp1", projectID: project, title: "บทที่ 3 วิธีดำเนินการวิจัย",
                deliverableType: deliverable, scopeRef: "ขอบเขต",
                acceptanceCriteria: criteria, role: role,
                raci: RACI(accountable: .teamLead), status: .backlog, order: 0)
}

@Suite("Starting work from a leaf (P10.4)")
struct StartWorkFromLeafTests {

    @Test("a leaf with acceptance criteria becomes an assignment that carries them")
    func criteriaTravel() throws {
        let criterion = Criterion(text: "อ้างอิงครบทุกย่อหน้า",
                                  evidenceRequired: "citation ที่ผูก provenance")
        let assignment = try #require(leaf(criteria: [criterion]).assignment(for: .writer))

        #expect(assignment.role == .writer)
        #expect(assignment.goal == "บทที่ 3 วิธีดำเนินการวิจัย")
        // The criteria are the whole point: they are what the reviewer checks,
        // and an assignment that loses them is one nobody can fail.
        #expect(assignment.acceptanceCriteria == [criterion])
    }

    /// The rule the button's disabled state comes from.
    @Test("a leaf with no acceptance criteria cannot be started")
    func noCriteriaNoWork() {
        #expect(leaf(criteria: []).assignment(for: .writer) == nil)
    }

    @Test("the leaf's own role wins over the one offered")
    func rolePreference() throws {
        let withRole = leaf(criteria: [Criterion(text: "x", evidenceRequired: "y")],
                            role: .analyst)
        #expect(try #require(withRole.assignment()).role == .analyst)
        // And a leaf with no role of its own takes the one it is given, which
        // is what the screen passes.
        let without = leaf(criteria: [Criterion(text: "x", evidenceRequired: "y")])
        #expect(try #require(without.assignment(for: .researcher)).role == .researcher)
        #expect(without.assignment() == nil, "a leaf with no role started as nobody")
    }

    @Test("a leaf with no deliverable type falls back to its own title")
    func deliverableFallsBackToTitle() throws {
        let assignment = try #require(
            leaf(criteria: [Criterion(text: "x", evidenceRequired: "y")]).assignment(for: .writer))
        #expect(assignment.deliverableType == "บทที่ 3 วิธีดำเนินการวิจัย")
    }
}
