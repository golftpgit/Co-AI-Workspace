import Testing
import Foundation
import AgentKit
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// The Stage Gate in the hook chain (ARCHITECTURE §19.4, P10.2).
//
// The Done-when for P10.2 is that a tool with side effects is refused while the
// project is still in Initiation — from the same path a session uses, not from
// a direct call to the gate. So these go through `ToolGateway.call`, which is
// the only door there is.
// ─────────────────────────────────────────────────────────────

private struct StubStage: ProjectStageReading {
    let stages: [String: ProjectStage]
    func stage(of id: ProjectID) async -> ProjectStage? { stages[id.rawValue] }
}

/// Records whether it ran, so "refused" can be told apart from "ran and
/// returned nothing" — which look identical from the outside.
private final class RanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var ran: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}

private struct SpyTool: AgentTool {
    let name: String
    let riskLevel: RiskLevel
    let flag: RanFlag
    var toolDescription: String { "spy" }
    var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        flag.mark()
        return ToolOutput(text: "ran")
    }
}

private func gateway(stages: [String: ProjectStage], tools: [any AgentTool]) async -> ToolGateway {
    let chain = HookChain(stageGate: StageGate(reader: StubStage(stages: stages)))
    let gateway = ToolGateway(chain: chain,
                              modes: OperatingModes(autonomy: .fullAutonomous))
    await gateway.register(tools)
    return gateway
}

@Suite("Stage gate")
struct StageGateTests {

    @Test("Initiation refuses a tool that would change something")
    func initiationBlocksMutating() async throws {
        let flag = RanFlag()
        let gateway = await gateway(stages: ["p1": .initiation],
                                    tools: [SpyTool(name: "run_shell", riskLevel: .high, flag: flag)])

        let outcome = try await gateway.call("run_shell", argumentsJSON: "{}",
                                             context: ToolContext(scope: .project(ProjectID("p1"))))
        guard case .blockedByStage(let reason) = outcome else {
            Issue.record("expected a stage refusal, got \(outcome)")
            return
        }
        #expect(!flag.ran)
        // The refusal has to say what would move it on, or the model retries
        // the same call until the budget runs out.
        #expect(reason.contains("G1"))
    }

    @Test("Initiation still allows reading — a brief is written from something")
    func initiationAllowsReads() async throws {
        let flag = RanFlag()
        let gateway = await gateway(stages: ["p1": .initiation],
                                    tools: [SpyTool(name: "kb_search", riskLevel: .low, flag: flag)])

        let outcome = try await gateway.call("kb_search", argumentsJSON: "{}",
                                             context: ToolContext(scope: .project(ProjectID("p1"))))
        #expect(outcome.didExecute)
        #expect(flag.ran)
    }

    @Test("Planning allows authoring but not mutation")
    func planningIsReadAndDraft() async throws {
        let authored = RanFlag(), mutated = RanFlag()
        let gateway = await gateway(
            stages: ["p1": .planning],
            tools: [SpyTool(name: "save_document", riskLevel: .medium, flag: authored),
                    SpyTool(name: "analysis_execute", riskLevel: .medium, flag: mutated)])
        let context = ToolContext(scope: .project(ProjectID("p1")))

        #expect(try await gateway.call("save_document", argumentsJSON: "{}", context: context).didExecute)
        let blocked = try await gateway.call("analysis_execute", argumentsJSON: "{}", context: context)
        #expect(!blocked.didExecute)
        #expect(!mutated.ran)
        // Same risk level, different answer: risk is about how much damage a
        // call could do, the stage is about whether the work is due yet.
        #expect(authored.ran)
    }

    @Test("Execution allows everything the risk chain allows")
    func executionIsOpen() async throws {
        let flag = RanFlag()
        let gateway = await gateway(stages: ["p1": .execution],
                                    tools: [SpyTool(name: "run_shell", riskLevel: .high, flag: flag)])

        #expect(try await gateway.call("run_shell", argumentsJSON: "{}",
                                       context: ToolContext(scope: .project(ProjectID("p1")))).didExecute)
    }

    @Test("a closed project stays readable and nothing else")
    func closedIsReadOnly() async throws {
        let read = RanFlag(), write = RanFlag()
        let gateway = await gateway(
            stages: ["p1": .closed],
            tools: [SpyTool(name: "kb_search", riskLevel: .low, flag: read),
                    SpyTool(name: "save_document", riskLevel: .medium, flag: write)])
        let context = ToolContext(scope: .project(ProjectID("p1")))

        #expect(try await gateway.call("kb_search", argumentsJSON: "{}", context: context).didExecute)
        #expect(!(try await gateway.call("save_document", argumentsJSON: "{}", context: context).didExecute))
        #expect(!write.ran)
    }

    @Test("General is not gated — there is no project to be in a stage")
    func centralScopeIsUntouched() async throws {
        let flag = RanFlag()
        let gateway = await gateway(stages: [:],
                                    tools: [SpyTool(name: "run_shell", riskLevel: .high, flag: flag)])

        #expect(try await gateway.call("run_shell", argumentsJSON: "{}",
                                       context: ToolContext(scope: .central)).didExecute)
    }

    @Test("an unknown project is refused, not waved through")
    func unknownProjectIsRefused() async throws {
        let flag = RanFlag()
        let gateway = await gateway(stages: ["p1": .execution],
                                    tools: [SpyTool(name: "kb_search", riskLevel: .low, flag: flag)])

        let outcome = try await gateway.call("kb_search", argumentsJSON: "{}",
                                             context: ToolContext(scope: .project(ProjectID("ghost"))))
        #expect(!outcome.didExecute)
        #expect(!flag.ran)
    }

    @Test("a tool nobody classified is treated as the most dangerous kind")
    func unclassifiedToolsAreMutating() async throws {
        // A new tool added without a row in the effect table must not get the
        // most permissive treatment by default — that quiet default is how
        // capabilities have slipped past rules in this project before.
        #expect(StageGate.effect(of: "some_new_tool") == .mutating)

        let flag = RanFlag()
        let gateway = await gateway(stages: ["p1": .planning],
                                    tools: [SpyTool(name: "some_new_tool", riskLevel: .low, flag: flag)])
        #expect(!(try await gateway.call("some_new_tool", argumentsJSON: "{}",
                                         context: ToolContext(scope: .project(ProjectID("p1")))).didExecute))
    }

    @Test("a project-scoped call with no way to read the stage is refused")
    func noReaderIsNotPermission() async throws {
        let flag = RanFlag()
        let chain = HookChain(stageGate: .disabled)
        let gateway = ToolGateway(chain: chain, modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(SpyTool(name: "run_shell", riskLevel: .high, flag: flag))

        // Same rule the HITL step already follows: no way to check is a
        // refusal, not permission.
        let outcome = try await gateway.call("run_shell", argumentsJSON: "{}",
                                             context: ToolContext(scope: .project(ProjectID("p1"))))
        #expect(!outcome.didExecute)
        #expect(!flag.ran)
    }

    @Test("every tool the risk table classifies also has an effect")
    func tablesAgree() async throws {
        // The two tables are keyed by the same names on purpose. A tool
        // classified for risk but not for effect would fall to `.mutating` and
        // quietly stop working outside Execution; one classified for effect but
        // not risk would skip the risk floor. check.sh fails on either.
        let risk = Set(DefaultRiskScorer.baseline.keys)
        let effect = Set(StageGate.effects.keys)
        #expect(risk == effect, "risk-only: \(risk.subtracting(effect)) · effect-only: \(effect.subtracting(risk))")
    }
}
