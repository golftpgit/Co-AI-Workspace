import Testing
import Foundation
import AgentKit
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// Gap Detection and the Analysis Plan (ARCHITECTURE §12.4, P6.7).
//
// Everything here runs without a model: the model's only job is turning prose
// into a `ProposalReading`, and every rule that decides what blocks approval is
// comparison and counting. That split is the reason these tests can be exact.
// ─────────────────────────────────────────────────────────────

private let schema = SchemaSnapshot(fields: [
    .init(table: "patients", name: "patient_id", type: "BIGINT"),
    .init(table: "patients", name: "age", type: "BIGINT"),
    .init(table: "readings", name: "hba1c", type: "DOUBLE"),
    .init(table: "readings", name: "patient_id", type: "BIGINT"),
    .init(table: "visits", name: "visit_date", type: "DATE"),
])

/// A proposal in the shape one actually arrives in — Thai prose, some things
/// stated and some not.
private let proposal = """
โครงร่างวิจัย: ผลของการให้เมตฟอร์มินต่อระดับ HbA1c ในผู้ป่วยเบาหวานชนิดที่ 2
คำถามวิจัย: การให้เมตฟอร์มินลดระดับ HbA1c ได้จริงหรือไม่
ประชากรที่ศึกษา: ผู้ป่วยเบาหวานชนิดที่ 2 อายุ 18 ปีขึ้นไป
ปัจจัยที่ศึกษา: การได้รับเมตฟอร์มิน
ผลลัพธ์ที่วัด: ระดับ HbA1c ที่ 6 เดือน
"""

private func reading() -> ProposalReading {
    ProposalReading(
        researchQuestion: "การให้เมตฟอร์มินลดระดับ HbA1c ได้จริงหรือไม่",
        hypothesis: "",
        population: "ผู้ป่วยเบาหวานชนิดที่ 2 อายุ 18 ปีขึ้นไป",
        exposure: "การได้รับเมตฟอร์มิน",
        outcome: "ระดับ HbA1c ที่ 6 เดือน",
        plannedMethod: "",
        timeframe: "",
        requiredFields: ["hba1c", "age", "patient_id", "creatinine"])
}

@Suite("Gap detection")
struct GapDetectorTests {

    /// §12.4 level 1: a variable the proposal needs and the database does not
    /// have. Nothing can be run, so nothing may be approved.
    @Test("a field that does not exist anywhere is a critical gap")
    func missingFieldIsCritical() {
        let plan = GapDetector.plan(title: "เมตฟอร์มิน", reading: reading(),
                                    proposalText: proposal, schema: schema)
        let critical = plan.gaps.filter { $0.severity == .critical }
        #expect(critical.count == 1)
        #expect(critical[0].subject.contains("creatinine"))
        #expect(!plan.isReadyForApproval)
    }

    /// §12.4 level 2: the name exists in more than one table, so which one is
    /// meant is a question, not a guess.
    @Test("a field that matches two tables is ambiguous, and lists both")
    func duplicateFieldIsAmbiguous() {
        let plan = GapDetector.plan(title: "เมตฟอร์มิน", reading: reading(),
                                    proposalText: proposal, schema: schema)
        let ambiguous = plan.gaps.first { $0.severity == .ambiguous }
        #expect(ambiguous?.subject.contains("patient_id") == true)
        #expect(ambiguous?.options.sorted() == ["patients.patient_id", "readings.patient_id"])
    }

    @Test("spelling differences are not gaps")
    func spellingIsNotAGap() {
        var input = reading()
        input.requiredFields = ["HbA1c", "AGE"]
        let plan = GapDetector.plan(title: "t", reading: input,
                                    proposalText: proposal, schema: schema)
        #expect(plan.gaps.filter { $0.subject.contains("ตัวแปร") }.isEmpty)
        #expect(plan.decisions.contains { $0.value == "readings.hba1c" })
    }

