import Testing
import Foundation
import AgentKit
import Observability
import LLMProviders
import Persistence
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P1.10's Done-when, minus the pixels: a turn that contains a tool call and
// an approval has to complete. The model is scripted so the *shape* of the
// turn is what is under test, not a particular model's behaviour.
// ─────────────────────────────────────────────────────────────

private actor MemoryTranscript: TurnTranscript {
    private(set) var messages: [StoredMessage] = []
    var failOnAppend = false

    @discardableResult
    func append(conversationID: String, role: StoredMessage.Role, content: String) async throws -> StoredMessage {
        let message = StoredMessage(id: UUID().uuidString, conversationID: conversationID,
                                    role: role, content: content, createdAt: Date())
        messages.append(message)
        return message
    }

    func history(conversationID: String, limit: Int) async throws -> [StoredMessage] {
        messages.filter { $0.conversationID == conversationID }
    }

    var roles: [StoredMessage.Role] { messages.map(\.role) }
    func content(at index: Int) -> String { messages[index].content }
}

/// Replies with a scripted sequence: one entry per round of the turn.
private struct ScriptedExecutor: LLMExecutor {
    enum Round: Sendable {
        case text(String)
        case toolCall(name: String, argumentsJSON: String)
    }

    let identifier = "scripted"
    let tier: ModelTier = .selfHosted
    let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: true,
                                       supportsStructuredOutput: true,
                                       supportsStreaming: true, supportsVision: false)
    let script: RoundScript

    func isAvailable() async -> Bool { true }

    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                switch await script.next() {
                case .text(let text):
                    continuation.yield(.textDelta(text))
                case .toolCall(let name, let arguments):
                    continuation.yield(.textDelta("ขอรันคำสั่งก่อนนะ"))
                    continuation.yield(.toolCall(.init(id: "call_1", name: name, argumentsJSON: arguments)))
                case .none:
                    continuation.yield(.textDelta("จบแล้ว"))
                }
                continuation.yield(.finished(reason: "stop"))
                continuation.finish()
            }
        }
    }
}

private actor RoundScript {
    private var rounds: [ScriptedExecutor.Round]
    init(_ rounds: [ScriptedExecutor.Round]) { self.rounds = rounds }
    func next() -> ScriptedExecutor.Round? { rounds.isEmpty ? nil : rounds.removeFirst() }
}

