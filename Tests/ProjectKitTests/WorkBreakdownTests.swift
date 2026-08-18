import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// The WBS and the gate that reads it (ARCHITECTURE §19.6, P10.4).
//
// Each test below is a plan that looks finished and is not. That is the only
// interesting kind: a plan with an obvious hole gets fixed without a gate.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_test")
private let done = [Criterion(text: "ตรวจได้", evidenceRequired: "exit code 0")]

private func package(_ title: String,
                     parent: String? = nil,
                     id: String? = nil,
                     criteria: [Criterion] = done,
                     scopeRef: String? = "ความชุกในพยาบาลวิชาชีพ",
                     status: WorkPackageStatus = .backlog,
                     order: Int = 0) -> WorkPackage {
    WorkPackage(id: id ?? "wp_\(title)", projectID: project, parent: parent,
                title: title, deliverableType: title, scopeRef: scopeRef,
                acceptanceCriteria: criteria, role: .analyst,
                // Accountability is part of a finished plan since P10.5, so
                // the fixture that stands for "a complete leaf" carries it.
                raci: RACI(accountable: .teamLead, responsible: [.agent(.analyst)]),
                status: status, order: order)
}

private func briefed(inScope: [String] = ["ความชุกในพยาบาลวิชาชีพ"],
                     stage: ProjectStage = .planning) -> Project {
    var project = Project(name: "ความเครียดพยาบาล", kind: .research,
                          brief: "วัดความชุก",
                          statement: ScopeStatement(inScope: inScope,
                                                    outOfScope: ["ข้ามวิชาชีพ"],
                                                    acceptanceCriteria: ["ส่งวารสารได้"]),
                          board: [BoardRole(seat: .executive, person: "ผู้ใช้")])
    project.stage = stage
    return project
}

@Suite("Work breakdown structure")
struct WorkBreakdownTests {

    @Test("leaves are the work; groups are not")
    func leavesAndGroups() {
        let wbs = WorkBreakdown([
            package("บทความ", id: "root"),
            package("ข้อมูลสะอาด", parent: "root", id: "data"),
            package("สคริปต์ดึงข้อมูล", parent: "data", id: "pull"),
        ])

        #expect(wbs.leaves.map(\.id) == ["pull"])
        #expect(wbs.roots.map(\.id) == ["root"])
        #expect(wbs.depth(of: wbs.leaves[0]) == 2)
        #expect(wbs.ordered.map(\.id) == ["root", "data", "pull"])
    }

    @Test("a leaf with no acceptance criteria cannot become an assignment")
    func leafWithoutCriteriaIsNotWork() {
        let empty = package("รายงาน", criteria: [])
        #expect(empty.assignment() == nil)
        // And the same fact reaches the gate by name rather than as a silent
        // absence.
        let problems = WorkBreakdown([empty]).problems(inScope: ["ความชุกในพยาบาลวิชาชีพ"])
        #expect(problems.map(\.kind) == [.noAcceptanceCriteria])
    }

    @Test("a leaf that points at nothing in scope is work nobody agreed to")
    func unscopedLeafIsReported() {
        let orphan = package("ทำเว็บไซต์ให้ รพ.", scopeRef: nil)
        let stale = package("วิเคราะห์รอบสอง", id: "wp_stale", scopeRef: "ขอบเขตที่ถูกลบไปแล้ว")

        let problems = WorkBreakdown([orphan, stale])
            .problems(inScope: ["ความชุกในพยาบาลวิชาชีพ"])
        #expect(problems.contains { $0.kind == .noScopeRef })
        // Editing the scope statement after planning leaves leaves behind. The
        // WBS reports it rather than repairing it: which side moved is not
        // something code can know.
        #expect(problems.contains { $0.kind == .danglingScopeRef })
    }

