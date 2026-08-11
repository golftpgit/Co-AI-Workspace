import Testing
import Foundation
import AgentKit
import Knowledge
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P2.6's Done-when: an action that breaks a hard constraint is stopped, and
// what the human sees is the rule itself.
//
// The gate is checked through `ToolGateway`, not in isolation, because the
// invariant that matters is "the tool did not run" — not "a function returned
// a refusal" (the same reason P1.7's tests are written that way).
// ─────────────────────────────────────────────────────────────

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct DeleteTool: AgentTool {
    let name = "run_shell"
    let toolDescription = "รันคำสั่งเชลล์"
    let riskLevel: RiskLevel = .medium
    let parametersJSON = #"{"type":"object","properties":{"command":{"type":"string"}}}"#
    let ran: Counter

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        await ran.increment()
        return ToolOutput(text: "ran")
    }
}

private let policyDocument = """
- ห้ามลบฐานข้อมูลผลการทดลอง
- ควรสำรองข้อมูลทุกสัปดาห์
"""

private func library() -> PolicyLibrary {
    PolicyLibrary(rules: PolicyDocumentParser().rules(
        in: policyDocument,
        provenance: Provenance(documentID: "policy_1", title: "นโยบายข้อมูลผู้ป่วย",
                               origin: .upload(filename: "policy.md"), tier: .t1)))
}

@Suite("Policy gate")
struct PolicyGateTests {
    @Test("a hard constraint stops the tool from running at all")
    func hardConstraintStopsTheCall() async throws {
        let ran = Counter()
        // Full autonomy on purpose: a hard constraint is not an approval that
        // a permissive setting can wave through.
        let gateway = ToolGateway(
            chain: HookChain(policyGate: KnowledgePolicyGate(library: library())),
            modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(DeleteTool(ran: ran))

        let outcome = try await gateway.call(
            "run_shell",
            argumentsJSON: #"{"command":"ลบฐานข้อมูลผลการทดลอง ทั้งหมด"}"#,
            context: ToolContext(scope: .central))

        #expect(await ran.value == 0, "the tool ran despite a hard constraint")
        guard case .blockedByPolicy(let reason) = outcome else {
            Issue.record("expected a policy block, got \(outcome)")
            return
        }
        // The Done-when: the rule is shown, not a summary of it.
        #expect(reason.contains("ห้ามลบฐานข้อมูลผลการทดลอง"), "reason was: \(reason)")
        #expect(reason.contains("นโยบายข้อมูลผู้ป่วย"), "no source document: \(reason)")
    }

    @Test("an action no rule covers still runs")
    func unrelatedActionRuns() async throws {
        let ran = Counter()
        let gateway = ToolGateway(
            chain: HookChain(policyGate: KnowledgePolicyGate(library: library())),
            modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(DeleteTool(ran: ran))

        _ = try await gateway.call("run_shell",
                                   argumentsJSON: #"{"command":"swift test"}"#,
                                   context: ToolContext(scope: .central))
        #expect(await ran.value == 1, "an unrelated command was blocked")
    }

    @Test("advice does not stop anything")
    func adviceDoesNotBlock() async throws {
        let ran = Counter()
        let gateway = ToolGateway(
            chain: HookChain(policyGate: KnowledgePolicyGate(library: library())),
            modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(DeleteTool(ran: ran))

        _ = try await gateway.call("run_shell",
                                   argumentsJSON: #"{"command":"สำรองข้อมูลทุกสัปดาห์"}"#,
                                   context: ToolContext(scope: .central))
        #expect(await ran.value == 1, "guidance was treated as a prohibition")
    }

    @Test("an empty policy set is not a clean bill of health")
    func emptyPolicyStillRuns() async throws {
        // The placeholder P1 shipped was named NoPolicyGate so nobody would
        // read "no rules" as "checked and clean". An empty library behaves the
        // same way: it permits, and says nothing about safety.
        let ran = Counter()
        let gateway = ToolGateway(
            chain: HookChain(policyGate: KnowledgePolicyGate(library: PolicyLibrary(rules: []))),
            modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(DeleteTool(ran: ran))

        _ = try await gateway.call("run_shell",
                                   argumentsJSON: #"{"command":"ลบฐานข้อมูลผลการทดลอง"}"#,
                                   context: ToolContext(scope: .central))
        #expect(await ran.value == 1)
    }
}
