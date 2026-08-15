import Testing
import Foundation
import AgentKit
import Observability
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// The one thing that must hold: a tool cannot run unless the hook chain let
// it. v1 shipped a bug where one call path skipped the gate entirely, and a
// test shaped exactly like these is what caught it — so every refusal branch
// here asserts on whether the *tool body* ran, never on the return value.
// ─────────────────────────────────────────────────────────────

/// Records the fact of being called. Nothing else about it matters.
private struct SpyTool: AgentTool {
    let name: String
    let toolDescription = "spy"
    let riskLevel: RiskLevel
    let parametersJSON: String
    let ran: Ledger

    init(name: String = "run_shell",
         risk: RiskLevel = .high,
         parametersJSON: String = #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#,
         ran: Ledger) {
        self.name = name
        self.riskLevel = risk
        self.parametersJSON = parametersJSON
        self.ran = ran
    }

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        await ran.record(argumentsJSON)
        return ToolOutput(text: "ran")
    }
}

private actor Ledger {
    private(set) var calls: [String] = []
    func record(_ arguments: String) { calls.append(arguments) }
    var count: Int { calls.count }
}

private struct FixedApprover: ApprovalRequesting {
    let decision: ApprovalDecision
    let seen: Ledger?
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await seen?.record(request.detail)
        return decision
    }
}

private struct AlwaysConflicting: PolicyGate {
    let rule: String
    func conflict(with call: PendingToolCall, risk: RiskAssessment) async -> String? { rule }
}

private let shellArguments = #"{"command":"echo hi"}"#

private func context() -> ToolContext {
    ToolContext(scope: .central, workingDirectory: URL(fileURLWithPath: "/tmp"), conversationID: "cv_test")
}

@Suite("Nothing reaches a tool except through the gate")
struct GateInvariantTests {
    @Test("an approved high-risk call runs, and only then")
    func approvedRuns() async throws {
        let ran = Ledger()
        let gateway = ToolGateway(approver: FixedApprover(decision: .approved, seen: nil),
                                  modes: OperatingModes(autonomy: .balanced))
        await gateway.register(SpyTool(ran: ran))

        let outcome = try await gateway.call("run_shell", argumentsJSON: shellArguments, context: context())
        #expect(outcome.didExecute)
        #expect(await ran.count == 1)
    }

    @Test("a rejected approval never reaches the tool body")
    func rejectionNeverRuns() async throws {
        let ran = Ledger()
        let gateway = ToolGateway(approver: FixedApprover(decision: .rejected(reason: "อย่าเพิ่ง"), seen: nil),
                                  modes: OperatingModes(autonomy: .balanced))
        await gateway.register(SpyTool(ran: ran))

        let outcome = try await gateway.call("run_shell", argumentsJSON: shellArguments, context: context())
        guard case .denied(let reason) = outcome else {
            Issue.record("expected denial, got \(outcome)"); return
        }
        #expect(reason == "อย่าเพิ่ง")
        #expect(await ran.count == 0)
    }

    /// The case v1 got wrong: with no channel able to ask, it ran anyway.
    @Test("no approver means denied, not allowed")
    func missingApproverDenies() async throws {
        let ran = Ledger()
        let gateway = ToolGateway(approver: nil, modes: OperatingModes(autonomy: .balanced))
        await gateway.register(SpyTool(ran: ran))

        let outcome = try await gateway.call("run_shell", argumentsJSON: shellArguments, context: context())
        #expect(!outcome.didExecute)
        #expect(await ran.count == 0)
    }

