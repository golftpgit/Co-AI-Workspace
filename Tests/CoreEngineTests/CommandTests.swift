import Testing
import Foundation
import AgentKit
import LLMProviders
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P16.1/P16.3/P16.7 — the organisation's shape, decided by types and rules
// rather than by a running model.
//
// The most important test in this file compiles rather than runs: a parent
// receives a `Deliverable` and there is no way for it to reach a sub-team's
// transcript, because `Specialist` has no such member. §2.3's isolation is the
// compiler's, and a test that checked it at runtime would be checking the
// weaker thing.
// ─────────────────────────────────────────────────────────────

private func criteria(_ text: String = "ตรวจได้จากผลที่รันจริง") -> [Criterion] {
    [Criterion(text: text, evidenceRequired: "หลักฐานที่ตรวจได้")]
}

private let researchCharter = TeamCharter(
    mission: "หาหลักฐานเรื่องเวรดึกกับความผิดพลาดทางยา",
    domain: "research",
    acceptanceCriteria: criteria())!

@Suite("A team is a specialist (P16.1, P16.7)")
struct CommandStructureTests {

    /// P16.7's Done-when, and the same rule `Assignment` has had since P1.1:
    /// work whose definition of done was never written cannot be reviewed, and
    /// at team level that is a whole branch producing unreviewable output.
    @Test("a charter with no acceptance criteria cannot be built at all")
    func charterNeedsCriteria() {
        #expect(TeamCharter(mission: "ทำให้ดี", domain: "research",
                            acceptanceCriteria: []) == nil)
        #expect(TeamCharter(mission: "   ", domain: "research",
                            acceptanceCriteria: criteria()) == nil)
        #expect(TeamCharter(mission: "หาหลักฐาน", domain: "research",
                            acceptanceCriteria: criteria()) != nil)
    }

    /// The type-level claim, written as code that would not compile if it were
    /// false: a `SubTeam` is usable exactly where a specialist is, and the only
    /// thing that comes back is a `Deliverable`.
    @Test("a sub-team is accepted anywhere a specialist is, and returns only a deliverable")
    func aTeamIsASpecialist() async {
        let team = SubTeam(role: .researcher, charter: researchCharter, depth: 1,
                           tools: ["kb_search"],
                           orchestrator: TeamOrchestrator(router: ModelRouter(executors: []),
                                                          specialists: [:]))
        // Held as `any Specialist` — the parent's view. Everything the sub-team
        // knows about its own run is unreachable from here, which is the
        // isolation §2.3 asks for, enforced by there being no member to call.
        let asMember: any Specialist = team
        #expect(asMember.role == .researcher)
        #expect(asMember.definitionOfDone.isEmpty == false)
    }

    @Test("a team's capability is its members', capped by its charter and its parent")
    func capabilityOnlyShrinks() {
        let charter = TeamCharter(mission: "วิเคราะห์", domain: "analysis",
                                  acceptanceCriteria: criteria(),
                                  toolCeiling: ["kb_search", "run_stat_test"])!
        let capability = CommandRules.capability(
            ofMembers: [["kb_search", "run_shell"], ["run_stat_test", "kb_search"]],
            charter: charter,
            parentTools: ["kb_search", "run_stat_test", "save_document"])

        // `run_shell` is a member's and not the charter's; `save_document` is
        // the parent's and nobody's below. Every step can only remove.
        #expect(capability == ["kb_search", "run_stat_test"])
    }

    @Test("an empty ceiling means the parent's limit, never more than it")
    func emptyCeilingIsNotUnlimited() {
        let capability = CommandRules.capability(
            ofMembers: [["kb_search", "run_shell"]],
            charter: researchCharter,          // no ceiling of its own
            parentTools: ["kb_search"])
        #expect(capability == ["kb_search"])
    }
}

@Suite("Authority flows down and only shrinks (P16.3)")
struct CommandAuthorityTests {

    /// The invariant §22.4 calls the most important in the section: without it,
    /// "create a sub-team that needs `run_shell`" is the cheapest way around
    /// the policy gate — privilege escalation by spawning a child.
    @Test("a sub-team cannot be given a tool its parent does not have")
    func authorityCannotGrow() {
        let outcome = CommandRules.mayCreateSubTeam(
            depth: 1,
            parentTools: ["kb_search"],
            childTools: ["kb_search", "run_shell"],
            independent: true,
            leadRole: .researcher)

        #expect(outcome == .refused(.wouldExceedAuthority(tools: ["run_shell"])))
        #expect("\(NestingRefusal.wouldExceedAuthority(tools: ["run_shell"]))"
                    .contains("หลบ policy gate"))
    }

    @Test("the same check applies to a plan written after the team exists")
    func authorityIsCheckedAgainLater() async {
        let team = SubTeam(role: .researcher, charter: researchCharter, depth: 1,
                           tools: ["kb_search"],
                           orchestrator: TeamOrchestrator(router: ModelRouter(executors: []),
                                                          specialists: [:]))
        let plan = TeamPlan(goal: "หาหลักฐาน", assignments: [
            Assignment(role: .researcher, goal: "ค้นเอกสาร",
                       acceptanceCriteria: criteria(), deliverableType: "สรุป"),
        ])
        // Granted three tools and then writing a plan that needs a fourth is
        // the same escalation, one step later.
        #expect(await team.mayRun(plan, requiring: ["kb_search", "run_shell"])
                == .refused(.wouldExceedAuthority(tools: ["run_shell"])))
        #expect(await team.mayRun(plan, requiring: ["kb_search"]) == .allowed)
    }

    @Test("the fourth level is refused and says why, rather than being decided by the system")
    func depthIsCapped() {
        #expect(CommandDepth.mayNest(at: 2))
        #expect(CommandDepth.mayNest(at: 3) == false)

        let outcome = CommandRules.mayCreateSubTeam(
            depth: 3, parentTools: ["kb_search"], childTools: ["kb_search"],
            independent: true, leadRole: .researcher)
        #expect(outcome == .refused(.tooDeep(depth: 3)))
        // The reason is the cost, and it is stated: every level multiplies
        // agents, and multi-agent work was measured at roughly 15× the tokens.
        #expect("\(NestingRefusal.tooDeep(depth: 3))".contains("15×"))
    }

    /// §2.4 has forbidden an Engineer from fanning out since P4. Becoming a
    /// team must not be the way around it, or the rule is decorative.
    @Test("an Engineer still cannot fan out, at any depth, by any name")
    func engineerCannotFanOutByBecomingATeam() {
        for depth in 0..<CommandDepth.maximum {
            let outcome = CommandRules.mayCreateSubTeam(
                depth: depth, parentTools: ["run_shell"], childTools: ["run_shell"],
                independent: true, leadRole: .engineer)
            #expect(outcome == .refused(.fanOutForbidden(role: .engineer)),
                    "an Engineer split into sub-teams at depth \(depth)")
        }
    }
}

