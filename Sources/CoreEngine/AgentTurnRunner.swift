import Foundation
import AgentKit
import Observability
import LLMProviders
import Persistence

// ─────────────────────────────────────────────────────────────
// One turn, end to end (ARCHITECTURE §5.2) — the walking skeleton's spine:
//
//   user text → DB → history from DB → router → stream → tool calls → gate →
//   approval → tool → back to the model → assistant text → DB
//
// Two rules from earlier phases are load-bearing here. The user's message is
// committed *before* the model is called (P1.3), so an error mid-turn can
// never make it look like they never spoke. And history is read back from the
// database every turn rather than from whatever the view happens to hold.
// ─────────────────────────────────────────────────────────────

/// What the chat view renders as a turn unfolds.
public enum TurnEvent: Sendable {
    case userMessageStored(StoredMessage)
    case routed(executor: String, tier: ModelTier)
    case assistantDelta(String)
    /// `id` is the model's own tool-call id, carried so the UI can update the
    /// card it already drew instead of appending a second one.
    case toolCallStarted(id: String, name: String, argumentsJSON: String)
    case toolCallFinished(id: String, name: String, text: String, executed: Bool)
    /// Something the user should know that is not part of the answer.
    case note(String)
    case assistantMessageStored(StoredMessage)
    case failed(String)
    case finished
}

/// The persistence the runner needs, and nothing more. Declared here so a test
/// can exercise a whole turn without a database, while the app passes the real
/// `ConversationStore`.
public protocol TurnTranscript: Sendable {
    @discardableResult
    func append(conversationID: String, role: StoredMessage.Role, content: String) async throws -> StoredMessage
    func history(conversationID: String, limit: Int) async throws -> [StoredMessage]
}

extension ConversationStore: TurnTranscript {}

