import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// P19.6's other half: G2 asks how many, while the answer can still change
// anything (§12.6.1).
//
// A study too small to see the effect it was designed around does not produce
// "no effect" — it produces nothing, at the same cost in people's time and
// consent. The gate is the last moment that is fixable.
// ─────────────────────────────────────────────────────────────

private let inScope = "วัดอัตราความผิดพลาดก่อนและหลังเปลี่ยนตาราง"

private func plannedProject() -> Project {
    var project = Project(
        name: "ผลของการจัดตารางเวรต่อความผิดพลาดทางยา",
        kind: .research,
        brief: "เวรดึกติดกันสัมพันธ์กับความผิดพลาดทางยาหรือไม่",
        statement: ScopeStatement(inScope: [inScope],
                                  outOfScope: ["ไม่ประเมินต้นทุน"],
                                  acceptanceCriteria: ["รายงานอัตราพร้อมช่วงความเชื่อมั่น"]),
        board: [BoardRole(seat: .executive, person: "หัวหน้าพยาบาล")])
    project.stage = .planning
    return project
}

private func breakdown() -> WorkBreakdown {
    WorkBreakdown([
        WorkPackage(projectID: ProjectID("p"),
                    title: "เก็บข้อมูลอัตราความผิดพลาด",
                    scopeRef: inScope,
                    acceptanceCriteria: [Criterion(text: "ได้ข้อมูลครบทุกหอผู้ป่วย",
                                                   evidenceRequired: "ตารางข้อมูลที่ดึงได้จริง")],
                    raci: RACI(accountable: .human("หัวหน้าพยาบาล"))),
    ])
}

@Suite("G2 asks how many (P19.6)")
struct SampleSizeGateTests {

    @Test("a study that collects from people cannot pass G2 with no sample size")
    func gateBlocksWithoutASampleSize() {
        let evaluation = ProjectLifecycle.evaluate(
            plannedProject(), wbs: breakdown(),
            study: StudyFacts(collectsPrimaryData: true))

        #expect(evaluation?.passed == false)
        #expect(evaluation?.unmet.contains { $0.contains("sample size") } == true)
    }

    @Test("a size with no assumption behind it does not count")
    func sizeWithoutAnAssumptionIsNotAnAnswer() {
        // A number an ethics committee cannot check is not an answer, and
        // "we will recruit 200" is that number.
        let evaluation = ProjectLifecycle.evaluate(
            plannedProject(), wbs: breakdown(),
            study: StudyFacts(collectsPrimaryData: true, plannedSampleSize: 200,
                              sampleSizeAssumption: ""))
        #expect(evaluation?.passed == false)
    }

    @Test("size and assumption together open the gate")
    func sizeWithAnAssumptionPasses() {
        let evaluation = ProjectLifecycle.evaluate(
            plannedProject(), wbs: breakdown(),
            study: StudyFacts(collectsPrimaryData: true, plannedSampleSize: 63,
                              sampleSizeAssumption: "ตรวจจับผลต่าง 5 เมื่อ SD = 10 ที่ power 0.8"))
        #expect(evaluation?.passed == true)
        #expect(evaluation?.unmet.isEmpty == true)
    }

    /// A gate that asks everybody produces a number everybody types past.
    @Test("a project that collects nothing from people is not asked")
    func secondaryAnalysisIsNotAsked() {
        let evaluation = ProjectLifecycle.evaluate(
            plannedProject(), wbs: breakdown(), study: StudyFacts())
        #expect(evaluation?.passed == true)
        #expect(evaluation?.unmet.contains { $0.contains("sample size") } == false)
    }

    @Test("the question is asked at G2 and not carried into later gates")
    func onlyAtPlanning() {
        var executing = plannedProject()
        executing.stage = .execution
        let evaluation = ProjectLifecycle.evaluate(
            executing, wbs: breakdown(), study: StudyFacts(collectsPrimaryData: true))
        // By execution the data is being collected; asking now would be a gate
        // nobody can act on, which is the shape of a gate people route around.
        #expect(evaluation?.unmet.contains { $0.contains("sample size") } == false)
    }
}
