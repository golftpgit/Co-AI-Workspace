import Testing
import Foundation
import AgentKit
import Knowledge
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// P11.10's Done-when: the retention policy that was set is enforced when the
// project closes (§19.12 condition 8, §20.5).
//
// The first test is the one that matters most, because it is the behaviour
// that shipped and was wrong: free text used to satisfy this gate.
// ─────────────────────────────────────────────────────────────

private func policy(_ text: String, document: String = "นโยบายข้อมูลวิจัย") -> PolicyRule {
    PolicyRule(id: "p_\(UUID().uuidString)", text: text, isHardConstraint: true,
               terms: [], provenance: Provenance(documentID: "doc_1", title: document,
                                                 origin: .upload(filename: "policy.md"),
                                                 tier: .t1))
}

private func disposition(_ policyText: String,
                         action: DataDisposition.Action = .delete,
                         by: String = "พนุพงศ์ ต.") -> DataDisposition {
    DataDisposition(action: action, policy: policyText, decidedBy: by)
}

@Suite("Retention — condition 8 is enforced, not typed")
struct RetentionGateTests {

    // The regression this task exists to fix. Before P11.10 the condition was
    // "policy is non-empty and somebody signed it", so any sentence passed.
    @Test("free text that matches no real policy no longer passes the gate")
    func freeTextIsRefused() {
        let rules = RetentionPolicyReader.rules(in: [
            policy("เก็บข้อมูลผู้เข้าร่วมไว้ 5 ปีแล้วทำลาย"),
        ])
        let result = RetentionCheck.evaluate(
            disposition: disposition("จะจัดการให้เรียบร้อย"),
            heldHumanData: true, rules: rules)

        #expect(result.passes == false)
        guard case .blocked(let why) = result else { Issue.record("expected a block"); return }
        // It has to say what does exist, or the person is guessing.
        #expect(why.contains("เก็บข้อมูลผู้เข้าร่วมไว้ 5 ปีแล้วทำลาย"))
    }

    @Test("naming a policy that is really in the policy scope passes, with a due date")
    func realPolicyPasses() {
        let rules = RetentionPolicyReader.rules(in: [
            policy("เก็บข้อมูลผู้เข้าร่วมไว้ 5 ปีแล้วทำลาย"),
        ])
        let now = Date(timeIntervalSince1970: 0)
        let result = RetentionCheck.evaluate(disposition: disposition("เก็บข้อมูลผู้เข้าร่วมไว้ 5 ปี"),
                                             heldHumanData: true, rules: rules, now: now)

        guard case .satisfied(let obligation) = result else {
            Issue.record("expected it to pass, got \(result)"); return
        }
        #expect(obligation.action == .delete)
        #expect(obligation.decidedBy == "พนุพงศ์ ต.")
        let expected = Calendar.current.date(byAdding: .month, value: 60, to: now)
        #expect(obligation.dueOn == expected, "five years should be sixty months from now")
    }

    // A study that promised participants something and wrote it down nowhere is
    // exactly the case §20.5 exists for.
    @Test("collecting from people with no retention policy at all is blocked")
    func noPolicyAtAllIsBlocked() {
        let result = RetentionCheck.evaluate(disposition: disposition("เก็บ 5 ปี"),
                                             heldHumanData: true, rules: [])
        #expect(result.passes == false)
        guard case .blocked(let why) = result else { Issue.record("expected a block"); return }
        #expect(why.contains("policy"))
    }

    // A software project has no participants. Making it invent a retention
    // promise is ceremony, and R10 is about exactly that.
    @Test("a project that collected nothing from people is not asked to promise anything")
    func notApplicableWhenNoHumanData() {
        let result = RetentionCheck.evaluate(disposition: nil, heldHumanData: false, rules: [])
        #expect(result == .notApplicable)
        #expect(result.passes)
    }

