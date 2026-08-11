import Testing
import Foundation
import AgentKit
import LLMProviders
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P4.1's Done-when: "compiler บังคับ isolation จริง — test พิสูจน์ว่า context
// ไม่รั่วข้าม actor".
//
// The compiler half cannot be asserted at runtime — a test that a type has no
// member is a test that does not compile — so it is stated where it can be
// checked: `Specialist.execute` returns `Deliverable`, and these tests prove
// what a `Deliverable` does and does not carry.
// ─────────────────────────────────────────────────────────────

private actor ToolCounter {
    private(set) var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
}

private struct EchoTool: AgentTool {
    let name: String
    let toolDescription = "เครื่องมือทดสอบ"
    let riskLevel: RiskLevel = .low
    let parametersJSON = #"{"type":"object","properties":{"q":{"type":"string"}}}"#
    let counter: ToolCounter
    let output: String

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        await counter.record(name)
        return ToolOutput(text: output, artifacts: ["artifact_\(name)"])
    }
}

/// Answers with one tool call, then a summary — the shape of a real turn.
private struct ScriptedExecutor: LLMExecutor {
    let identifier = "scripted"
    let tier: ModelTier = .selfHosted
    let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: true,
                                       supportsStructuredOutput: true,
                                       supportsStreaming: true, supportsVision: false)
    let script: Script

    actor Script {
        private var rounds: [[LLMToolCall]]
        let finalText: String
        init(rounds: [[LLMToolCall]], finalText: String) {
            self.rounds = rounds
            self.finalText = finalText
        }
        func next() -> [LLMToolCall]? { rounds.isEmpty ? nil : rounds.removeFirst() }
    }

    func isAvailable() async -> Bool { true }

    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if let calls = await script.next(), !calls.isEmpty {
                    continuation.yield(.textDelta("กำลังทำงาน"))
                    for call in calls { continuation.yield(.toolCall(call)) }
                } else {
                    continuation.yield(.textDelta(script.finalText))
                }
                continuation.yield(.finished(reason: "stop"))
                continuation.finish()
            }
        }
    }
}

private func environment(tools: [any AgentTool],
                         rounds: [[LLMToolCall]],
                         finalText: String = "สรุปผลงาน") async -> SpecialistEnvironment {
    let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
    await gateway.register(tools)
    let executor = ScriptedExecutor(
        script: ScriptedExecutor.Script(rounds: rounds, finalText: finalText))
    return SpecialistEnvironment(router: ModelRouter(executors: [executor]),
                                 gateway: gateway)
}

private let assignment = Assignment(
    role: .researcher, goal: "หาหลักฐานเรื่องอินซูลิน",
    acceptanceCriteria: [Criterion(text: "มี 2 แหล่ง", evidenceRequired: "citation")],
    deliverableType: "สรุปพร้อมอ้างอิง")