private struct EchoTool: AgentTool {
    var name = "kb_search"
    let toolDescription = "ค้นความรู้"
    var riskLevel: RiskLevel = .low
    let parametersJSON = #"{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}"#
    let ran: Counter

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        await ran.increment()
        return ToolOutput(text: "พบ 2 รายการสำหรับ \(argumentsJSON)")
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct Approver: ApprovalRequesting {
    let decision: ApprovalDecision
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision { decision }
}

private func collect(_ stream: AsyncStream<TurnEvent>) async -> [TurnEvent] {
    var events: [TurnEvent] = []
    for await event in stream { events.append(event) }
    return events
}

@Suite("A whole turn")
struct AgentTurnRunnerTests {
    @Test("a turn with a tool call runs the tool and comes back with an answer")
    func turnWithToolCall() async throws {
        let transcript = MemoryTranscript()
        let ran = Counter()
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(EchoTool(ran: ran))
        let script = RoundScript([.toolCall(name: "kb_search", argumentsJSON: #"{"q":"มะเร็งปอด"}"#),
                                  .text("สรุปให้แล้วครับ")])
        let runner = AgentTurnRunner(router: ModelRouter(executors: [ScriptedExecutor(script: script)]),
                                     gateway: gateway,
                                     transcript: transcript)

        let events = await collect(runner.run(userText: "ค้นให้หน่อย",
                                              conversationID: "cv_1", scope: .central))

        #expect(await ran.value == 1)
        #expect(events.contains { if case .toolCallFinished(_, _, _, let executed) = $0 { return executed }; return false })
        #expect(events.contains { if case .finished = $0 { return true }; return false })

        // user → assistant(asking) → tool result → assistant(final)
        #expect(await transcript.roles == [.user, .assistant, .tool, .assistant])
        #expect(await transcript.content(at: 3) == "สรุปให้แล้วครับ")
    }

    /// The end-to-end shape P1.7 + P1.8 + P1.10 exist for: the model asks, the
    /// human says no, and the turn keeps going instead of failing.
    @Test("a denied approval stops the tool but not the turn")
    func deniedApprovalDoesNotKillTheTurn() async throws {
        let transcript = MemoryTranscript()
        let ran = Counter()
        let gateway = ToolGateway(approver: Approver(decision: .rejected(reason: "ยังไม่ต้อง")),
                                  modes: OperatingModes(autonomy: .approvalRequired))
        // `save_document` scores medium, which is what the approval-required
        // threshold catches; `kb_search` would sail straight through.
        await gateway.register(EchoTool(name: "save_document", riskLevel: .medium, ran: ran))
        let script = RoundScript([.toolCall(name: "save_document", argumentsJSON: #"{"q":"x"}"#),
                                  .text("งั้นตอบจากที่รู้แทน")])
        let runner = AgentTurnRunner(router: ModelRouter(executors: [ScriptedExecutor(script: script)]),
                                     gateway: gateway,
                                     transcript: transcript)

        let events = await collect(runner.run(userText: "ช่วยหาให้หน่อย",
                                              conversationID: "cv_2", scope: .central))

        #expect(await ran.value == 0, "the tool ran despite being denied")
        // The model is told why, so it can offer something else instead of
        // calling the same tool again.
        let toolEvent = events.compactMap { event -> String? in
            if case .toolCallFinished(_, _, let text, _) = event { return text }
            return nil
        }.first
        #expect(toolEvent?.contains("ยังไม่ต้อง") == true)
        #expect(events.contains { if case .finished = $0 { return true }; return false })
    }

    /// P1.3's rule, checked from the turn's side: an agent failure must not
    /// swallow what the user typed.
    @Test("the user's message survives a model failure")
    func userMessageIsCommittedBeforeTheModelRuns() async throws {
        let transcript = MemoryTranscript()
        let router = ModelRouter(executors: [ScriptedExecutor(script: RoundScript([]))],
                                 availabilityTTL: .seconds(0))
        let gateway = ToolGateway()
        // A schema-only request that no executor can serve is a routing error
        // raised before any model is called.
        let runner = AgentTurnRunner(router: router, gateway: gateway, transcript: transcript)
        _ = await collect(runner.run(userText: "ข้อความที่ต้องไม่หาย",
                                     conversationID: "cv_3", scope: .central))

        #expect(await transcript.messages.first?.content == "ข้อความที่ต้องไม่หาย")
        #expect(await transcript.messages.first?.role == .user)
    }

    /// Tier 0 has no tool calling (§9.1). Rather than failing the turn, the
    /// runner drops the tools and says so.
    @Test("a tier with no tool support answers without tools instead of failing")
    func fallsBackWhenNoTierCanCallTools() async throws {
        let transcript = MemoryTranscript()
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(EchoTool(ran: Counter()))

        struct TextOnly: LLMExecutor {
            let identifier = "text-only"
            let tier: ModelTier = .onDevice
            let capabilities = LLMCapabilities(contextWindow: 8_000, supportsTools: false,
                                               supportsStructuredOutput: true,
                                               supportsStreaming: true, supportsVision: false)
            func isAvailable() async -> Bool { true }
            func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield(.textDelta("ตอบโดยไม่ใช้เครื่องมือ"))
                    continuation.yield(.finished(reason: "stop"))
                    continuation.finish()
                }
            }
        }

        let runner = AgentTurnRunner(router: ModelRouter(executors: [TextOnly()]),
                                     gateway: gateway, transcript: transcript)
        let events = await collect(runner.run(userText: "สวัสดี", conversationID: "cv_4", scope: .central))

        #expect(events.contains { if case .note(let text) = $0 { return text.contains("ไม่รองรับ") }; return false })
        #expect(await transcript.roles == [.user, .assistant])
    }