    // Deliberately *not* a block. Blocking here would stop every project in
    // the app from closing the moment one reader is unwired — the bug that
    // `ProjectTypeGate` calls strictness in costume (P11.1). It shows as a grey
    // dash instead, which U21-2 says must not look like a green tick.
    @Test("not having checked shows as vacuous — neither a block nor a tick")
    func unknownIsVacuousNotGreen() {
        let result = RetentionCheck.evaluate(disposition: disposition("เก็บ 5 ปี"),
                                             heldHumanData: nil, rules: [])
        #expect(result.passes)
        #expect(result.isVacuous)
    }

    // "Follow the policy" with no date is the version nobody can act on, so the
    // absence of a period is reported instead of being filled in.
    @Test("a policy with no period gives an obligation that says so, not a made-up date")
    func noPeriodIsSaidOutLoud() {
        let rules = RetentionPolicyReader.rules(in: [
            policy("ข้อมูลผู้เข้าร่วมต้องถูกทำให้ไม่ระบุตัวตนก่อนเผยแพร่"),
        ])
        let result = RetentionCheck.evaluate(
            disposition: disposition("ข้อมูลผู้เข้าร่วมต้องถูกทำให้ไม่ระบุตัวตน", action: .keep),
            heldHumanData: true, rules: rules)

        guard case .satisfied(let obligation) = result else {
            Issue.record("expected it to pass, got \(result)"); return
        }
        #expect(obligation.dueOn == nil)
        #expect(obligation.summary.contains("ไม่ได้ระบุระยะเวลา"))
    }
}

@Suite("Retention — reading the policy scope")
struct RetentionPolicyReaderTests {

    @Test("only rules that are about keeping or destroying data are picked up")
    func picksRetentionRulesOnly() {
        let rules = RetentionPolicyReader.rules(in: [
            policy("ห้ามลบฐานข้อมูลผลการทดลอง"),
            policy("เก็บข้อมูลผู้เข้าร่วมไว้ 5 ปีแล้วทำลาย"),
            policy("ต้องสำรองข้อมูลทุกสัปดาห์"),
        ])
        #expect(rules.count == 1)
        #expect(rules[0].text.contains("5 ปี"))
    }

    @Test("periods are read in both languages, and absent ones stay absent")
    func readsPeriods() {
        #expect(RetentionPolicyReader.period(in: "เก็บไว้ 5 ปีแล้วทำลาย") == 60)
        #expect(RetentionPolicyReader.period(in: "เก็บไว้ 18 เดือน") == 18)
        #expect(RetentionPolicyReader.period(in: "retain for 3 years then destroy") == 36)
        #expect(RetentionPolicyReader.period(in: "retain for 6 months") == 6)
        #expect(RetentionPolicyReader.period(in: "ทำลายเมื่อสิ้นสุดโครงการ") == nil)
    }

    @Test("the rule carries the document it came from, so 'says who' is answerable")
    func keepsItsSource() {
        let rules = RetentionPolicyReader.rules(in: [
            policy("เก็บข้อมูล 2 ปี", document: "ระเบียบคณะกรรมการจริยธรรม"),
        ])
        #expect(rules[0].source == "ระเบียบคณะกรรมการจริยธรรม")
    }
}

@Suite("Retention — inside the closing gate")
struct RetentionClosingGateTests {

    private func project() -> Project {
        var project = Project(id: ProjectID("pj_test"), name: "การศึกษาภาวะหมดไฟ")
        project.stage = .closing
        return project
    }

    @Test("the gate blocks a close whose retention is free text")
    func gateBlocks() {
        let facts = ClosingFacts(
            openRegisterEntries: 0, openConflicts: 0, pendingAssumptions: 0,
            conformanceGaps: [], dataDisposition: disposition("เดี๋ยวจัดการ"),
            heldHumanData: true,
            retentionRules: RetentionPolicyReader.rules(in: [policy("เก็บไว้ 5 ปีแล้วทำลาย")]))

        let evaluation = ProjectLifecycle.evaluate(project(), hasLessons: true, closing: facts)
        let retentionCondition = evaluation?.conditions.first { $0.text.contains("ไม่พบนโยบาย") }
        #expect(retentionCondition?.satisfied == false, "free text passed the closing gate")
    }

