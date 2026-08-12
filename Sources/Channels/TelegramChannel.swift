import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Telegram (ARCHITECTURE §8.1, P7.1) — the thing v1 left as task K1 and never
// finished: approving a risky action from a phone.
//
// **Long polling, not webhooks.** §8.1 is explicit and it is the right call for
// a laptop: `getUpdates` is an outbound request, so there is no inbound port to
// open, no tunnel, no certificate, and nothing that stops working when the
// machine moves to a different network.
//
// Three things this file is careful about:
//
//  • **It cannot run anything.** This module cannot see `ToolGateway` or any
//    `AgentTool` — an inbound message can only be handed to `InboundHandling`,
//    and an approval only to `ApprovalAnswering`. That is v1's bug B2 made
//    impossible rather than forbidden.
//  • **The allow-list is checked before the message exists as far as the rest
//    of the system is concerned.** A bot's username is public; the token is the
//    only secret; so a stranger who finds the bot must not be able to make it
//    do anything at all.
//  • **The token is in the URL path.** Telegram's API is
//    `api.telegram.org/bot<TOKEN>/method`, so every log line about a failed
//    request would otherwise publish the token. Everything logged here goes
//    through `redacted`.
// ─────────────────────────────────────────────────────────────

public actor TelegramChannel: RunnableChannel {
    public nonisolated let id: ChannelID
    private let account: ChannelAccount
    private let transport: any HTTPTransport
    private let answering: (any ApprovalAnswering)?
    private let pollSeconds: Int

    private var handler: (any InboundHandling)?
    private var pollTask: Task<Void, Never>?
    /// Telegram's cursor. Updates are re-delivered until acknowledged by asking
    /// for a higher offset, which is what makes a restart lose nothing.
    private var offset: Int64 = 0
    /// Which chat a conversation belongs to, so a reply goes back where the
    /// question came from rather than to everyone.
    private var conversationChats: [String: String] = [:]
    /// The last chat that spoke to this bot — where a reply with no
    /// conversation attached goes.
    private var lastChat: String?
    /// The prompts posted for an approval, so they can be edited when it is
    /// answered (here or anywhere else).
    private var approvalMessages: [ApprovalRequest.ID: [(chat: String, message: Int64)]] = [:]

    private let log = AppLog.logger("telegram")

    public init(account: ChannelAccount,
                transport: any HTTPTransport = URLSessionTransport(),
                answering: (any ApprovalAnswering)? = nil,
                pollSeconds: Int = 25) {
        self.id = ChannelID("telegram:\(account.id)")
        self.account = account
        self.transport = transport
        self.answering = answering
        self.pollSeconds = pollSeconds
    }

    // MARK: - lifecycle

    public func start(handler: any InboundHandling) async {
        guard account.isReady else {
            let why = account.blockers.joined(separator: ", ")
            log.error("telegram '\(self.account.name, privacy: .public)' not started: \(why, privacy: .public)")
            return
        }
        self.handler = handler
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.poll() }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        handler = nil
    }

    public func bind(conversation: String, to chat: String) {
        conversationChats[conversation] = chat
    }

    // MARK: - Channel

    public func send(_ message: AgentMessage) async {
        // A reply belongs to the chat that asked. Falling back to "everyone"
        // would turn one person's answer into a broadcast, which on a group
        // chat is how a bot gets muted.
        guard let chat = message.conversationID.flatMap({ conversationChats[$0] }) ?? lastChat else {
            log.debug("dropped a reply with no chat to send it to")
            return
        }
        _ = try? await sendMessage(chat: chat, text: message.text)
    }

    public func present(_ request: ApprovalRequest) async {
        // Broadcast: an approval is not tied to a conversation, and §5.4 says
        // the first answer anywhere wins.
        var posted: [(chat: String, message: Int64)] = []
        for chat in account.allowedChats {
            let keyboard: [String: Any] = ["inline_keyboard": [[
                ["text": "✅ อนุมัติ", "callback_data": "ok:\(request.id.rawValue)"],
                ["text": "⛔️ ไม่อนุมัติ", "callback_data": "no:\(request.id.rawValue)"],
            ]]]
            if let message = try? await sendMessage(chat: chat,
                                                    text: Self.prompt(for: request),
                                                    replyMarkup: keyboard) {
                posted.append((chat, message))
            }
        }
        approvalMessages[request.id] = posted
    }

    public func approvalResolved(_ id: ApprovalRequest.ID, decision: ApprovalDecision) async {
        guard let posted = approvalMessages.removeValue(forKey: id) else { return }
        // Edited rather than left standing: a button that still looks live but
        // does nothing is how a person ends up believing they approved
        // something they did not.
        for entry in posted {
            _ = try? await call("editMessageText", body: [
                "chat_id": entry.chat,
                "message_id": entry.message,
                "text": Self.outcome(decision),
            ])
        }
    }

    // MARK: - polling

    private func poll() async {
        while !Task.isCancelled {
            do {
                let updates = try await getUpdates()
                for update in updates { await handle(update) }
            } catch {
                guard !Task.isCancelled else { return }
                // Never let the loop die: a bad network minute must not end
                // the only way someone can approve something from a phone.
                log.error("poll failed: \(redacted("\(error)", token: self.account.token), privacy: .public)")
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func getUpdates() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "offset": offset,
            "timeout": pollSeconds,
            // Nothing else is acted on, so nothing else is asked for.
            "allowed_updates": ["message", "callback_query"],
        ]
        let result = try await call("getUpdates", body: body)
        return result as? [[String: Any]] ?? []
    }

    private func handle(_ update: [String: Any]) async {
        if let updateID = (update["update_id"] as? NSNumber)?.int64Value {
            // Acknowledged by asking for the next one. Done before the work,
            // so a message that makes this crash is not redelivered forever.
            offset = max(offset, updateID + 1)
        }

        if let callback = update["callback_query"] as? [String: Any] {
            await handle(callback: callback)
            return
        }

        guard let message = update["message"] as? [String: Any],
              let chat = (message["chat"] as? [String: Any])?["id"],
              let text = message["text"] as? String, !text.isEmpty else { return }
        let chatID = Self.identifier(chat)

        guard account.allows(chat: chatID) else {
            // Logged, not answered. Replying would confirm the bot exists to
            // whoever is probing it.
            log.error("dropped a message from chat \(chatID, privacy: .public), which is not on the allow-list")
            return
        }

        let from = message["from"] as? [String: Any]
        let sender = (from?["username"] as? String)
            ?? (from?["first_name"] as? String)
            ?? "unknown"
        lastChat = chatID

        await handler?.handle(IncomingMessage(account: account.id,
                                              platform: .telegram,
                                              chat: chatID,
                                              sender: sender,
                                              text: text,
                                              scope: account.scope))
    }

    private func handle(callback: [String: Any]) async {
        guard let data = callback["data"] as? String,
              let callbackID = callback["id"] as? String else { return }
        let chat = (callback["message"] as? [String: Any])
            .flatMap { $0["chat"] as? [String: Any] }
            .map { Self.identifier($0["id"] ?? "") }

        guard let chat, account.allows(chat: chat) else {
            log.error("dropped a button press from a chat that is not on the allow-list")
            return
        }
        // `callback_data` is capped at 64 bytes by Telegram, which is why the
        // verb is two characters and the rest is the request id.
        let parts = data.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let requestID = ApprovalRequest.ID(String(parts[1]))
        // Approve or reject only. §2.6's "edit the arguments first" needs to
        // see the arguments, and a phone keyboard over a shell command is how
        // an approval becomes a typo.
        let decision: ApprovalDecision = parts[0] == "ok"
            ? .approved
            : .rejected(reason: "ไม่อนุมัติจาก Telegram")

        let accepted = await answering?.submit(requestID, decision: decision, from: id) ?? false
        // Telegram spins the button until this is answered.
        _ = try? await call("answerCallbackQuery", body: [
            "callback_query_id": callbackID,
            "text": accepted ? "บันทึกคำตอบแล้ว" : "มีคนตอบไปก่อนแล้ว",
        ])
        if !accepted {
            // Someone else won. Take our own prompt down so it cannot be
            // pressed again.
            await approvalResolved(requestID, decision: decision)
        }
    }

    // MARK: - the API

    @discardableResult
    private func sendMessage(chat: String, text: String,
                             replyMarkup: [String: Any]? = nil) async throws -> Int64 {
        var body: [String: Any] = ["chat_id": chat, "text": String(text.prefix(4_000))]
        if let replyMarkup { body["reply_markup"] = replyMarkup }
        let result = try await call("sendMessage", body: body)
        return ((result as? [String: Any])?["message_id"] as? NSNumber)?.int64Value ?? 0
    }

    /// One request. Telegram answers `{"ok": …}` on both success and failure,
    /// so a 200 is not a result — `ok: false` carries the real reason and is
    /// turned into an error here rather than read as an empty answer.
    @discardableResult
    private func call(_ method: String, body: [String: Any]) async throws -> Any {
        guard let token = account.token else {
            throw TransportError.platform("ยังไม่ได้ตั้งตัวแปร \(account.tokenVariable)")
        }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TransportError.platform("สร้าง URL ไม่ได้")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSONHelp.encode(body)

        let data = try await transport.send(request)
        let object = try JSONHelp.object(data)
        guard object["ok"] as? Bool == true else {
            throw TransportError.platform(
                redacted("\(object["description"] ?? object)", token: token))
        }
        return object["result"] ?? [:]
    }

    // MARK: - formatting

    /// Chat ids arrive as numbers and are used as strings everywhere else.
    /// `"\(NSNumber)"` would render 12345 as 12345 but a large id in
    /// scientific notation, so it goes through an integer explicitly.
    static func identifier(_ value: Any) -> String {
        if let number = value as? NSNumber { return "\(number.int64Value)" }
        return "\(value)"
    }

    /// What the phone shows. The command itself, verbatim — §5.4's whole point
    /// is that a person approves what will actually run, and a summary is not
    /// something anyone can check from a phone.
    static func prompt(for request: ApprovalRequest) -> String {
        var lines = ["ขออนุมัติ: \(request.toolName) · ความเสี่ยง \(request.risk.rawValue)"]
        lines.append("")
        lines.append(String(request.detail.prefix(1_500)))
        if let policy = request.policyConflict {
            lines.append("")
            lines.append("ขัดกับนโยบาย: \(policy)")
        }
        return lines.joined(separator: "\n")
    }

    static func outcome(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .approved: "✅ อนุมัติแล้ว"
        case .approvedWithEdit: "✅ อนุมัติแล้ว (มีการแก้อาร์กิวเมนต์ก่อนรัน)"
        case .rejected(let reason): "⛔️ ไม่อนุมัติ — \(reason ?? "ไม่ได้ระบุเหตุผล")"
        }
    }
}