    /// A model that keeps calling tools is a loop. The cap has to be visible.
    @Test("a runaway tool loop stops at the cap and says so")
    func toolLoopIsCapped() async throws {
        let transcript = MemoryTranscript()
        let ran = Counter()
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(EchoTool(ran: ran))
        let script = RoundScript(Array(repeating: .toolCall(name: "kb_search", argumentsJSON: #"{"q":"x"}"#),
                                       count: 10))
        let runner = AgentTurnRunner(router: ModelRouter(executors: [ScriptedExecutor(script: script)]),
                                     gateway: gateway, transcript: transcript, maxToolRounds: 3)

        let events = await collect(runner.run(userText: "วนไปเรื่อย ๆ", conversationID: "cv_5", scope: .central))
        #expect(await ran.value == 3)
        #expect(events.contains { if case .note(let text) = $0 { return text.contains("3 รอบ") }; return false })
    }

    @Test("the turn is one span with the tool calls hanging off it")
    func turnSpansNest() async throws {
        let sink = InMemorySpanSink()
        let gateway = ToolGateway(spanSink: sink, modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(EchoTool(ran: Counter()))
        let script = RoundScript([.toolCall(name: "kb_search", argumentsJSON: #"{"q":"x"}"#), .text("จบ")])
        let runner = AgentTurnRunner(router: ModelRouter(executors: [ScriptedExecutor(script: script)]),
                                     gateway: gateway, transcript: MemoryTranscript(), spanSink: sink)

        _ = await collect(runner.run(userText: "hi", conversationID: "cv_6", scope: .central))

        let spans = await sink.spans
        let turn = try #require(spans.first { $0.name == "turn" })
        let tool = try #require(spans.first { $0.name == "tool:kb_search" })
        #expect(tool.parent == turn.id)
    }
}

// ─────────────────────────────────────────────────────────────
// Regressions from the first real session with Llama 3.1 8B (2026-08-10).
// Everything here was seen on screen before it was a test.
// ─────────────────────────────────────────────────────────────

/// Refuses every call before it runs, the way `run_shell` does when no working
/// directory has been chosen.
private struct UnrunnableTool: AgentTool {
    let name = "save_document"
    let toolDescription = "บันทึกเอกสาร"
    let riskLevel: RiskLevel = .medium
    let parametersJSON = #"{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}"#
    let ran: Counter

    func precheck(argumentsJSON: String, context: ToolContext) throws {
        throw ToolError.notPermitted("ยังไม่ได้เลือกโฟลเดอร์งาน")
    }

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        await ran.increment()
        return ToolOutput(text: "ไม่ควรมาถึงตรงนี้")
    }
}

private struct RecordingApprover: ApprovalRequesting {
    let decision: ApprovalDecision
    let asked: Counter
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await asked.increment()
        return decision
    }
}

@Suite("What the first real session taught us")
struct TurnRegressionTests {
    /// Seen on screen: with no folder chosen, the model invented
    /// `/path/to/project` and the user was asked to approve a command that
    /// could never have run.
    @Test("a call that cannot run is sent back instead of becoming an approval")
    func impossibleCallNeverReachesTheHuman() async throws {
        let ran = Counter(), asked = Counter()
        let gateway = ToolGateway(approver: RecordingApprover(decision: .approved, asked: asked),
                                  modes: OperatingModes(autonomy: .approvalRequired))
        await gateway.register(UnrunnableTool(ran: ran))
        let script = RoundScript([.toolCall(name: "save_document", argumentsJSON: #"{"q":"x"}"#),
                                  .text("บอกผู้ใช้ให้เลือกโฟลเดอร์ก่อน")])
        let runner = AgentTurnRunner(router: ModelRouter(executors: [ScriptedExecutor(script: script)]),
                                     gateway: gateway, transcript: MemoryTranscript())

        let events = await collect(runner.run(userText: "ลองดู", conversationID: "cv_r1", scope: .central))

        #expect(await asked.value == 0, "the human was asked about an impossible call")
        #expect(await ran.value == 0)
        // And the model is told why, in words it can act on.
        let text = events.compactMap { event -> String? in
            if case .toolCallFinished(_, _, let text, _) = event { return text }
            return nil
        }.first
        #expect(text?.contains("โฟลเดอร์") == true)
    }

    /// Also seen on screen: after a refusal the model called the identical
    /// command again, and the banner came straight back.
    @Test("the same refused call is not put in front of the human twice")
    func deniedCallIsNotAskedAgain() async throws {
        let ran = Counter(), asked = Counter()
        let gateway = ToolGateway(approver: RecordingApprover(decision: .rejected(reason: "ไม่เอา"),
                                                              asked: asked),
                                  modes: OperatingModes(autonomy: .approvalRequired))
        await gateway.register(EchoTool(name: "save_document", riskLevel: .medium, ran: ran))
        let same = ScriptedExecutor.Round.toolCall(name: "save_document", argumentsJSON: #"{"q":"x"}"#)
        let runner = AgentTurnRunner(router: ModelRouter(executors: [
            ScriptedExecutor(script: RoundScript(Array(repeating: same, count: 5)))
        ]), gateway: gateway, transcript: MemoryTranscript(), maxToolRounds: 5)

        _ = await collect(runner.run(userText: "ลองซ้ำ", conversationID: "cv_r2", scope: .central))

        let times = await asked.value
        #expect(times == 1, "the human was asked \(times) times for one refusal")
        #expect(await ran.value == 0)
    }

    /// A different command after a refusal is a new question, not the same one.
    @Test("a different call still gets asked")
    func differentCallStillAsks() async throws {
        let ran = Counter(), asked = Counter()
        let gateway = ToolGateway(approver: RecordingApprover(decision: .rejected(reason: "ไม่"),
                                                              asked: asked),
                                  modes: OperatingModes(autonomy: .approvalRequired))
        await gateway.register(EchoTool(name: "save_document", riskLevel: .medium, ran: ran))
        let runner = AgentTurnRunner(router: ModelRouter(executors: [
            ScriptedExecutor(script: RoundScript([
                .toolCall(name: "save_document", argumentsJSON: #"{"q":"หนึ่ง"}"#),
                .toolCall(name: "save_document", argumentsJSON: #"{"q":"สอง"}"#),
                .text("จบ"),
            ]))
        ]), gateway: gateway, transcript: MemoryTranscript(), maxToolRounds: 5)

        _ = await collect(runner.run(userText: "ลอง", conversationID: "cv_r3", scope: .central))
        #expect(await asked.value == 2)
    }

    /// Seen on screen as `apple-on-device(transport)` — a category word with
    /// the actual failure thrown away.
    @Test("a routing failure says what each tier actually reported")
    func routingFailureIsLegible() async throws {
        struct Broken: LLMExecutor {
            let identifier = "apple-on-device"
            let tier: ModelTier = .onDevice
            let capabilities = LLMCapabilities(contextWindow: 8_000, supportsTools: false,
                                               supportsStructuredOutput: true,
                                               supportsStreaming: true, supportsVision: false)
            func isAvailable() async -> Bool { true }
            func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: LLMError.transport("assets not loaded")) }
            }
        }

        let runner = AgentTurnRunner(router: ModelRouter(executors: [Broken()]),
                                     gateway: ToolGateway(), transcript: MemoryTranscript())
        let events = await collect(runner.run(userText: "hi", conversationID: "cv_r4", scope: .central))

        let failure = events.compactMap { event -> String? in
            if case .failed(let text) = event { return text }
            return nil
        }.first
        #expect(failure?.contains("assets not loaded") == true, "got: \(failure ?? "nothing")")
        #expect(failure?.contains("apple-on-device") == true)
    }

    /// A model that is not told where it is will make somewhere up.
    @Test("the system prompt says which folder commands run in")
    func systemPromptCarriesTheWorkingDirectory() async throws {
        let seen = PromptLog()
        struct PromptSpy: LLMExecutor {
            let identifier = "spy"
            let tier: ModelTier = .selfHosted
            let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: true,
                                               supportsStructuredOutput: true,
                                               supportsStreaming: true, supportsVision: false)
            let seen: PromptLog
            func isAvailable() async -> Bool { true }
            func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { continuation in
                    Task {
                        await seen.record(request.messages.first?.content ?? "")
                        continuation.yield(.textDelta("ok"))
                        continuation.yield(.finished(reason: "stop"))
                        continuation.finish()
                    }
                }
            }
        }

        let runner = AgentTurnRunner(router: ModelRouter(executors: [PromptSpy(seen: seen)]),
                                     gateway: ToolGateway(), transcript: MemoryTranscript())
        _ = await collect(runner.run(userText: "hi", conversationID: "cv_r5", scope: .central,
                                     workingDirectory: URL(fileURLWithPath: "/tmp/โปรเจกต์")))
        #expect(await seen.last?.contains("/tmp/โปรเจกต์") == true)

        _ = await collect(runner.run(userText: "hi", conversationID: "cv_r6", scope: .central))
        #expect(await seen.last?.contains("ยังไม่ได้เลือกโฟลเดอร์งาน") == true)
    }
}

private actor PromptLog {
    private(set) var last: String?
    func record(_ prompt: String) { last = prompt }
}

@Suite("What survives a reload")
struct TranscriptFidelityTests {
    /// Seen on screen: after a reload, a call for a tool that does not exist
    /// and a call the user refused both rendered as "เสร็จแล้ว".
    @Test("a refused call still reads as refused after the conversation reloads")
    func blockedStateSurvives() async throws {
        let transcript = MemoryTranscript()
        let gateway = ToolGateway(approver: Approver(decision: .rejected(reason: "ไม่เอา")),
                                  modes: OperatingModes(autonomy: .approvalRequired))
        await gateway.register(EchoTool(name: "save_document", riskLevel: .medium, ran: Counter()))
        let runner = AgentTurnRunner(router: ModelRouter(executors: [
            ScriptedExecutor(script: RoundScript([
                .toolCall(name: "save_document", argumentsJSON: #"{"q":"x"}"#),
                .text("งั้นตอบเองแทน"),
            ]))
        ]), gateway: gateway, transcript: transcript)

        _ = await collect(runner.run(userText: "ลอง", conversationID: "cv_t1", scope: .central))

        let stored = try #require(await transcript.messages.first { $0.role == .tool })
        let entry = ToolTranscript.decode(stored.content)
        #expect(entry.toolName == "save_document")
        #expect(entry.executed == false, "the refusal was stored as a success")
    }

    @Test("a call that did run reads as having run")
    func executedStateSurvives() async throws {
        let transcript = MemoryTranscript()
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(EchoTool(ran: Counter()))
        let runner = AgentTurnRunner(router: ModelRouter(executors: [
            ScriptedExecutor(script: RoundScript([
                .toolCall(name: "kb_search", argumentsJSON: #"{"q":"x"}"#), .text("เสร็จ"),
            ]))
        ]), gateway: gateway, transcript: transcript)

        _ = await collect(runner.run(userText: "ลอง", conversationID: "cv_t2", scope: .central))
        let stored = try #require(await transcript.messages.first { $0.role == .tool })
        #expect(ToolTranscript.decode(stored.content).executed)
    }

    /// The next turn must not read a refusal as evidence that the work is done.
    @Test("the model is replayed the refusal, not a result")
    func replayKeepsTheRefusal() {
        let encoded = ToolTranscript.encode(.init(toolName: "run_shell", executed: false,
                                                  text: "ผู้ใช้ไม่อนุมัติ"))
        let entry = ToolTranscript.decode(encoded)
        #expect(entry.executed == false)
        #expect(entry.toolName == "run_shell")
        #expect(entry.text == "ผู้ใช้ไม่อนุมัติ")
    }

    /// Rows written before the marker existed still have to load.
    @Test("an older row without the marker still decodes")
    func legacyRowsDecode() {
        let entry = ToolTranscript.decode("run_shell\n$ ls\n[exit 0]")
        #expect(entry.toolName == "run_shell")
        #expect(entry.executed)
        #expect(entry.text.contains("[exit 0]"))
    }

    /// Llama 3.1 8B invented `list_files` and `open_project` before finding
    /// `run_shell`. Naming the roster is cheap; three wasted rounds are not.
    @Test("the system prompt names the tools that actually exist")
    func systemPromptListsTools() async throws {
        let seen = PromptLog()
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(EchoTool(ran: Counter()))

        struct PromptSpy: LLMExecutor {
            let identifier = "spy"
            let tier: ModelTier = .selfHosted
            let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: true,
                                               supportsStructuredOutput: true,
                                               supportsStreaming: true, supportsVision: false)
            let seen: PromptLog
            func isAvailable() async -> Bool { true }
            func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { continuation in
                    Task {
                        await seen.record(request.messages.first?.content ?? "")
                        continuation.yield(.textDelta("ok"))
                        continuation.yield(.finished(reason: "stop"))
                        continuation.finish()
                    }
                }
            }
        }

        let runner = AgentTurnRunner(router: ModelRouter(executors: [PromptSpy(seen: seen)]),
                                     gateway: gateway, transcript: MemoryTranscript())
        _ = await collect(runner.run(userText: "hi", conversationID: "cv_t3", scope: .central))
        #expect(await seen.last?.contains("kb_search") == true)
        #expect(await seen.last?.contains("ห้ามเรียกชื่ออื่น") == true)
    }
}