    /// §12.4 level 3: the proposal simply does not say which statistical method
    /// it will use — the choice has to be made, and by a person.
    @Test("a method the proposal never states becomes an assumption to settle")
    func missingMethodNeedsAnAssumption() {
        let plan = GapDetector.plan(title: "เมตฟอร์มิน", reading: reading(),
                                    proposalText: proposal, schema: schema)
        let assumptions = plan.gaps.filter { $0.severity == .assumptionNeeded }
        #expect(assumptions.contains { $0.subject == "วิธีทางสถิติ" })
        // On its own it does not block — but the placeholder decision it comes
        // with is tagged `agent_suggested`, and that does.
        #expect(plan.agentSuggestions.contains { $0.question == "วิธีทางสถิติ" })
    }

    /// The rule carried over from `RelationExtractor`: words that are not in
    /// the document are not the document's.
    @Test("a value the proposal does not contain is tagged as the agent's")
    func paraphraseIsNotTheProposal() {
        var input = reading()
        // A perfectly reasonable paraphrase — and not what the proposal says.
        input.population = "ผู้ใหญ่ที่เป็นเบาหวาน"
        let plan = GapDetector.plan(title: "t", reading: input,
                                    proposalText: proposal, schema: schema)
        let population = plan.decisions.first { $0.question == "ประชากรที่ศึกษา" }
        #expect(population?.origin == .agentSuggested)

        // Whereas the words the proposal really uses are the proposal's.
        let outcome = plan.decisions.first { $0.question == "ผลลัพธ์ที่วัด (outcome)" }
        #expect(outcome?.origin == .proposalStated)
    }

    @Test("with no database attached, every field is honestly unknown rather than fine")
    func noSchemaIsNotAPass() {
        let plan = GapDetector.plan(title: "t", reading: reading(),
                                    proposalText: proposal,
                                    schema: SchemaSnapshot(fields: []))
        #expect(plan.gaps.filter { $0.severity == .critical }.count == 4)
        #expect(plan.gaps[0].detail.contains("ยังไม่ได้ต่อฐานข้อมูล")
                || plan.blockingGaps.first?.detail.contains("ยังไม่ได้ต่อฐานข้อมูล") == true)
    }
}

@Suite("Analysis plan")
struct AnalysisPlanTests {

    private func settled() -> AnalysisPlan {
        var plan = GapDetector.plan(title: "เมตฟอร์มิน", reading: reading(),
                                    proposalText: proposal, schema: schema)
        for gap in plan.gaps {
            plan.resolve(gap: gap.id, with: gap.options.first ?? "ตกลงตามที่เสนอ")
        }
        for decision in plan.agentSuggestions {
            plan.confirm(decision.id, value: "ผู้ใช้ยืนยัน")
        }
        return plan
    }

    /// P6.7's Done-when, stated as the type's own rule.
    @Test("a plan with an agent suggestion left in it cannot be approved")
    func agentSuggestionsBlockApproval() {
        var plan = GapDetector.plan(title: "เมตฟอร์มิน", reading: reading(),
                                    proposalText: proposal, schema: schema)
        // Everything that blocks on its own is settled; what remains is the
        // method the proposal never stated, still standing as the agent's
        // placeholder. That alone has to be enough to refuse approval.
        for gap in plan.blockingGaps {
            plan.resolve(gap: gap.id, with: gap.options.first ?? "ตกลง")
        }
        #expect(plan.blockingGaps.isEmpty)
        #expect(plan.agentSuggestions.contains { $0.question == "วิธีทางสถิติ" })
        #expect(throws: PlanApprovalError.self) { try plan.approve(by: "ผู้ใช้") }
        #expect(!plan.isApproved)
    }