    @Test("plan-only mode blocks execution regardless of risk or autonomy")
    func planOnlyBlocksEverything() async throws {
        let ran = Ledger()
        let gateway = ToolGateway(approver: FixedApprover(decision: .approved, seen: nil),
                                  modes: OperatingModes(autonomy: .fullAutonomous, planOnly: true))
        await gateway.register(SpyTool(name: "kb_search", risk: .low,
                                       parametersJSON: #"{"type":"object","properties":{}}"#, ran: ran))

        let outcome = try await gateway.call("kb_search", argumentsJSON: "{}", context: context())
        guard case .planOnly = outcome else { Issue.record("expected plan-only, got \(outcome)"); return }
        #expect(await ran.count == 0)
    }

    /// Full autonomous turns off *approval*, not the policy gate.
    @Test("a policy hard stop outranks full autonomy")
    func policyOutranksAutonomy() async throws {
        let ran = Ledger()
        let chain = HookChain(policyGate: AlwaysConflicting(rule: "ห้ามลบข้อมูลผู้ป่วยทุกกรณี"))
        let gateway = ToolGateway(chain: chain, approver: FixedApprover(decision: .approved, seen: nil),
                                  modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(SpyTool(ran: ran))

        let outcome = try await gateway.call("run_shell", argumentsJSON: shellArguments, context: context())
        guard case .blockedByPolicy(let rule) = outcome else {
            Issue.record("expected a hard stop, got \(outcome)"); return
        }
        // The human sees the rule itself, not "risky" (§11.2).
        #expect(rule == "ห้ามลบข้อมูลผู้ป่วยทุกกรณี")
        #expect(outcome.transcriptText.contains("ห้ามลบข้อมูลผู้ป่วยทุกกรณี"))
        #expect(await ran.count == 0)
    }

    @Test("a call the critic sends back never runs")
    func criticSendBackNeverRuns() async throws {
        let ran = Ledger()
        let gateway = ToolGateway(approver: FixedApprover(decision: .approved, seen: nil),
                                  modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(SpyTool(ran: ran))

        // `command` is required by the schema and missing here.
        let outcome = try await gateway.call("run_shell", argumentsJSON: "{}", context: context())
        guard case .sentBack(let reason) = outcome else {
            Issue.record("expected send-back, got \(outcome)"); return
        }
        #expect(reason.contains("command"))
        #expect(await ran.count == 0)
    }

    @Test("an unknown tool name is reported, not guessed at")
    func unknownToolIsNamed() async throws {
        let gateway = ToolGateway()
        let outcome = try await gateway.call("does_not_exist", argumentsJSON: "{}", context: context())
        guard case .unknownTool(let name) = outcome else {
            Issue.record("expected unknownTool, got \(outcome)"); return
        }
        #expect(name == "does_not_exist")
    }

    /// The structural half of the invariant: what the gateway hands out cannot
    /// be invoked. If `adverts` ever returned `any AgentTool`, every test above
    /// would still pass and the guarantee would be gone.
    @Test("the gateway advertises tools without vending anything callable")
    func advertsAreInert() async throws {
        let ran = Ledger()
        let gateway = ToolGateway()
        await gateway.register(SpyTool(ran: ran))

        let adverts = await gateway.adverts
        #expect(adverts.count == 1)
        #expect(adverts[0].name == "run_shell")
        #expect(adverts[0].declaredRisk == .high)
        #expect(ToolAdvert.self is any Sendable.Type)
        #expect(await ran.count == 0)
    }

    // P15.4 — the tool list is part of the cached prefix.
    //
    // vLLM caches by token prefix, and the tool list is rendered into the
    // prompt ahead of the conversation. Two tools registered in a different
    // order on the next launch — a plugin loading a moment sooner, an MCP
    // server answering first — would render a different prefix and quietly cost
    // every conversation its cache. Measured: a hit is 0.32s to first token
    // against 3.35s cold (E.24), so this is 3 seconds per turn hanging off an
    // ordering nobody would think to keep stable.
    @Test("the advertised tool list is in the same order however it was registered")
    func advertOrderIsStable() async throws {
        let ran = Ledger()
        let forwards = ToolGateway()
        await forwards.register(SpyTool(name: "a_tool", ran: ran))
        await forwards.register(SpyTool(name: "m_tool", ran: ran))
        await forwards.register(SpyTool(name: "z_tool", ran: ran))

        let backwards = ToolGateway()
        await backwards.register(SpyTool(name: "z_tool", ran: ran))
        await backwards.register(SpyTool(name: "m_tool", ran: ran))
        await backwards.register(SpyTool(name: "a_tool", ran: ran))

        let first = await forwards.adverts.map(\.name)
        let second = await backwards.adverts.map(\.name)
        #expect(first == ["a_tool", "m_tool", "z_tool"])
        #expect(first == second, "the same tools rendered a different prompt prefix")
    }

    @Test("a human's edit is what actually runs")
    func editedArgumentsAreTheOnesExecuted() async throws {
        let ran = Ledger()
        let edited = #"{"command":"echo แก้แล้ว"}"#
        let gateway = ToolGateway(approver: FixedApprover(decision: .approvedWithEdit(argumentsJSON: edited),
                                                          seen: nil),
                                  modes: OperatingModes(autonomy: .approvalRequired))
        await gateway.register(SpyTool(ran: ran))

        _ = try await gateway.call("run_shell", argumentsJSON: shellArguments, context: context())
        #expect(await ran.calls == [edited])
    }

    @Test("every gate decision leaves a span behind")
    func decisionsAreObservable() async throws {
        let sink = InMemorySpanSink()
        let ran = Ledger()
        let gateway = ToolGateway(approver: nil, spanSink: sink,
                                  modes: OperatingModes(autonomy: .approvalRequired))
        await gateway.register(SpyTool(ran: ran))

        _ = try await gateway.call("run_shell", argumentsJSON: shellArguments, context: context())
        let spans = await sink.spans(named: "tool:run_shell")
        #expect(spans.count == 1)
        #expect(spans.first?.status == .cancelled)
    }
}

@Suite("Autonomy thresholds")
struct AutonomyTests {
    @Test("full autonomous runs high-risk work without asking")
    func fullAutonomousDoesNotAsk() async throws {
        let ran = Ledger()
        let asked = Ledger()
        let gateway = ToolGateway(approver: FixedApprover(decision: .approved, seen: asked),
                                  modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(SpyTool(ran: ran))

        _ = try await gateway.call("run_shell", argumentsJSON: shellArguments, context: context())
        #expect(await ran.count == 1)
        #expect(await asked.count == 0)
    }

    @Test("approval-required asks about medium-risk work that balanced lets through")
    func thresholdsDiffer() async throws {
        let write = #"{"path":"/tmp/x.md","text":"hi"}"#
        let schema = #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#

        for (mode, expectedAsks) in [(OperatingModes.Autonomy.approvalRequired, 1),
                                     (OperatingModes.Autonomy.balanced, 0)] {
            let ran = Ledger()
            let asked = Ledger()
            let gateway = ToolGateway(approver: FixedApprover(decision: .approved, seen: asked),
                                      modes: OperatingModes(autonomy: mode))
            await gateway.register(SpyTool(name: "write_file", risk: .medium,
                                           parametersJSON: schema, ran: ran))

            _ = try await gateway.call("write_file", argumentsJSON: write, context: context())
            #expect(await ran.count == 1)
            #expect(await asked.count == expectedAsks, "autonomy \(mode)")
        }
    }
}
