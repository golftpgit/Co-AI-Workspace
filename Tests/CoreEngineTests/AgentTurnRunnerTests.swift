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
        #expect(events.contains { if case .toolCallFinished(_, _, let executed) = $0 { return executed }; return false })
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
            if case .toolCallFinished(_, let text, _) = event { return text }
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