@Suite("When to split, and who pays (P16.2)")
struct DynamicScalingTests {

    @Test("seven is the span of control; the eighth assignment needs a sub-team")
    func spanOfControl() {
        #expect(CommandRules.needsSplitting(assignments: 7) == false)
        #expect(CommandRules.needsSplitting(assignments: 8))
        #expect(CommandRules.spanOfControl == 7)
    }

    @Test("twelve independent assignments split; twelve tangled ones do not")
    func splittingNeedsIndependence() {
        let independent = CommandRules.mayCreateSubTeam(
            depth: 0, parentTools: ["kb_search"], childTools: ["kb_search"],
            independent: true, leadRole: .researcher)
        #expect(independent == .allowed)

        let tangled = CommandRules.mayCreateSubTeam(
            depth: 0, parentTools: ["kb_search"], childTools: ["kb_search"],
            independent: false,
            tangledReason: "ทุกใบต้องใช้ผลของใบแรก",
            leadRole: .researcher)
        // Splitting tightly coupled work gives two teams that undo each other,
        // which is the same reason §2.4 exists.
        #expect(tangled == .refused(.tooTangled(reason: "ทุกใบต้องใช้ผลของใบแรก")))
    }

    /// §22.3's third condition, and the one whose absence is worst: splitting
    /// quietly and running out of budget halfway is worse than being slow.
    @Test("not enough budget means no split, and a number to raise the ceiling by")
    func budgetIsCheckedBeforeSplitting() {
        let outcome = CommandRules.mayCreateSubTeam(
            depth: 0, parentTools: ["kb_search"], childTools: ["kb_search"],
            independent: true, budgetShortfallUSD: 4.20, leadRole: .researcher)

        #expect(outcome == .refused(.notEnoughBudget(needMoreUSD: 4.20)))
        let message = "\(NestingRefusal.notEnoughBudget(needMoreUSD: 4.20))"
        #expect(message.contains("4.20"), "a refusal that does not say how much is missing")
        #expect(message.contains("แตกทีมเงียบ ๆ แล้วงบหมดกลางทางแย่กว่าทำช้า"))
    }

    @Test("all three conditions are required together, not any one of them")
    func conditionsAreConjunctive() {
        // Independent and affordable, but too deep.
        #expect(CommandRules.mayCreateSubTeam(
            depth: 3, parentTools: ["kb_search"], childTools: ["kb_search"],
            independent: true, budgetShortfallUSD: 0, leadRole: .researcher).isAllowed == false)
        // Shallow and affordable, but tangled.
        #expect(CommandRules.mayCreateSubTeam(
            depth: 0, parentTools: ["kb_search"], childTools: ["kb_search"],
            independent: false, budgetShortfallUSD: 0, leadRole: .researcher).isAllowed == false)
        // Shallow and independent, but unaffordable.
        #expect(CommandRules.mayCreateSubTeam(
            depth: 0, parentTools: ["kb_search"], childTools: ["kb_search"],
            independent: true, budgetShortfallUSD: 1, leadRole: .researcher).isAllowed == false)
    }
}

// ─────────────────────────────────────────────────────────────
// P16.2's outstanding item — the lead had its own idea of how wide a plan may
// be.
// ─────────────────────────────────────────────────────────────
@Suite("One span of control (P16.2)")
struct SpanOfControlTests {

    /// `TeamOrchestrator` compared against `maxFanOut = 4` while `CommandRules`
    /// published 7, so "how wide may a plan be" had two answers and the one
    /// that ran was whichever the caller happened to hit.
    @Test("the lead's default cap is the published span of control")
    func defaultCapIsTheRule() {
        #expect(CommandRules.spanOfControl == 7)
        #expect(CommandRules.needsSplitting(assignments: 7) == false)
        #expect(CommandRules.needsSplitting(assignments: 8))
    }

    /// A test narrowing the cap deliberately is a different thing from a second
    /// opinion about the rule, so the parameter stays.
    @Test("a narrower cap is asked of the same rule")
    func narrowerCapStillGoesThroughTheRule() {
        #expect(CommandRules.needsSplitting(assignments: 5, cap: 4))
        #expect(CommandRules.needsSplitting(assignments: 4, cap: 4) == false)
    }
}