@Suite("Specialists")
struct SpecialistTests {
    @Test("a specialist hands back a deliverable, not its transcript")
    func onlyDeliverableCrossesTheBoundary() async throws {
        let counter = ToolCounter()
        let environment = await environment(
            tools: [EchoTool(name: "kb_search", counter: counter,
                             output: "ผลการค้น: อินซูลินช่วยคุมน้ำตาล")],
            rounds: [[LLMToolCall(id: "1", name: "kb_search",
                                  argumentsJSON: #"{"q":"อินซูลิน"}"#)]],
            finalText: "พบหลักฐาน 2 แหล่ง")

        let deliverable = try await Researcher(environment: environment).execute(assignment)

        #expect(deliverable.assignmentID == assignment.id)
        #expect(deliverable.summary == "พบหลักฐาน 2 แหล่ง")
        // Pointers, not content: §2.3 keeps raw output out of the lead's
        // context so a long task cannot flood it.
        #expect(deliverable.artifacts == ["artifact_kb_search"])
        // The one thing that must not appear: the working conversation. The
        // type has nowhere to put it, which is the guarantee.
        #expect(!deliverable.summary.contains("กำลังทำงาน"))
    }

    @Test("evidence comes from what ran, not from what was claimed")
    func evidenceIsFromTheTranscript() async throws {
        let counter = ToolCounter()
        let environment = await environment(
            tools: [EchoTool(name: "run_shell", counter: counter,
                             output: "swift test\nexit code: 0")],
            rounds: [[LLMToolCall(id: "1", name: "run_shell",
                                  argumentsJSON: #"{"q":"swift test"}"#)]],
            finalText: "แก้เสร็จแล้ว เทสผ่านหมด")

        let engineering = Assignment(
            role: .engineer, goal: "แก้เทสให้ผ่าน",
            acceptanceCriteria: [Criterion(text: "เทสผ่าน", evidenceRequired: "exit code 0")],
            deliverableType: "โค้ดที่ผ่านเทส")
        let deliverable = try await Engineer(environment: environment).execute(engineering)

        let exits = deliverable.evidence.filter { $0.kind == .commandExit }
        #expect(exits.count == 1)
        // The summary claims success; the evidence is what a reviewer reads.
        #expect(exits.first?.passed == true)
    }

    @Test("a failing command produces failing evidence, whatever the summary says")
    func failedCommandIsNotDressedUp() async throws {
        let counter = ToolCounter()
        let environment = await environment(
            tools: [EchoTool(name: "run_shell", counter: counter,
                             output: "swift test\nexit code: 1\nTest run failed")],
            rounds: [[LLMToolCall(id: "1", name: "run_shell",
                                  argumentsJSON: #"{"q":"swift test"}"#)]],
            finalText: "เรียบร้อย ทุกอย่างผ่านแล้วครับ")

        let engineering = Assignment(
            role: .engineer, goal: "แก้เทส",
            acceptanceCriteria: [Criterion(text: "เทสผ่าน", evidenceRequired: "exit code 0")],
            deliverableType: "โค้ด")
        let deliverable = try await Engineer(environment: environment).execute(engineering)

        // This is the whole point of external-truth-gated done (§2.5): the
        // model says it passed, the evidence says it did not, and QA reads the
        // evidence.
        #expect(deliverable.evidence.first(where: { $0.kind == .commandExit })?.passed == false)
        #expect(deliverable.summary.contains("ผ่านแล้ว"))
    }

    @Test("a role cannot use a tool it was not given")
    func toolsAreScopedToTheRole() async throws {
        let counter = ToolCounter()
        // A Writer only gets kb_search; asking for run_shell must not run it.
        let environment = await environment(
            tools: [EchoTool(name: "run_shell", counter: counter, output: "rm -rf /"),
                    EchoTool(name: "kb_search", counter: counter, output: "ผลการค้น")],
            rounds: [[LLMToolCall(id: "1", name: "run_shell",
                                  argumentsJSON: #"{"q":"rm -rf /"}"#)]],
            finalText: "เขียนเสร็จแล้ว")

        let writing = Assignment(
            role: .writer, goal: "เรียบเรียงรายงาน",
            acceptanceCriteria: [Criterion(text: "มี citation", evidenceRequired: "citation")],
            deliverableType: "รายงาน")
        _ = try await Writer(environment: environment).execute(writing)

        #expect(await counter.calls.isEmpty, "a writer ran a shell command")
    }

    @Test("every specialist declares what done means for it")
    func definitionsOfDoneExist() async {
        let environment = await environment(tools: [], rounds: [])
        // An assignment cannot exist without acceptance criteria (P1.1); a
        // role cannot exist without a standard to be judged by either.
        #expect(!Researcher(environment: environment).definitionOfDone.isEmpty)
        #expect(!Analyst(environment: environment).definitionOfDone.isEmpty)
        #expect(!Engineer(environment: environment).definitionOfDone.isEmpty)
        #expect(!Writer(environment: environment).definitionOfDone.isEmpty)

        // The Researcher's standard is the one §2.5 is most specific about.
        let researcher = Researcher(environment: environment)
        #expect(researcher.definitionOfDone.contains { $0.text.contains("2 แหล่ง") })
        #expect(researcher.definitionOfDone.contains { $0.evidenceRequired.contains("fetch_page") })
    }

    @Test("a specialist with no model fails loudly rather than returning nothing")
    func modelFailureIsNotAnEmptyDeliverable() async throws {
        struct DeadExecutor: LLMExecutor {
            let identifier = "dead"
            let tier: ModelTier = .selfHosted
            let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: true,
                                               supportsStructuredOutput: true,
                                               supportsStreaming: true, supportsVision: false)
            func isAvailable() async -> Bool { false }
            func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: LLMError.unavailable("offline")) }
            }
        }
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        let environment = SpecialistEnvironment(
            router: ModelRouter(executors: [DeadExecutor()]), gateway: gateway)

        // An empty deliverable would be reviewed as work that produced
        // nothing, rather than work that never ran.
        await #expect(throws: SpecialistError.self) {
            _ = try await Researcher(environment: environment).execute(assignment)
        }
    }
}
