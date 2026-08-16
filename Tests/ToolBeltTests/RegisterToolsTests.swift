import Testing
import Foundation
import AgentKit
import ProjectKit
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// P10.8's Done-when, at the layer it was written for: **an agent can propose a
// risk and cannot decide a change.**
//
// It was only testable at the type level before, because there were no tools —
// which meant the rule was true of the types and untested of the system. These
// go through the tools an agent actually calls.
// ─────────────────────────────────────────────────────────────

private actor Filed: RegisterFiling {
    private(set) var entries: [RegisterEntry] = []
    func record(_ entry: RegisterEntry) async throws { entries.append(entry) }
    func first() -> RegisterEntry? { entries.first }
}

private func context(_ scope: Scope = .project(ProjectID("pj1")),
                     role: Role? = .analyst) -> ToolContext {
    ToolContext(scope: scope, role: role)
}

@Suite("An agent proposes and does not decide (P10.8)")
struct RegisterToolsTests {

    @Test("a risk filed by an agent is recorded as filed by that agent")
    func riskCarriesItsOrigin() async throws {
        let filed = Filed()
        let tool = RaiseRiskTool(service: { filed })
        _ = try await tool.call(
            argumentsJSON: #"{"title":"ข้อมูลดิบอาจมาไม่ทัน","probability":3,"impact":4,"response":"reduce"}"#,
            context: context())

        let entry = try #require(await filed.first())
        #expect(entry.kind == .risk)
        // Taken from the context. There is no argument an agent could pass to
        // claim it was a person — which is the only version of this rule that
        // survives a manifest somebody else wrote.
        #expect(entry.origin == .agent(.analyst))
        #expect(entry.origin.isHuman == false)
        #expect(entry.status.isOpen)
    }

    /// The Done-when's second half. `propose_change` files `proposed`, and
    /// there is no tool anywhere that can move it to approved.
    @Test("a change proposed by an agent stays waiting for a person")
    func changeIsOnlyProposed() async throws {
        let filed = Filed()
        let tool = ProposeChangeTool(service: { filed })
        let output = try await tool.call(
            argumentsJSON: #"""
            {"title":"ขอเลื่อนส่งบทที่ 3","scope_impact":"ไม่กระทบ",
             "time_impact":"ช้าลง 1 สัปดาห์","cost_impact":"ไม่กระทบ"}
            """#,
            context: context(role: .writer))

        let entry = try #require(await filed.first())
        #expect(entry.status == .proposed)
        #expect(entry.decidedBy == nil)
        #expect(entry.origin == .agent(.writer))
        #expect(output.text.contains("รอตัดสิน"))
        // Deciding takes a person's name and lives on the other side of the
        // gate; nothing on the tool list reaches it.
        #expect(throws: RegisterError.self) {
            _ = try entry.decided(approve: true, by: "   ")
        }
    }

    @Test("a made-up score is refused rather than clamped")
    func scoresAreNotClamped() {
        // Clamping would file an invented number under a field that says it was
        // assessed.
        #expect(throws: ToolError.self) {
            _ = try RaiseRiskTool.arguments(
                #"{"title":"x","probability":9,"impact":4,"response":"reduce"}"#)
        }
        #expect(throws: ToolError.self) {
            _ = try RaiseRiskTool.arguments(
                #"{"title":"x","probability":3,"impact":4,"response":"ignore"}"#)
        }
        #expect(throws: ToolError.self) {
            _ = try RaiseRiskTool.arguments(
                #"{"title":"  ","probability":3,"impact":4,"response":"accept"}"#)
        }
    }

    /// A change request with a blank column has its cost decided by whoever
    /// reads it most optimistically.
    @Test("a change request must say what it does to all three")
    func allThreeImpactsRequired() {
        #expect(throws: ToolError.self) {
            _ = try ProposeChangeTool.arguments(
                #"{"title":"x","scope_impact":"","time_impact":"ช้าลง","cost_impact":"ไม่กระทบ"}"#)
        }
        let ok = try? ProposeChangeTool.arguments(
            #"{"title":"x","scope_impact":"ไม่กระทบ","time_impact":"ช้าลง","cost_impact":"ไม่กระทบ"}"#)
        #expect(ok?.scope == "ไม่กระทบ")
    }

    /// A project risk filed into General is filed nowhere.
    @Test("outside a project both tools refuse and say where it would have gone")
    func refusedOutsideAProject() async {
        let filed = Filed()
        let tool = RaiseRiskTool(service: { filed })
        do {
            _ = try await tool.call(
                argumentsJSON: #"{"title":"x","probability":3,"impact":3,"response":"accept"}"#,
                context: context(.central))
            Issue.record("filed a project risk with no project")
        } catch let error as ToolError {
            #expect("\(error)".contains("โปรเจกต์"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await filed.entries.isEmpty)
    }
}
