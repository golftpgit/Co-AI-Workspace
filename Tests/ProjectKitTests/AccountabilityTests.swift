import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// RACI and the board (ARCHITECTURE §19.5, §19.9, P10.5).
//
// Two of the three rules are not tested here, because they are not testable:
// "exactly one accountable" and "no agent in the Executive seat" are enforced
// by the shape of the types, so the states they forbid cannot be written down
// in a test either. What is left — the rule that depends on how much is at
// stake — is what these check.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_raci")
private let done = [Criterion(text: "ตรวจได้", evidenceRequired: "exit 0")]

private func leaf(_ title: String,
                  raci: RACI? = RACI(accountable: .teamLead, responsible: [.agent(.analyst)]),
                  risk: RiskLevel = .low) -> WorkPackage {
    WorkPackage(id: "wp_\(title)", projectID: project, title: title,
                scopeRef: "ความชุกในพยาบาลวิชาชีพ",
                acceptanceCriteria: done, role: .analyst,
                raci: raci, riskClass: risk)
}

@Suite("Accountability")
struct AccountabilityTests {

    @Test("a leaf nobody answers for holds G2 shut")
    func accountableIsRequired() {
        let problems = WorkBreakdown([leaf("สคริปต์", raci: nil)])
            .problems(inScope: ["ความชุกในพยาบาลวิชาชีพ"])
        #expect(problems.map(\.kind) == [.noAccountable])
    }

    @Test("high-risk work is accountable to a person, not to the team lead")
    func highRiskNeedsAHuman() {
        let toLead = leaf("แก้ข้อมูลผู้เข้าร่วม", risk: .high)
        #expect(WorkBreakdown([toLead]).problems(inScope: ["ความชุกในพยาบาลวิชาชีพ"])
            .map(\.kind) == [.highRiskWithoutHuman])

        // The same package, accountable to a named person, is fine — and the
        // specialist doing the work is unchanged. R and A are different
        // questions, which is the whole reason RACI has both letters.
        let toPerson = leaf("แก้ข้อมูลผู้เข้าร่วม",
                            raci: RACI(accountable: .human("ผู้ใช้"),
                                       responsible: [.agent(.analyst)]),
                            risk: .high)
        #expect(WorkBreakdown([toPerson]).problems(inScope: ["ความชุกในพยาบาลวิชาชีพ"]).isEmpty)
    }

    @Test("low-risk work may be accountable to the team lead")
    func leadMayHoldOrdinaryWork() {
        #expect(WorkBreakdown([leaf("อ่านวรรณกรรม")])
            .problems(inScope: ["ความชุกในพยาบาลวิชาชีพ"]).isEmpty)
    }

    @Test("the Executive seat holds a person's name and nothing else")
    func executiveIsAPerson() {
        // There is no expression that puts a Role here: `BoardRole` has no case
        // and no initializer that accepts one. The test that would prove it
        // cannot be written, which is the strongest form the rule can take.
        let seat = BoardRole(seat: .executive, person: "ผู้ใช้")
        #expect(seat.isFilled)
        #expect(!BoardRole(seat: .executive, person: "   ").isFilled)
    }

    @Test("G1 refuses a project whose business case nobody owns")
    func g1NeedsAnExecutive() throws {
        var project = Project(name: "ความเครียดพยาบาล",
                              brief: "วัดความชุก",
                              statement: ScopeStatement(inScope: ["ความชุก"],
                                                        outOfScope: ["ข้ามวิชาชีพ"]))
        let gate = try #require(ProjectLifecycle.evaluate(project))
        #expect(gate.unmet == ["มีชื่อผู้รับผิดชอบทางธุรกิจ (Executive) ที่เป็นคน"])

        project.board = [BoardRole(seat: .executive, person: "ผู้ใช้")]
        #expect(ProjectLifecycle.evaluate(project)?.passed == true)
    }

    @Test("an accountable actor is still a participant, so reports can list one set")
    func accountableProjectsIntoTheActorSet() {
        #expect(Accountable.teamLead.asActor == .agent(.teamLead))
        #expect(Accountable.human("ผู้ใช้").asActor == .human("ผู้ใช้"))
        #expect(Accountable.human("ผู้ใช้").isHuman)
        #expect(!Accountable.teamLead.isHuman)
    }
}
