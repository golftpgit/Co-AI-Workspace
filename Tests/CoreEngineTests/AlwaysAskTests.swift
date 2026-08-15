import Testing
import Foundation
import AgentKit
import LLMProviders
@testable import CoreEngine


// ─────────────────────────────────────────────────────────────
// P14.4 — the tools that ask a person whatever the slider says.
//
// The claim that matters is the P1.7 one: **the tool did not run**. A test that
// only checked the outcome value would pass on a chain that returned a refusal
// after the package was already installed.
// ─────────────────────────────────────────────────────────────

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct CountingTool: AgentTool {
    let name: String
    let toolDescription = "ทูลสำหรับทดสอบ"
    let riskLevel: RiskLevel
    let parametersJSON = #"{"type":"object","properties":{}}"#
    let ran: CallCounter

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        await ran.increment()
        return ToolOutput(text: "ran")
    }
}

@Suite("Tools that always ask — P14.4")
struct AlwaysAskTests {

    @Test("install_package does not run under full autonomy with nobody to ask")
    func installPackageStopsUnderFullAutonomy() async throws {
        let ran = CallCounter()
        let gateway = ToolGateway(chain: HookChain(),
                                  modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(CountingTool(name: "install_package", riskLevel: .high, ran: ran))

        let outcome = try await gateway.call("install_package", argumentsJSON: "{}",
                                             context: ToolContext(scope: .central))

        // The thing that matters, first.
        #expect(await ran.value == 0, "the package was installed without anybody being asked")
        guard case .denied = outcome else {
            Issue.record("expected a denial with no approver, got \(outcome)")
            return
        }
    }

    // The comparison that makes the previous test mean something: an ordinary
    // high-risk tool *is* waved through by full autonomy, which is what the
    // setting is for.
    @Test("an ordinary high-risk tool still runs under full autonomy")
    func ordinaryHighRiskStillRuns() async throws {
        let ran = CallCounter()
        let gateway = ToolGateway(chain: HookChain(),
                                  modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(CountingTool(name: "run_shell", riskLevel: .high, ran: ran))

        _ = try await gateway.call("run_shell", argumentsJSON: "{}",
                                   context: ToolContext(scope: .central))
        #expect(await ran.value == 1)
    }

    // A manifest cannot declare its way out: the list is keyed by name and
    // read by the chain, not by the tool.
    @Test("declaring a low risk level does not take it off the list")
    func declaredRiskDoesNotMatter() async throws {
        let ran = CallCounter()
        let gateway = ToolGateway(chain: HookChain(),
                                  modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(CountingTool(name: "install_package", riskLevel: .low, ran: ran))

        _ = try await gateway.call("install_package", argumentsJSON: "{}",
                                   context: ToolContext(scope: .central))
        #expect(await ran.value == 0)
    }

    @Test("the list names install_package, and says why the list exists")
    func listIsExplicit() {
        #expect(AlwaysAsk.requiresHuman("install_package"))
        #expect(AlwaysAsk.requiresHuman("run_shell") == false)
    }
}

// ─────────────────────────────────────────────────────────────
// P12.7 — the lessons arrive, rather than being findable.
// ─────────────────────────────────────────────────────────────

private actor SeenInputs {
    private(set) var inputs: [String] = []
    func record(_ values: [String]) { inputs = values }
}

private actor RecordingSpecialist: Specialist {
    nonisolated let role: Role
    nonisolated let definitionOfDone: [Criterion] = []
    private let seen: SeenInputs

    init(role: Role, seen: SeenInputs) {
        self.role = role
        self.seen = seen
    }

    func execute(_ assignment: Assignment) async throws -> Deliverable {
        await seen.record(assignment.inputs)
        return Deliverable(assignmentID: assignment.id, summary: "เสร็จ")
    }
}

@Suite("Role memory reaches the specialist — P12.7")
struct RoleMemoryDeliveryTests {

    private func team(_ seen: SeenInputs, role: Role,
                      memory: @escaping @Sendable (Role) async -> [String]) -> TeamOrchestrator {
        TeamOrchestrator(router: ModelRouter(executors: []),
                         specialists: [role: RecordingSpecialist(role: role, seen: seen)],
                         roleMemory: memory)
    }

    @Test("a lesson for this role is in the assignment's inputs before work starts")
    func lessonsArriveAsInputs() async {
        let seen = SeenInputs()
        let orchestrator = team(seen, role: .engineer) { role in
            role == .engineer ? ["บทเรียนทั่วไป — โครงการ ก: อย่าลืมล็อกเวอร์ชัน"] : []
        }

        // Through the public entry point with a plan supplied, so this
        // exercises the path a real run takes rather than a private helper.
        _ = await orchestrator.run(goal: "ทำงาน", plan: TeamPlan(goal: "ทำงาน", assignments: [
            Assignment(role: .engineer, goal: "ทำงาน", inputs: ["ข้อมูลเดิมของงาน"],
                       acceptanceCriteria: [Criterion(text: "ผ่าน", evidenceRequired: "log")],
                       deliverableType: "code")
        ]))

        let inputs = await seen.inputs
        #expect(inputs.first?.contains("อย่าลืมล็อกเวอร์ชัน") == true,
                "the lesson did not reach the specialist")
        // The assignment's own inputs survive, after the lessons.
        #expect(inputs.contains("ข้อมูลเดิมของงาน"))
    }

    @Test("with no lessons the assignment is untouched")
    func noLessonsChangesNothing() async {
        let seen = SeenInputs()
        let orchestrator = team(seen, role: .writer) { _ in [] }

        _ = await orchestrator.run(goal: "เขียน", plan: TeamPlan(goal: "เขียน", assignments: [
            Assignment(role: .writer, goal: "เขียน", inputs: ["เฉพาะของเดิม"],
                       acceptanceCriteria: [Criterion(text: "ผ่าน", evidenceRequired: "doc")],
                       deliverableType: "document")
        ]))

        #expect(await seen.inputs == ["เฉพาะของเดิม"])
    }
}