public actor AgentTurnRunner {
    private let router: ModelRouter
    private let gateway: ToolGateway
    private let transcript: any TurnTranscript
    private let sink: (any SpanSink)?
    private let systemPrompt: String
    /// A cap, because a model that keeps calling tools without converging is a
    /// loop, not progress. Hitting it is reported, never silently swallowed.
    private let maxToolRounds: Int

    public init(router: ModelRouter,
                gateway: ToolGateway,
                transcript: any TurnTranscript,
                spanSink: (any SpanSink)? = nil,
                systemPrompt: String = AgentTurnRunner.defaultSystemPrompt,
                maxToolRounds: Int = 6) {
        self.router = router
        self.gateway = gateway
        self.transcript = transcript
        self.sink = spanSink
        self.systemPrompt = systemPrompt
        self.maxToolRounds = maxToolRounds
    }

    public static let defaultSystemPrompt = """
    คุณคือผู้ช่วยของ Co-AI Workspace ทำงานบนเครื่อง Mac ของผู้ใช้ \
    ตอบเป็นภาษาไทยเว้นแต่ผู้ใช้จะใช้ภาษาอื่น กระชับและตรงประเด็น
    เมื่อจำเป็นต้องดูสถานะจริงของเครื่องหรือของโปรเจกต์ ให้เรียกเครื่องมือแทนการเดา \
    แต่คำถามที่ตอบได้เองอย่าเรียกเครื่องมือ \
    เครื่องมือที่มีความเสี่ยงจะถูกส่งให้ผู้ใช้อนุมัติก่อนเสมอ ถ้าผู้ใช้ไม่อนุมัติ ให้เสนอทางเลือกอื่น ห้ามเรียกคำสั่งเดิมซ้ำ
    ห้ามสมมติ path หรือชื่อไฟล์ที่ยังไม่เคยเห็น — ถ้าไม่รู้ ให้ใช้เครื่องมือดูก่อนหรือถามผู้ใช้
    """

    /// Appended to the system prompt each turn. A model that is not told where
    /// it is will invent somewhere: with no folder chosen, Llama 3.1 8B called
    /// `run_shell` with `working_directory: "/path/to/project"` and the user
    /// was asked to approve it.
    private static func placeContext(_ workingDirectory: URL?) -> String {
        guard let workingDirectory else {
            return """

            ตอนนี้ผู้ใช้ยังไม่ได้เลือกโฟลเดอร์งาน จึงรันคำสั่งใด ๆ ไม่ได้เลย \
            ถ้างานต้องรันคำสั่ง ให้บอกผู้ใช้ให้กด "เลือกโฟลเดอร์งาน" ก่อน อย่าเดา path
            """
        }
        return """

        โฟลเดอร์งานปัจจุบันคือ \(workingDirectory.path(percentEncoded: false)) \
        คำสั่งทั้งหมดรันที่นี่ ไม่ต้องส่ง working_directory มาเองเว้นแต่ต้องการโฟลเดอร์อื่นจริง ๆ
        """
    }

    /// Runs a turn. The stream finishes with `.finished` or `.failed`;
    /// cancelling the consuming task cancels the turn.
    public func run(userText: String,
                    conversationID: String,
                    scope: Scope,
                    workingDirectory: URL? = nil,
                    role: Role? = nil,
                    policy: RoutingPolicy = .disposable) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let task = Task {
                await execute(userText: userText,
                              conversationID: conversationID,
                              scope: scope,
                              workingDirectory: workingDirectory,
                              role: role,
                              policy: policy,
                              emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - the turn

    private func execute(userText: String,
                         conversationID: String,
                         scope: Scope,
                         workingDirectory: URL?,
                         role: Role?,
                         policy: RoutingPolicy,
                         emit: @Sendable (TurnEvent) -> Void) async {
        var turnSpan = Span(name: "turn", role: role, scope: scope)
        await sink?.record(turnSpan)

        func close(_ status: SpanStatus, _ detail: String?) async {
            turnSpan.status = status
            turnSpan.endedAt = Date()
            turnSpan.detail = detail
            await sink?.record(turnSpan)
        }

        // 1 — the user's message lands in the database before anything else can
        //     fail. This is the whole point of P1.3.
        do {
            emit(.userMessageStored(
                try await transcript.append(conversationID: conversationID, role: .user, content: userText)))
        } catch {
            emit(.failed("บันทึกข้อความไม่สำเร็จ: \(error)"))
            await close(.failed, "persist user message: \(error)")
            return
        }

        // 2 — history comes from the database, not from the view.
        let adverts = await gateway.adverts
        var messages: [LLMMessage]
        do {
            let history = try await transcript.history(conversationID: conversationID, limit: 500)
            let system = systemPrompt + Self.placeContext(workingDirectory)
                + Self.toolRoster(adverts.map(\.name))
            messages = [LLMMessage(.system, system)] + history.map(Self.llmMessage(from:))
        } catch {
            emit(.failed("อ่านประวัติการสนทนาไม่สำเร็จ: \(error)"))
            await close(.failed, "load history: \(error)")
            return
        }

        let context = ToolContext(scope: scope,
                                  workingDirectory: workingDirectory,
                                  conversationID: conversationID,
                                  role: role)
        /// Calls the human has already refused this turn, by tool and arguments.
        var denied = Set<String>()
        var tools = adverts.map {
            LLMToolSpec(name: $0.name, description: $0.description, parametersJSON: $0.parametersJSON)
        }

        for round in 0..<maxToolRounds {
            if Task.isCancelled { await close(.cancelled, "cancelled"); emit(.finished); return }

            var request = LLMRequest(messages: messages)
            request.tools = tools
            request.maxTokens = 1_024

            let stream: AsyncThrowingStream<LLMEvent, Error>
            do {
                let routed = try await router.stream(request, policy: policy)
                emit(.routed(executor: routed.executor, tier: routed.tier))
                stream = routed.events
            } catch is RoutingError where !tools.isEmpty {
                // Nothing available can call tools right now — on-device is the
                // usual case (§9.1). Answering without them beats failing the
                // turn, as long as the user is told which one happened.
                emit(.note("โมเดลที่ใช้ได้ตอนนี้ไม่รองรับการเรียกเครื่องมือ — ตอบโดยไม่ใช้เครื่องมือ"))
                tools = []
                continue
            } catch let error as RoutingError {
                emit(.failed(Self.explain(error)))
                await close(.failed, error.description)
                return
            } catch {
                emit(.failed("เรียกโมเดลไม่สำเร็จ: \(error)"))
                await close(.failed, "\(error)")
                return
            }

            var text = ""
            var calls: [LLMToolCall] = []
            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let chunk):
                        text += chunk
                        emit(.assistantDelta(chunk))
                    case .toolCall(let call):
                        calls.append(call)
                    case .usage(let usage):
                        turnSpan.promptTokens = (turnSpan.promptTokens ?? 0) + usage.promptTokens
                        turnSpan.completionTokens = (turnSpan.completionTokens ?? 0) + usage.completionTokens
                    case .finished:
                        break
                    }
                }
            } catch {
                // A failure after the first token cannot be re-routed without
                // splicing two answers together (§9.2), so it surfaces — but
                // whatever the model already said is kept.
                if !text.isEmpty { try? await store(text, in: conversationID, emit: emit) }
                emit(.failed("สตรีมคำตอบขาดกลางคัน: \(error)"))
                await close(.failed, "\(error)")
                return
            }

            guard !calls.isEmpty else {
                if !text.isEmpty { try? await store(text, in: conversationID, emit: emit) }
                await close(.succeeded, "rounds: \(round + 1)")
                emit(.finished)
                return
            }

            // The assistant turn that requested tools has to be echoed back with
            // its tool_calls intact, or the endpoint replies with empty text and
            // no error (ARCHITECTURE E.9).
            messages.append(LLMMessage(.assistant, text, toolCalls: calls))
            if !text.isEmpty { try? await store(text, in: conversationID, emit: emit) }

            for call in calls {
                emit(.toolCallStarted(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))

                // Asking a second time about something the human already said
                // no to is not diligence, it is nagging — and a model that
                // retries the identical call would do it every round up to the
                // cap. Observed with Llama 3.1 8B on the first real turn.
                let fingerprint = "\(call.name)\u{1}\(call.argumentsJSON)"
                if denied.contains(fingerprint) {
                    let text = "ผู้ใช้ไม่อนุมัติคำสั่งนี้ไปแล้วในเทิร์นนี้ — ห้ามเรียกซ้ำ ให้เสนอวิธีอื่นหรือถามผู้ใช้"
                    emit(.toolCallFinished(id: call.id, name: call.name, text: text, executed: false))
                    messages.append(LLMMessage(.tool, text, toolCallID: call.id))
                    _ = try? await transcript.append(
                        conversationID: conversationID, role: .tool,
                        content: ToolTranscript.encode(.init(toolName: call.name, executed: false, text: text)))
                    continue
                }

                let resultText: String
                var executed = false
                do {
                    // Every tool call in the system goes through here (§5.3).
                    let outcome = try await gateway.call(call.name,
                                                         argumentsJSON: call.argumentsJSON,
                                                         context: context,
                                                         parentSpan: turnSpan.id)
                    resultText = outcome.transcriptText
                    executed = outcome.didExecute
                    if case .denied = outcome { denied.insert(fingerprint) }
                } catch {
                    // The tool itself failed. The model gets the error verbatim,
                    // because that is usually what tells it what to do next.
                    resultText = "เครื่องมือ '\(call.name)' ล้มเหลว: \(error)"
                }
                emit(.toolCallFinished(id: call.id, name: call.name, text: resultText, executed: executed))
                messages.append(LLMMessage(.tool, resultText, toolCallID: call.id))
                _ = try? await transcript.append(
                    conversationID: conversationID, role: .tool,
                    content: ToolTranscript.encode(.init(toolName: call.name,
                                                         executed: executed, text: resultText)))
            }
        }

        emit(.note("เรียกเครื่องมือครบ \(maxToolRounds) รอบแล้วยังไม่จบ — หยุดไว้ก่อนเพื่อไม่ให้วนไม่รู้จบ"))
        await close(.failed, "tool round cap reached")
        emit(.finished)
    }

    /// Spelling out the roster costs a line and stops a small model inventing
    /// members of it: Llama 3.1 8B called `list_files` and `open_project`,
    /// neither of which exists, before settling on `run_shell`.
    private static func toolRoster(_ names: [String]) -> String {
        guard !names.isEmpty else {
            return "\n\nตอนนี้ไม่มีเครื่องมือให้เรียกเลย ตอบจากความรู้ที่มี"
        }
        return """


        เครื่องมือที่มีอยู่จริงมีเท่านี้: \(names.joined(separator: ", ")) \
        ห้ามเรียกชื่ออื่นนอกรายการนี้ ถ้าไม่มีเครื่องมือที่ตรงงาน ให้บอกผู้ใช้ตามตรง
        """
    }

    /// Routing errors are the one failure a user can usually act on — the
    /// endpoint is down, nothing supports tools — so they are worth saying in
    /// full rather than as a category word.
    private static func explain(_ error: RoutingError) -> String {
        let lines = error.attempts.map { attempt in
            "• \(attempt.executor): \(attempt.detail ?? attempt.outcome)"
        }
        return (["ไม่มีโมเดลที่รับงานนี้ได้:"] + lines
                + ["ลองตรวจว่า endpoint ที่ตั้งไว้เปิดอยู่ หรือเปิด Apple Intelligence"])
            .joined(separator: "\n")
    }

    private func store(_ text: String, in conversationID: String,
                       emit: @Sendable (TurnEvent) -> Void) async throws {
        let stored = try await transcript.append(conversationID: conversationID,
                                                 role: .assistant, content: text)
        emit(.assistantMessageStored(stored))
    }

    /// Stored tool results come back as narrated assistant turns rather than
    /// protocol `tool` messages: a `tool` message is only valid next to the
    /// `tool_calls` that produced it, and those ids do not outlive the turn.
    /// Replaying them as prose keeps a reloaded conversation valid for every
    /// tier, including the ones with no tool support at all.
    private static func llmMessage(from stored: StoredMessage) -> LLMMessage {
        switch stored.role {
        case .system: return LLMMessage(.system, stored.content)
        case .user: return LLMMessage(.user, stored.content)
        case .assistant: return LLMMessage(.assistant, stored.content)
        case .tool:
            let entry = ToolTranscript.decode(stored.content)
            let outcome = entry.executed ? "ผลจากเครื่องมือ" : "เครื่องมือนี้ไม่ได้ถูกรัน"
            return LLMMessage(.assistant, "[\(outcome) \(entry.toolName)]\n\(entry.text)")
        }
    }
}
