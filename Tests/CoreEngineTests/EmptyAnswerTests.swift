import Testing
import Foundation
import AgentKit
import Observability
import LLMProviders
import Persistence
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// A stream that stops early is not an answer (§9.2, P15.1).
//
// Measured by cutting the connection to GX10 in the middle of a real answer,
// through the app, on screen (E.38). What the person was left looking at was
// their own question, a collapsed "ความคิดของโมเดล 2 วินาที", and **nothing
// else** — no answer, no error, no sign anything had gone wrong.
//
// The runner already has a mid-stream failure path that says
// "สตรีมคำตอบขาดกลางคัน" and it did not run, because nothing threw. A dropped
// SSE connection does not always surface as an error: the socket closes, the
// iteration ends, and an empty stream is indistinguishable from a stream that
// simply finished. So the turn took the success path with no text and no tool
// calls, and reported success by saying nothing.
//
// The rule is therefore not about connections at all, which is why it belongs
// here rather than in the transport: **a round that produced no text and no
// tool call has not answered**, whatever the reason. A model that returns only
// reasoning, a server that closes early, a truncated response — from where the
// person is sitting these are one thing, an empty reply, and an empty reply
// presented as a completed turn is the system claiming it did something it did
// not do (§2.5).
// ─────────────────────────────────────────────────────────────

private actor Transcript: TurnTranscript {
    private(set) var messages: [StoredMessage] = []

    @discardableResult
    func append(conversationID: String, role: StoredMessage.Role,
                content: String) async throws -> StoredMessage {
        let message = StoredMessage(id: UUID().uuidString, conversationID: conversationID,
                                    role: role, content: content, createdAt: Date())
        messages.append(message)
        return message
    }

    func history(conversationID: String, limit: Int) async throws -> [StoredMessage] {
        messages.filter { $0.conversationID == conversationID }
    }
}

/// Ends the stream after emitting whatever it was given — including nothing at
/// all, which is what a dropped connection looks like from here.
private struct EndsEarly: LLMExecutor {
    let identifier = "gx10"
    let tier: ModelTier = .selfHosted
    let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: true,
                                       supportsStructuredOutput: true,
                                       supportsStreaming: true, supportsVision: false)
    let reasoning: String?

    func isAvailable() async -> Bool { true }

    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            if let reasoning { continuation.yield(.reasoningDelta(reasoning)) }
            continuation.finish()          // no error — the socket just closed
        }
    }
}

@Suite("An empty reply is not a completed turn")
struct EmptyAnswerTests {

    private func events(reasoning: String?) async -> [TurnEvent] {
        let transcript = Transcript()
        let runner = AgentTurnRunner(
            router: ModelRouter(executors: [EndsEarly(reasoning: reasoning)]),
            gateway: ToolGateway(),
            transcript: transcript)
        var collected: [TurnEvent] = []
        let stream = await runner.run(userText: "อธิบายยาวๆ หน่อย",
                                      conversationID: "cv_1", scope: .central)
        for await event in stream {
            collected.append(event)
        }
        return collected
    }

    @Test("a stream that ends with nothing said is reported, not counted as finished")
    func silenceIsReported() async {
        let events = await events(reasoning: nil)
        let failure = events.compactMap { event -> String? in
            if case .failed(let reason) = event { return reason }
            return nil
        }.first
        #expect(failure != nil,
                "สตรีมจบโดยไม่มีคำตอบเลย แต่เทิร์นรายงานว่าสำเร็จ — คนที่นั่งดูจะเห็นแค่คำถามของตัวเอง")
    }

    @Test("thinking is not an answer either")
    func reasoningAloneIsStillSilence() async {
        // The measured case: the connection died during the reasoning phase, so
        // there *was* something on screen — a collapsed thinking disclosure —
        // and still nothing that answered the question.
        let events = await events(reasoning: "กำลังคิด…")
        let failure = events.compactMap { event -> String? in
            if case .failed(let reason) = event { return reason }
            return nil
        }.first
        #expect(failure != nil, "มีแต่ความคิดของโมเดล ไม่มีคำตอบ — ยังไม่ใช่เทิร์นที่สำเร็จ")
        #expect(failure?.contains("gx10") == true,
                "ข้อความต้องบอกว่าใครเงียบ ไม่งั้นคนอ่านไม่รู้จะไปดูที่ไหน")
    }
}