    @Test("once every suggestion is confirmed, the plan approves — and has none left")
    func approvedPlanHasNoSuggestions() throws {
        var plan = settled()
        try plan.approve(by: "ผู้ใช้")
        #expect(plan.isApproved)
        #expect(plan.approvedBy == "ผู้ใช้")
        // The Done-when, checked on the approved object itself.
        #expect(plan.agentSuggestions.isEmpty)
        #expect(plan.decisions.allSatisfy {
            $0.origin == .humanConfirmed || $0.origin == .proposalStated
        })
    }

    @Test("a critical gap blocks approval however many suggestions are confirmed")
    func criticalGapBlocks() {
        var plan = AnalysisPlan(title: "t")
        plan.add(AnalysisDecision(question: "วิธี", value: "t-test", origin: .proposalStated))
        plan.add(AnalysisGap(severity: .critical, subject: "ตัวแปร “creatinine”",
                             detail: "ไม่มีคอลัมน์นี้"))
        #expect(throws: PlanApprovalError.self) { try plan.approve(by: "ผู้ใช้") }
        #expect(plan.blockers.contains { $0.contains("creatinine") })
    }

    /// The pre-registration property: an approved plan that is edited is no
    /// longer the plan that was approved, and it says so.
    @Test("editing an approved plan withdraws the approval and records why")
    func editingWithdrawsApproval() throws {
        var plan = settled()
        try plan.approve(by: "ผู้ใช้")
        plan.add(AnalysisDecision(question: "ตัวแปรควบคุม", value: "อายุ",
                                  origin: .humanConfirmed))
        #expect(!plan.isApproved)
        #expect(plan.revisions.count == 1)
        #expect(plan.revisions[0].contains("ตัวแปรควบคุม"))
    }

    /// §12.3's loop back, and the reason the two features are one mechanism: a
    /// failed assumption proposes a different test, the proposal arrives as the
    /// agent's, and the plan cannot be re-approved until a person looks at it.
    @Test("a failed statistical assumption sends the plan back for re-approval")
    func statisticalFailureReopensThePlan() throws {
        var plan = settled()
        try plan.approve(by: "ผู้ใช้")

        plan.methodologyChanged(
            reason: "t-test ไม่ผ่านการตรวจการแจกแจงปกติ (Shapiro–Wilk p = 0.0003)",
            proposal: AnalysisDecision(question: "วิธีทางสถิติ (แก้ไข)",
                                       value: "Mann–Whitney U",
                                       origin: .agentSuggested,
                                       note: "แทน t-test ที่ข้อสมมติไม่ผ่าน"))

        #expect(!plan.isApproved)
        #expect(plan.agentSuggestions.count == 1)
        #expect(throws: PlanApprovalError.self) { try plan.approve(by: "ผู้ใช้") }

        // And the way back is a person agreeing to the new method.
        let suggestion = plan.agentSuggestions[0].id
        plan.confirm(suggestion)
        try plan.approve(by: "ผู้ใช้")
        #expect(plan.isApproved)
        #expect(plan.revisions.count == 1)
    }

    @Test("answering a gap records the answer as the person's, not the agent's")
    func answeringAGapIsAHumanDecision() {
        var plan = AnalysisPlan(title: "t")
        let gap = AnalysisGap(severity: .ambiguous, subject: "ตัวแปร “patient_id”",
                              detail: "มีสองที่", options: ["a.patient_id", "b.patient_id"])
        plan.add(gap)
        let resolved = plan.resolve(gap: gap.id, with: "b.patient_id")
        #expect(resolved)

        let decision = plan.decisions.first { $0.question == gap.subject }
        #expect(decision?.value == "b.patient_id")
        #expect(decision?.origin == .humanConfirmed)
        #expect(plan.openGaps.isEmpty)
    }

    @Test("an empty plan is not an approved plan")
    func emptyPlanCannotBeApproved() {
        var plan = AnalysisPlan(title: "ว่าง")
        #expect(throws: PlanApprovalError.self) { try plan.approve(by: "ผู้ใช้") }
    }
}