    @Test("an unwired retention reader shows a grey dash, never a green tick")
    func uncheckedIsVacuous() {
        // The disposition is decided, so condition 8's original half passes.
        // What is unknown is whether this project ever collected from people —
        // and that must not silently read as "checked and fine" (U21-2).
        let facts = ClosingFacts(openRegisterEntries: 0, openConflicts: 0,
                                 pendingAssumptions: 0, conformanceGaps: [],
                                 dataDisposition: disposition("เก็บ 5 ปี"),
                                 heldHumanData: nil)
        let evaluation = ProjectLifecycle.evaluate(project(), hasLessons: true, closing: facts)
        let condition = evaluation?.conditions.first { $0.text.contains("ยังไม่ได้ตรวจว่า") }
        #expect(condition?.vacuous == true)
        #expect(condition?.satisfied == true, "an unwired reader must not block every close")
    }

    // A project with no participants still has files, and §19.12 condition 8
    // has always been about those too — retention is the extra half, not a
    // replacement for the original question.
    @Test("a project that collected nothing from people still has to say where its files go")
    func dispositionStillRequiredWithoutHumanData() {
        let facts = ClosingFacts(openRegisterEntries: 0, openConflicts: 0,
                                 pendingAssumptions: 0, conformanceGaps: [],
                                 dataDisposition: nil, heldHumanData: false)
        let evaluation = ProjectLifecycle.evaluate(project(), hasLessons: true, closing: facts)
        let condition = evaluation?.conditions.first { $0.text.contains("ข้อมูลและไฟล์ที่เหลือ") }
        #expect(condition?.satisfied == false)
    }
}

@Suite("Retention — the facts the gate is given")
struct RetentionFactsTests {

    private struct Facts: RetentionFactsReading {
        var held: Bool?
        var rules: [RetentionRule] = []
        func heldHumanData(scope: Scope) async -> Bool? { held }
        func retentionRules(scope: Scope) async -> [RetentionRule] { rules }
    }

    // The wiring, end to end through ProjectService: a project that collected
    // answers and names a policy nobody wrote cannot be closed.
    @Test("the service hands the gate real facts, and free text is refused there too")
    func serviceFeedsTheGate() async throws {
        let rules = RetentionPolicyReader.rules(in: [policy("เก็บข้อมูลผู้เข้าร่วมไว้ 5 ปีแล้วทำลาย")])
        let service = ProjectService(store: MemoryProjectStore(),
                                     retentionFacts: Facts(held: true, rules: rules))

        let project = try await service.create(name: "การศึกษาภาวะหมดไฟ")
        try await service.decideDisposition(disposition("เดี๋ยวค่อยว่ากัน"), for: project.id)

        let facts = await service.closingFacts(of: project.id)
        #expect(facts.heldHumanData == true)
        #expect(facts.retentionRules.count == 1)
        guard case .blocked = facts.retention else {
            Issue.record("free text reached the gate and passed: \(facts.retention)")
            return
        }
    }

    // Without the wiring the condition must not block — the whole app would be
    // unable to close a project because one reader is absent.
    @Test("a service with no retention reader leaves the condition unchecked, not failing")
    func absentReaderIsUnchecked() async throws {
        let service = ProjectService(store: MemoryProjectStore())

        let project = try await service.create(name: "โปรเจกต์ซอฟต์แวร์")
        try await service.decideDisposition(disposition("เก็บไว้ที่เดิม", action: .keep),
                                            for: project.id)

        let facts = await service.closingFacts(of: project.id)
        #expect(facts.heldHumanData == nil)
        #expect(facts.retention.passes)
        #expect(facts.retention.isVacuous)
    }
}
