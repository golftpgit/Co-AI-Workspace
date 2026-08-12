import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Siri, Shortcuts and Spotlight (ARCHITECTURE §8.1, §14.3, P7.5).
//
// The shape is different from every other channel and the difference is the
// whole design. Telegram is a stream: messages arrive, replies are pushed, and
// nobody is blocked. An intent is a *question with a caller waiting on it* —
// Shortcuts wants a value back, and it wants it before its own timeout.
//
// What is deliberately the same is the path: an intent becomes an
// `IncomingMessage` handed to `InboundHandling`, exactly like a Telegram
// message, so §8.2's "every channel through the same core" holds by
// construction. This module still cannot see a tool or the gateway.
//
// **Approval does not happen here.** §8.1: Siri is the wrong place to approve
// something you are supposed to read first — there is no diff to look at and
// no way to show one. So an approval raised during an intent goes to the GUI,
// and the caller is told that in words rather than left to time out with no
// explanation. That distinction — "still waiting for you in the app" versus
// "took too long" — is the difference between a Shortcut somebody trusts and
// one they stop using.
// ─────────────────────────────────────────────────────────────

public enum IntentAnswer: Sendable, Equatable {
    case answered(String)
    /// The turn stopped at the gate. The app has the sheet.
    case needsApproval(tool: String)
    case timedOut
    /// Nothing is listening — the workspace has not finished starting.
    case notRunning

    /// What Siri says out loud.
    public var spoken: String {
        switch self {
        case .answered(let text): return text
        case .needsApproval(let tool):
            return "งานนี้ต้องอนุมัติก่อน — เปิดแอปแล้วอนุมัติ '\(tool)' ได้เลย"
        case .timedOut: return "ยังทำไม่เสร็จ ลองดูในแอปได้เลย"
        case .notRunning: return "Co-AI Workspace ยังเริ่มไม่เสร็จ ลองอีกครั้งในอีกสักครู่"
        }
    }
}

public actor AppIntentsChannel: RunnableChannel {
    public nonisolated let id = ChannelID("app-intents")
    /// The account id the router files this channel under. Fixed, because
    /// unlike a bot there is only ever one of these: the person logged into
    /// this Mac.
    public static let accountID = "app-intents"

    private struct Pending {
        let continuation: CheckedContinuation<IntentAnswer, Never>
        /// Set when the gate asked for a human mid-turn.
        var blockedOn: String?
    }

    private var handler: (any InboundHandling)?
    /// request key → what is waiting for it.
    private var pending: [String: Pending] = [:]
    /// conversation id → request key, filled in by `bind` when the router
    /// creates the conversation.
    private var conversations: [String: String] = [:]
    /// The request a turn is currently running for. An intent is one at a
    /// time from the caller's point of view, and an approval arrives with no
    /// conversation attached to it.
    private var inFlight: [String] = []
    private let log = AppLog.logger("app-intents")

    public init() {}

    public func start(handler: any InboundHandling) async {
        self.handler = handler
    }

    public func stop() async {
        handler = nil
        for (key, waiter) in pending {
            waiter.continuation.resume(returning: .notRunning)
            pending.removeValue(forKey: key)
        }
        inFlight.removeAll()
    }

    // MARK: - the question

    /// Asks the workspace and waits for the answer, the way Shortcuts expects.
    public func ask(_ text: String,
                    scope: Scope = .central,
                    sender: String = "Shortcuts",
                    timeout: Duration = .seconds(90)) async -> IntentAnswer {
        guard let handler else { return .notRunning }
        let key = OpaqueID.make("intent")

        // The turn runs detached from the waiter: a caller that gives up must
        // not cancel work that is already in the hook chain, and Shortcuts
        // gives up on its own schedule.
        let message = IncomingMessage(account: Self.accountID, platform: .appIntents,
                                      chat: key, sender: sender, text: text, scope: scope)
        inFlight.append(key)
        Task { [handler] in await handler.handle(message) }

        let answer = await withCheckedContinuation { continuation in
            pending[key] = Pending(continuation: continuation, blockedOn: nil)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(key)
            }
        }
        return answer
    }

    // MARK: - Channel

    /// The router's reply. Matched back to the caller through the conversation
    /// the router bound to this request.
    public func send(_ message: AgentMessage) async {
        guard message.kind != .progress else { return }
        guard let conversationID = message.conversationID,
              let key = conversations[conversationID] else { return }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        resume(key, with: message.kind == .error ? .answered("ผิดพลาด: \(text)")
                                                 : .answered(text))
    }

    /// Not answered here, on purpose (§8.1). Recorded so the caller is told
    /// where the decision is waiting instead of hearing "took too long".
    public func present(_ request: ApprovalRequest) async {
        for key in inFlight where pending[key] != nil {
            pending[key]?.blockedOn = request.toolName
        }
    }

    public func approvalResolved(_ id: ApprovalRequest.ID, decision: ApprovalDecision) async {
        for key in inFlight { pending[key]?.blockedOn = nil }
    }

    public func bind(conversation: String, to chat: String) async {
        conversations[conversation] = chat
    }

    // MARK: - plumbing

    private func expire(_ key: String) {
        guard let waiter = pending[key] else { return }
        // A turn stopped at the gate has not run out of time; it is waiting
        // for a person, and saying so is the point of tracking it.
        resume(key, with: waiter.blockedOn.map { IntentAnswer.needsApproval(tool: $0) } ?? .timedOut)
    }

    private func resume(_ key: String, with answer: IntentAnswer) {
        guard let waiter = pending.removeValue(forKey: key) else { return }
        inFlight.removeAll { $0 == key }
        conversations = conversations.filter { $0.value != key }
        waiter.continuation.resume(returning: answer)
    }
}
