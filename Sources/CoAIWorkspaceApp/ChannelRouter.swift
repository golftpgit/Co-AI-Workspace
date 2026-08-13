import Foundation
import AgentKit
import Channels
import CoreEngine
import Persistence
import Observability

// ─────────────────────────────────────────────────────────────
// Where a message from a phone becomes a turn (ARCHITECTURE §8.2, P7.1/P7.4).
//
// This file is the whole reason the channels module is allowed to know nothing:
// it is the **only** thing that connects an inbound message to the engine, it
// lives in the app where the engine is assembled, and it does so by calling the
// same `AgentTurnRunner` the chat window calls. Not a similar path — the same
// object. §8.2's "ทุก channel วิ่งผ่าน Core เดียวกัน" is true here by
// construction rather than by care.
//
// v1's bug B2 was the alternative: a bridge that grew its own way of running
// things and never passed the hook chain.
// ─────────────────────────────────────────────────────────────

/// One conversation per chat, remembered so a phone conversation has a history
/// the way the window does.
actor ChannelRouter: InboundHandling {
    private let runner: AgentTurnRunner
    private let conversations: ConversationStore
    private let modes: OperatingModes
    /// chat key → conversation id.
    private var conversationIDs: [String: String] = [:]
    private var channels: [String: any RunnableChannel] = [:]
    private let log = AppLog.logger("channel-router")

    init(runner: AgentTurnRunner, conversations: ConversationStore, modes: OperatingModes) {
        self.runner = runner
        self.conversations = conversations
        self.modes = modes
    }

    func register(_ channel: any RunnableChannel, for account: String) {
        channels[account] = channel
    }

    func handle(_ message: IncomingMessage) async {
        let key = "\(message.account)/\(message.chat)"
        let conversationID: String
        if let existing = conversationIDs[key] {
            conversationID = existing
        } else {
            // Titled by where it came from, so the same thread is recognisable
            // in the window that the phone is talking to.
            let created = (try? await conversations.create(
                scope: message.scope,
                title: "\(message.platform.label) · \(message.sender)"))?.id
                ?? OpaqueID.make(OpaqueID.conversation)
            conversationIDs[key] = created
            conversationID = created
        }

        let channel = channels[message.account]
        await channel?.bind(conversation: conversationID, to: message.chat)

        // The same runner the chat window uses. Everything that follows —
        // routing, the hook chain, approval, spans — is the one path.
        var answer = ""
        for await event in await runner.run(userText: message.text,
                                            conversationID: conversationID,
                                            scope: message.scope) {
            switch event {
            case .assistantDelta(let text):
                answer += text
            case .toolCallFinished(let id, let name, _, let executed):
                _ = id
                // Said out loud: on a phone there is no card to look at, and a
                // command that was refused must not read as one that ran.
                if !executed {
                    await channel?.send(AgentMessage(kind: .progress,
                                                     text: "· \(name): ไม่ได้รัน",
                                                     conversationID: conversationID))
                }
            case .failed(let reason):
                await channel?.send(AgentMessage(kind: .error, text: "ผิดพลาด: \(reason)",
                                                 conversationID: conversationID))
            case .finished:
                let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    await channel?.send(AgentMessage(text: text, conversationID: conversationID))
                }
            default:
                continue
            }
        }
        _ = modes
    }

    /// Sends one message to every channel that is running (§19.10). Used by
    /// the exception report, which is the one thing whose whole purpose is to
    /// reach the person wherever they are — the same text everywhere, rendered
    /// once by the report itself.
    func broadcast(_ text: String) async {
        for channel in channels.values {
            await channel.send(AgentMessage(kind: .summary, text: text))
        }
    }

    func stopAll() async {
        for channel in channels.values { await channel.stop() }
        channels = [:]
    }
}