    @Test("a group with nothing under it is a heading")
    func emptyGroupIsReported() {
        // Two children so `root` is a group, one of which is itself an empty
        // branch — the shape a plan takes when somebody sketched headings and
        // stopped.
        let wbs = WorkBreakdown([
            package("บทความ", id: "root"),
            package("ข้อมูลสะอาด", parent: "root", id: "data"),
        ])
        #expect(wbs.problems(inScope: ["ความชุกในพยาบาลวิชาชีพ"]).isEmpty)

        let sketch = WorkBreakdown([
            package("บทความ", id: "root"),
            package("ข้อมูลสะอาด", parent: "root", id: "data"),
            package("ต้นฉบับ", parent: "root", id: "draft"),
            package("บทที่ 1", parent: "draft", id: "ch1"),
        ])
        #expect(sketch.problems(inScope: ["ความชุกในพยาบาลวิชาชีพ"]).isEmpty)
    }

    @Test("a package whose parent is gone is reported, not silently re-parented")
    func danglingParent() {
        let wbs = WorkBreakdown([package("ใบลอย", parent: "wp_ghost")])
        #expect(wbs.problems(inScope: ["ความชุกในพยาบาลวิชาชีพ"]).map(\.kind) == [.missingParent])
        // And it still appears in the drawn order: a package the screen does
        // not show is a package nobody can fix.
        #expect(wbs.ordered.count == 1)
    }

    @Test("scope with no work under it is the other half of the 100% rule")
    func uncoveredScopeIsVisible() {
        let wbs = WorkBreakdown([package("สคริปต์ดึงข้อมูล")])
        let uncovered = wbs.uncoveredScope(
            inScope: ["ความชุกในพยาบาลวิชาชีพ", "ความตรงของมาตรวัด"])
        #expect(uncovered == ["ความตรงของมาตรวัด"])
    }

    @Test("done needs evidence, and a group cannot be closed by hand")
    func doneRequiresEvidence() throws {
        let wbs = WorkBreakdown([
            package("บทความ", id: "root"),
            package("สคริปต์", parent: "root", id: "leaf"),
        ])

        #expect(throws: WBSError.self) { try wbs.complete("leaf", with: []) }
        #expect(throws: WBSError.self) {
            try wbs.complete("root", with: [Evidence(kind: .commandExit, summary: "exit 0", passed: true)])
        }

        let closed = try wbs.complete("leaf", with: [
            Evidence(kind: .commandExit, summary: "pytest exit 0", passed: true),
        ])
        #expect(closed.status == .done)
        #expect(closed.evidence.count == 1)
    }
}

@Suite("G2 reads the plan")
struct PlanningGateTests {

    @Test("a project with no work packages does not pass G2")
    func emptyPlanFails() throws {
        let gate = try #require(ProjectLifecycle.evaluate(briefed()))
        #expect(gate.gate == "G2")
        #expect(!gate.passed)
        #expect(gate.unmet.contains("At least one work package"))
    }

    @Test("a plan whose leaves are complete passes")
    func completePlanPasses() throws {
        let wbs = WorkBreakdown([
            package("บทความ", id: "root"),
            package("สคริปต์", parent: "root", id: "leaf"),
        ])
        let gate = try #require(ProjectLifecycle.evaluate(briefed(), wbs: wbs))
        #expect(gate.passed, "ค้าง: \(gate.unmet)")
    }

    @Test("a scope line nobody planned for holds G2 shut")
    func uncoveredScopeBlocksG2() throws {
        let wbs = WorkBreakdown([package("สคริปต์", id: "leaf")])
        let project = briefed(inScope: ["ความชุกในพยาบาลวิชาชีพ", "ความตรงของมาตรวัด"])

        let gate = try #require(ProjectLifecycle.evaluate(project, wbs: wbs))
        #expect(!gate.passed)
        #expect(gate.unmet == ["Every in-scope line has a work package behind it"])
    }

    @Test("G3 counts open leaves rather than trusting a number passed in")
    func executionGateCountsLeaves() throws {
        let wbs = WorkBreakdown([
            package("สคริปต์", id: "a", status: .done),
            package("รายงาน", id: "b", status: .inReview),
        ])
        let project = briefed(stage: .execution)

        let gate = try #require(ProjectLifecycle.evaluate(project, wbs: wbs))
        #expect(gate.gate == "G3")
        #expect(!gate.passed)

        let finished = WorkBreakdown([
            package("สคริปต์", id: "a", status: .done),
            package("รายงาน", id: "b", status: .done),
        ])
        #expect(ProjectLifecycle.evaluate(project, wbs: finished)?.passed == true)
    }
}
