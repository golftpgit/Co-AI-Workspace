import Foundation
import Observation
import AgentKit
import Persistence
import LLMProviders
import CoreEngine
import MLXRuntime

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
        /// Still waiting on the gate, a human, or the process itself.
        var running: Bool = false
        var blocked: Bool = false
    }

    private(set) var conversations: [Conversation] = []
    private(set) var selected: Conversation?
    private(set) var bubbles: [Bubble] = []
    private(set) var isRunning = false
    private(set) var routedVia: String?
    private(set) var loadError: String?
    /// The context meter. Kept in front of the user the whole time rather than
    /// appearing once as a note when compaction happens: by then the messages
    /// they were reading have already been summarised away (§5.6).
    private(set) var contextTokens = 0
    private(set) var contextBudget = 0
    /// Which local model Tier 0.5 will use, and what else is installed —
    /// switchable from the composer, because the model is a decision about
    /// *this* turn, not a setting to go and find.
    private(set) var localModels: [LocalModel] = []
    private(set) var localModelName: String?
    private(set) var localModelResident = false

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
    }

    /// The conversation as the brief drafter reads it (§19.1, P10.3). Tool
    /// output and system notes are left out: the draft is about what was
    /// *asked for*, and a transcript full of shell output drowns that.
    var transcriptTurns: [TranscriptTurn] {
        bubbles.compactMap { bubble in
            switch bubble.kind {
            case .user: TranscriptTurn(fromUser: true, text: bubble.text)
            case .assistant: TranscriptTurn(fromUser: false, text: bubble.text)
            case .tool, .note, .failure: nil
            }
        }
    }

    var promotableConversationID: String? {
        guard case .central = scope else { return nil }
        return selected?.id
    }

    func draftBrief() async -> DraftedBrief {
        await engine.briefDrafter.draft(from: transcriptTurns)
    }

    /// A project starts with a working directory of its own (§19.1): its
    /// folder inside the app container, which a sandboxed app reaches without
    /// the user granting anything. General still starts with none — a shell
    /// command with nowhere agreed to run is a question, not a default. The
    /// folder button overrides either.
    func adoptDefaultWorkingDirectory() async {
        guard workingDirectory == nil else { return }
        workingDirectory = await engine.stores(for: scope).workingDirectory
    }

    /// Subscribing is deliberately *not* done in `init`.
    ///
    /// SwiftUI evaluates a view's `init` on every body pass, so building the
    /// view model there produced a new one each time — and each new one
    /// subscribed a channel under the same id, replacing the last. The broker
    /// then presented approvals to a view model nobody was rendering: no
    /// banner appeared, and the turn waited for an answer that could never
    /// come. Attaching from the view's `task`, on the instance `@State`
    /// actually kept, is what ties the subscription to what is on screen.
    func attach() async {
        await engine.broker.subscribe(guiChannel())
        // A request raised before the window was ready is still outstanding;
        // the broker replays it on subscribe, so nothing is lost across a
        // reopen either.
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

    // MARK: - the model behind Tier 0.5

    func refreshLocalModels() async {
        localModels = await engine.modelCatalog.installed()
        localModelName = engine.localTier.selected?.name
        localModelResident = await engine.localTier.isResident
    }

    func useLocalModel(_ model: LocalModel) async {
        engine.localTier.select(model)
        await refreshLocalModels()
    }

    /// Hands the memory back without quitting anything. The next message
    /// reloads the weights; on a 16 GB machine that trade is often worth it,
    /// which is why LM Studio puts an eject button on every loaded model.
    func unloadLocalModel() async {
        await engine.localTier.unloadSelected()
        await refreshLocalModels()
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
            routedVia = "\(executor) · tier \(tier.label)"
        case .usage(let prompt, let completion, let budget):
            // The prompt is what fills the window; the completion joins it on
            // the next turn.
            contextTokens = prompt + completion
            contextBudget = budget
        case .assistantDelta(let chunk):
            appendToStreamingBubble(chunk)
        // One call, one card. It appears with the arguments the moment the
        // model asks, then becomes the result in place — appending a second
        // card made every tool call look like it happened twice.
        case .toolCallStarted(let id, let name, let arguments):
            streamingBubbleID = nil
            bubbles.append(Bubble(id: id, kind: .tool, text: arguments,
                                  toolName: name, running: true))
        case .toolCallFinished(let id, let name, let text, let executed):
            let updated = Bubble(id: id, kind: .tool, text: text,
                                 toolName: name, running: false, blocked: !executed)
            if let index = bubbles.firstIndex(where: { $0.id == id }) {
                bubbles[index] = updated
            } else {
                bubbles.append(updated)
            }
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
    private func guiChannel() -> CallbackChannel {
        CallbackChannel(
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
            // Including whether it ran. Reading this back as "ran fine"
            // turned every refusal in the history into a success.
            let entry = ToolTranscript.decode(message.content)
            return Bubble(id: message.id, kind: .tool, text: entry.text,
                          toolName: entry.toolName, blocked: !entry.executed)
        }
    }
}
