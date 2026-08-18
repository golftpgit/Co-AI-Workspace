import Testing
import Foundation
@testable import AgentKit

// ─────────────────────────────────────────────────────────────
// P12.8 — the number, and the two ways of computing it that would be worse
// than not having it.
//
// The spans already say what happened. The work is in what *not* to count: a
// call the policy gate stopped is the system working, and counting it against
// the role makes a well-behaved agent look incompetent — and makes the figure
// go *up* when the guard rails are loosened, which is the opposite of what
// anybody reading it wants to learn.
// ─────────────────────────────────────────────────────────────

private func attempt(_ role: Role = .engineer, _ tool: String = "run_shell",
                     succeeded: Bool, detail: String? = nil)
    -> ToolProficiencyReader.Attempt {
    ToolProficiencyReader.Attempt(role: role, tool: tool, succeeded: succeeded, detail: detail)
}

@Suite("Tool proficiency — P12.8")
struct ToolProficiencyTests {

    @Test("a plain run of successes and failures gives the rate")
    func countsOutcomes() {
        let found = ToolProficiencyReader.aggregate(
            (0..<7).map { attempt(succeeded: $0 < 5) })
        #expect(found.count == 1)
        #expect(found[0].attempts == 7)
        #expect(found[0].succeeded == 5)
        #expect(found[0].successRate.map { Int(($0 * 100).rounded()) } == 71)
    }

    // The rule that decides whether this number is worth showing at all.
    @Test("a call the rules stopped is not counted against the role")
    func ruleRefusalsAreNotFailures() {
        let found = ToolProficiencyReader.aggregate([
            attempt(succeeded: true), attempt(succeeded: true), attempt(succeeded: true),
            attempt(succeeded: true), attempt(succeeded: true),
            attempt(succeeded: false, detail: "policy hard stop [high]: ห้ามลบฐานข้อมูล"),
            attempt(succeeded: false, detail: "stage gate: ยังไม่ผ่านประตู"),
            attempt(succeeded: false, detail: "denied [high]: ผู้ใช้ไม่อนุมัติ"),
            attempt(succeeded: false, detail: "plan-only mode"),
        ])
        #expect(found[0].attempts == 5)
        #expect(found[0].succeeded == 5)
        #expect(found[0].blockedByRules == 4)
        #expect(found[0].successRate == 1.0)
    }

    // Not hidden either: "this role keeps trying things the rules forbid" is
    // worth knowing, and is a different fact from being bad at the tool.
    @Test("blocked calls are reported beside the rate, not swallowed")
    func blockedCallsAreShown() {
        let found = ToolProficiencyReader.aggregate(
            (0..<5).map { _ in attempt(succeeded: true) }
                + [attempt(succeeded: false, detail: "policy hard stop: x")])
        #expect(found[0].summary.contains("a rule blocked 1 more"))
        #expect(found[0].summary.contains("not counted against the role"))
    }

    // These three *are* the role's to get right: wrong arguments, work the
    // critic sent back, and a tool that ran and failed in its hands.
    @Test("bad arguments, a critic send-back and a real failure all count")
    func realFailuresCount() {
        let found = ToolProficiencyReader.aggregate([
            attempt(succeeded: false, detail: "precheck: ขาดอาร์กิวเมนต์ query"),
            attempt(succeeded: false, detail: "critic: คำสั่งนี้กว้างเกินไป"),
            attempt(succeeded: false, detail: "exit 1"),
            attempt(succeeded: true), attempt(succeeded: true),
        ])
        #expect(found[0].attempts == 5)
        #expect(found[0].succeeded == 2)
        #expect(found[0].blockedByRules == 0)
    }

    // One of one is 100% and means nothing.
    @Test("too few attempts gets no percentage, and says so")
    func smallSampleGetsNoNumber() {
        let found = ToolProficiencyReader.aggregate([attempt(succeeded: true)])
        #expect(found[0].successRate == nil)
        #expect(found[0].isTooFewToJudge)
        #expect(found[0].summary.contains("used too little to say anything"))
        #expect(found[0].summary.contains("100") == false)
    }

    @Test("exactly at the floor, a rate appears")
    func atTheFloorItReports() {
        let found = ToolProficiencyReader.aggregate(
            (0..<ToolProficiency.leastMeaningfulSample).map { _ in attempt(succeeded: true) })
        #expect(found[0].successRate == 1.0)
    }

    @Test("roles and tools are counted apart")
    func splitsByRoleAndTool() {
        let found = ToolProficiencyReader.aggregate([
            attempt(.engineer, "run_shell", succeeded: true),
            attempt(.engineer, "kb_search", succeeded: false),
            attempt(.writer, "run_shell", succeeded: true),
        ])
        #expect(found.count == 3)
    }

    // Sorted by use, not by rate: sorting by rate puts the single-call 100% at
    // the top, which is the reading this whole type exists to prevent.
    @Test("the most-used tool comes first, not the best-scoring one")
    func sortedByUse() {
        let found = ToolProficiencyReader.aggregate(
            [attempt(.engineer, "rare_tool", succeeded: true)]
                + (0..<6).map { _ in attempt(.engineer, "run_shell", succeeded: false) })
        #expect(found[0].tool == "run_shell")
    }

    // The prefixes are matched against what the gateway actually writes. If
    // that wording changes without this changing, refusals silently start
    // counting as incompetence.
    @Test("the refusal prefixes match the strings the gateway writes")
    func prefixesMatchTheGateway() {
        #expect(ToolProficiencyReader.wasBlockedByRules("policy hard stop [high]: …"))
        #expect(ToolProficiencyReader.wasBlockedByRules("stage gate: …"))
        #expect(ToolProficiencyReader.wasBlockedByRules("denied [medium]: …"))
        #expect(ToolProficiencyReader.wasBlockedByRules("plan-only mode"))
        #expect(ToolProficiencyReader.wasBlockedByRules("precheck: …") == false)
        #expect(ToolProficiencyReader.wasBlockedByRules("critic: …") == false)
        #expect(ToolProficiencyReader.wasBlockedByRules(nil) == false)
    }
}
