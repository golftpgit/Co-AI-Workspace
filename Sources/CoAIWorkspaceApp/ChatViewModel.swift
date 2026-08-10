import Foundation
import Observation
import AgentKit
import Persistence
import LLMProviders
import CoreEngine

// ─────────────────────────────────────────────────────────────
// Chat view model (ARCHITECTURE §14.2).
//
// It holds no truth of its own: conversations and messages come from the
// database on every load, and approvals come from the broker. v1's chat kept
// its own copy of the transcript and drifted out of sync with what had
// actually been persisted (bug B5's sibling).
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class ChatViewModel {
    struct Bubble: Identifiable {
        enum Kind: Sendable { case user, assistant, tool, note, failure }
        let id: String
        let kind: Kind
        var text: String
        var toolName: String?
        var blocked: Bool = false
    }

    private(set) var conversations: [Conversation] = []
    private(set) var selected: Conversation?
    private(set) var bubbles: [Bubble] = []
    private(set) var isRunning = false
    private(set) var routedVia: String?
    private(set) var loadError: String?

    var input: String = ""
    var pendingApproval: ApprovalRequest?
    /// Filled from the pending request so the user can change the arguments
    /// before saying yes (§2.6 manual override).
    var approvalEdit: String = ""
    var editingApproval = false

    var modes: OperatingModes = .default {
        didSet {
            let modes = modes
            Task { await engine.gateway.setModes(modes) }
        }
    }

    /// Where `run_shell` runs. Chosen by the user, so the App Sandbox grants
    /// access to it and only it.
    var workingDirectory: URL?

    private let engine: Engine
    private let scope: Scope
    private var turn: Task<Void, Never>?

    init(engine: Engine, scope: Scope = .central) {
        self.engine = engine
        self.scope = scope
        subscribeToApprovals()
    }

    // MARK: - conversations

    func load() async {
        do {
            conversations = try await engine.conversations.list(scope: scope)
            loadError = nil
            if selected == nil, let first = conversations.first {
                await select(first)
            }
        } catch {
            loadError = "โหลดรายการบทสนทนาไม่สำเร็จ: \(error)"
        }
    }

    func newConversation() async {
        do {
            let conversation = try await engine.conversations.create(scope: scope)
            conversations.insert(conversation, at: 0)
            selected = conversation
            bubbles = []
        } catch {
            loadError = "สร้างบทสนทนาใหม่ไม่สำเร็จ: \(error)"
        }
    }

    func select(_ conversation: Conversation) async {
        selected = conversation
        await reloadMessages()
    }

    func delete(_ conversation: Conversation) async {
        try? await engine.conversations.delete(conversation.id)
        conversations.removeAll { $0.id == conversation.id }
        if selected?.id == conversation.id {
            selected = conversations.first
            await reloadMessages()
        }
    }

    /// The transcript always comes from the database, never from what this
    /// object happened to accumulate while the turn ran.
    private func reloadMessages() async {
        guard let selected else { bubbles = []; return }
        do {
            bubbles = try await engine.conversations.history(conversationID: selected.id).map(Self.bubble(from:))
        } catch {
            loadError = "โหลดข้อความไม่สำเร็จ: \(error)"
        }
    }

    // MARK: - turns

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }

        if selected == nil { await newConversation() }
        guard let conversation = selected else { return }

        input = ""
        isRunning = true
        routedVia = nil
        bubbles.append(Bubble(id: UUID().uuidString, kind: .user, text: text))

        let stream = await engine.runner.run(userText: text,
                                             conversationID: conversation.id,
                                             scope: scope,
                                             workingDirectory: workingDirectory)
        // Inherits MainActor isolation, so every bubble update lands on the
        // main actor without hopping.
        turn = Task { [weak self] in
            for await event in stream { self?.apply(event) }
            self?.isRunning = false
            self?.turn = nil
            await self?.load()
        }
    }

    /// Stop is a real stop: the turn is cancelled and anything it was waiting
    /// for a human to answer is released rather than left hanging (§5.7).
    func stop() {
        turn?.cancel()
        turn = nil
        isRunning = false
        Task { await engine.broker.cancelAll() }
    }

    private func apply(_ event: TurnEvent) {
        switch event {
        case .userMessageStored:
            break                                   // already on screen
        case .routed(let executor, let tier):
            routedVia = "\(executor) · tier \(tier.rawValue)"
        case .assistantDelta(let chunk):
            appendToStreamingBubble(chunk)
        case .toolCallStarted(let name, let arguments):
            bubbles.append(Bubble(id: UUID().uuidString, kind: .tool,
                                  text: arguments, toolName: name))
        case .toolCallFinished(let name, let text, let executed):
            bubbles.append(Bubble(id: UUID().uuidString, kind: .tool, text: text,
                                  toolName: name, blocked: !executed))
        case .note(let text):
            bubbles.append(Bubble(id: UUID().uuidString, kind: .note, text: text))
        case .assistantMessageStored:
            // Close the streaming bubble so the next round starts a new one.
            streamingBubbleID = nil
        case .failed(let reason):
            bubbles.append(Bubble(id: UUID().uuidString, kind: .failure, text: reason))
        case .finished:
            streamingBubbleID = nil
        }
    }

    private var streamingBubbleID: String?

    private func appendToStreamingBubble(_ chunk: String) {
        if let id = streamingBubbleID, let index = bubbles.firstIndex(where: { $0.id == id }) {
            bubbles[index].text += chunk
        } else {
            let bubble = Bubble(id: UUID().uuidString, kind: .assistant, text: chunk)
            streamingBubbleID = bubble.id
            bubbles.append(bubble)
        }
    }

    // MARK: - approvals

    /// The GUI is just another channel (§5.4): it presents and it answers, and
    /// it is told when someone else answered first.
    private func subscribeToApprovals() {
        let channel = CallbackChannel(
            id: ChannelID("gui"),
            onPresent: { [weak self] request in
                await MainActor.run {
                    self?.pendingApproval = request
                    self?.approvalEdit = request.detail
                    self?.editingApproval = false
                }
            },
            onResolved: { [weak self] id, _ in
                await MainActor.run {
                    if self?.pendingApproval?.id == id { self?.pendingApproval = nil }
                }
            })
        Task { await engine.broker.subscribe(channel) }
    }

    func respond(_ decision: ApprovalDecision) {
        guard let request = pendingApproval else { return }
        pendingApproval = nil
        Task { await engine.broker.submit(request.id, decision: decision, from: ChannelID("gui")) }
    }

    // MARK: - display

    private static func bubble(from message: StoredMessage) -> Bubble {
        switch message.role {
        case .user: return Bubble(id: message.id, kind: .user, text: message.content)
        case .assistant: return Bubble(id: message.id, kind: .assistant, text: message.content)
        case .system: return Bubble(id: message.id, kind: .note, text: message.content)
        case .tool:
            // Stored as "toolName\noutput" by the turn runner.
            let parts = message.content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return Bubble(id: message.id, kind: .tool,
                          text: parts.count > 1 ? String(parts[1]) : message.content,
                          toolName: parts.first.map(String.init))
        }
    }
}
