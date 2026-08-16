import Testing
import Foundation
import AgentKit
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P20.4 — what the system knows about its own reliability reaches the
// decision, not just the screen.
//
// §24.3 asks for confidence to be shown where somebody is about to approve.
// The Done-when is stricter and is the part worth building: **low confidence
// closes the automatic path**. A percentage displayed beside an approve button
// that was never going to appear is decoration.
// ─────────────────────────────────────────────────────────────

private struct SpyTool: AgentTool {
    let name = "run_stat_test"
    let toolDescription = "รันการทดสอบ"
    let riskLevel: RiskLevel = .low
    let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        ToolOutput(text: "ran")
    }
}

private struct RecordingApprover: ApprovalRequesting {
    let asked: Asked
    let decision: ApprovalDecision

    actor Asked {
        private(set) var requests: [ApprovalRequest] = []
        func record(_ request: ApprovalRequest) { requests.append(request) }
        var count: Int { requests.count }
        var lastDetail: String { requests.last?.detail ?? "" }
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await asked.record(request)
        return decision
    }
}

private func call(role: Role? = .analyst) -> PendingToolCall {
    PendingToolCall(toolName: "run_stat_test",
                    toolDescription: "รันการทดสอบ",
                    declaredRisk: .low,
                    parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
                    argumentsJSON: "{}",
                    context: ToolContext(scope: .central, role: role))
}

private func chain(rate: (attempts: Int, succeeded: Int)?) -> HookChain {
    guard let rate else { return HookChain() }
    let attempts = rate.attempts, succeeded = rate.succeeded
    return HookChain(proficiency: { @Sendable _, tool in
        ToolProficiency(role: .analyst, tool: tool,
                        attempts: attempts, succeeded: succeeded, blockedByRules: 0)
    })
}

@Suite("Low confidence closes the automatic path (P20.4)")
struct ConfidenceGateTests {
    private let fullyAutonomous = OperatingModes(autonomy: .fullAutonomous)

    /// The Done-when. Full autonomy, a low-risk tool — everything about this
    /// call says "run it" except the record of how it has gone before.
    @Test("a role that keeps failing this tool gets a person, whatever the slider says")
    func lowConfidenceForcesApproval() async {
        let asked = RecordingApprover.Asked()
        let verdict = await chain(rate: (attempts: 10, succeeded: 4))
            .evaluate(call(), modes: fullyAutonomous,
                      approver: RecordingApprover(asked: asked, decision: .approved))

        #expect(await asked.count == 1, "full autonomy ran a call the system does not trust")
        guard case .allow(_, _, let notes) = verdict else {
            Issue.record("expected an allow after approval, got \(verdict)")
            return
        }
        #expect(notes.contains { $0.contains("ความมั่นใจต่ำ") })
    }

    @Test("the person deciding is told the number, in front of the decision")
    func theNumberReachesTheDecision() async {
        let asked = RecordingApprover.Asked()
        _ = await chain(rate: (attempts: 12, succeeded: 3))
            .evaluate(call(), modes: fullyAutonomous,
                      approver: RecordingApprover(asked: asked, decision: .approved))

        let detail = await asked.lastDetail
        #expect(detail.contains("25%"))
        #expect(detail.contains("ต่ำกว่าเกณฑ์"))
    }

    @Test("a role that does well is not interrupted")
    func highConfidenceStaysAutomatic() async {
        // A gate that asks about everything is a gate people switch off.
        let asked = RecordingApprover.Asked()
        let verdict = await chain(rate: (attempts: 20, succeeded: 19))
            .evaluate(call(), modes: fullyAutonomous,
                      approver: RecordingApprover(asked: asked, decision: .approved))

        #expect(await asked.count == 0)
        guard case .allow = verdict else {
            Issue.record("a reliable call was interrupted: \(verdict)")
            return
        }
    }

    /// `ToolProficiency` refuses to report a rate below five attempts, and that
    /// refusal has to mean "no reason to doubt" here — otherwise every new tool
    /// starts life needing a human, and the first thing anybody does is turn
    /// the gate off.
    @Test("too few attempts to judge is not the same as judged badly")
    func tooFewAttemptsDoesNotBlock() async {
        let asked = RecordingApprover.Asked()
        _ = await chain(rate: (attempts: 3, succeeded: 0))
            .evaluate(call(), modes: fullyAutonomous,
                      approver: RecordingApprover(asked: asked, decision: .approved))
        #expect(await asked.count == 0)
    }

    @Test("a build with no proficiency store does not start asking about everything")
    func noStoreMeansNoDoubt() async {
        let asked = RecordingApprover.Asked()
        _ = await chain(rate: nil)
            .evaluate(call(), modes: fullyAutonomous,
                      approver: RecordingApprover(asked: asked, decision: .approved))
        #expect(await asked.count == 0)
    }

    @Test("with no way to ask, low confidence denies rather than proceeding")
    func noApproverIsADenial() async {
        // The same rule the chain has had since P1: the absence of a channel is
        // not permission.
        let verdict = await chain(rate: (attempts: 10, succeeded: 2))
            .evaluate(call(), modes: fullyAutonomous, approver: nil)
        guard case .denied = verdict else {
            Issue.record("an untrusted call ran with nobody to ask: \(verdict)")
            return
        }
    }
}
