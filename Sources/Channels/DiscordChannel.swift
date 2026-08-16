import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Discord (ARCHITECTURE §8.1, P7.2).
//
// A Gateway WebSocket rather than polling, because that is the only way
// Discord delivers messages. The handshake §8.1 names is the whole protocol:
// Hello (op 10) carries the heartbeat interval → Identify (op 2) says who we
// are and what we want → Heartbeat (op 1) on that interval forever → Dispatch
// (op 0) carries MESSAGE_CREATE.
//
// Two rules that are not optional:
//
//  • **Filter our own messages.** The bot sees everything in the channel,
//    including what it just said. Without the check, the first reply becomes
//    the next prompt and the bot talks to itself until somebody notices — for
//    a system that can run shell commands, that is not a funny bug.
//  • **Stop heartbeating when the socket dies.** A heartbeat task that outlives
//    its connection is a leak that looks like nothing until there are twenty of
//    them.
//
// The socket is behind a protocol so the handshake, the filtering and the
// button handling can be driven from a test with no token and no network. What
// is *not* covered that way is whether Discord accepts our Identify payload —
// that needs a real bot, and it is the one thing left open here.
// ─────────────────────────────────────────────────────────────

/// The little of a WebSocket this channel needs.
public protocol GatewaySocket: Sendable {
    func connect(to url: URL) async throws
    func send(_ text: String) async throws
    /// One frame, or nil when the socket has closed.
    func receive() async throws -> String?
    func close() async
}

public actor URLSessionGatewaySocket: GatewaySocket {
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)

    public init() {}

    public func connect(to url: URL) async throws {
        let task = session.webSocketTask(with: url)
        task.resume()
        self.task = task
    }

    public func send(_ text: String) async throws {
        try await task?.send(.string(text))
    }

    public func receive() async throws -> String? {
        guard let task else { return nil }
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return nil
        }
    }

    public func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

public actor DiscordChannel: RunnableChannel {
    public nonisolated let id: ChannelID
    private let account: ChannelAccount
    private let socket: any GatewaySocket
    private let transport: any HTTPTransport
    private let answering: (any ApprovalAnswering)?
    private let gatewayURL: URL
    /// How long to wait before the first reconnect. A second in the app;
    /// injected so a test can prove the loop reconnects without waiting a
    /// second for it, which is the sort of sleep that turns a suite flaky on a
    /// busy machine.
    private let firstReconnectDelay: Duration

    private var handler: (any InboundHandling)?
    private var readTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// Discord's message sequence, echoed back with every heartbeat **and**
    /// with a resume — it is how the gateway knows what we already saw.
    private var sequence: Int?
    /// What a resume needs: the session Discord opened and where it says to
    /// reconnect. Both arrive in READY and both are gone once the gateway
    /// invalidates the session (op 9).
    private var sessionID: String?
    private var resumeURL: String?
    /// Our own application id, learned from READY. Until it arrives, messages
    /// are matched against the bot flag alone.
    private var selfID: String?
    private var conversationChannels: [String: String] = [:]
    private var lastChannel: String?
    private var pendingApprovals: [ApprovalRequest.ID: [(channel: String, message: String)]] = [:]

    private let log = AppLog.logger("discord")

    public init(account: ChannelAccount,
                socket: any GatewaySocket = URLSessionGatewaySocket(),
                transport: any HTTPTransport = URLSessionTransport(),
                answering: (any ApprovalAnswering)? = nil,
                gatewayURL: URL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!,
                firstReconnectDelay: Duration = .seconds(1)) {
        self.firstReconnectDelay = firstReconnectDelay
        self.id = ChannelID("discord:\(account.id)")
        self.account = account
        self.socket = socket
        self.transport = transport
        self.answering = answering
        self.gatewayURL = gatewayURL
    }

    // MARK: - lifecycle

    public func start(handler: any InboundHandling) async {
        guard account.isReady else {
            let why = account.blockers.joined(separator: ", ")
            log.error("discord '\(self.account.name, privacy: .public)' not started: \(why, privacy: .public)")
            return
        }
        self.handler = handler
        readTask = Task { [weak self] in await self?.stayConnected() }
    }

    /// Reconnects until somebody stops it.
    ///
    /// The socket dropping is ordinary — a laptop lid, a router, Discord
    /// moving us (op 7). What was not ordinary is what happened next: the read
    /// loop ended and nothing reconnected, so a bot went quiet until the app
    /// was restarted, and the person on the other end saw a bot that had
    /// stopped answering rather than a bot that was gone.
    ///
    /// Backoff, because a gateway that is refusing us is a gateway a tight
    /// loop makes angrier: Discord rate-limits identifies, and the punishment
    /// for hammering is a longer ban than the outage.
    private func stayConnected() async {
        var delay = firstReconnectDelay
        let ceiling = Duration.seconds(60)

        while !Task.isCancelled {
            // A resume goes to the URL Discord handed out for this session;
            // a fresh start goes to the front door.
            let url = reconnectURL.flatMap(URL.init(string:)) ?? gatewayURL
            do {
                try await socket.connect(to: url)
                delay = firstReconnectDelay
            } catch {
                log.error("discord gateway: \(redacted("\(error)", token: self.account.token), privacy: .public)")
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, ceiling)
                continue
            }

            await readLoop()
            guard !Task.isCancelled else { return }
            // The read loop only ends when the socket does. Sleep before
            // trying again so a gateway that is rejecting us is not asked
            // sixty times a second.
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, ceiling)
        }
    }

    public func stop() async {
        // Cancelled first, so the reconnect loop sees the cancellation rather
        // than the closed socket and tries to come back.
        readTask?.cancel(); readTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        await socket.close()
        handler = nil
    }

    public func bind(conversation: String, to chat: String) {
        conversationChannels[conversation] = chat
    }

    // MARK: - the gateway

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                guard let frame = try await socket.receive() else { break }
                await handle(frame: frame)
            } catch {
                guard !Task.isCancelled else { break }
                log.error("gateway read: \(redacted("\(error)", token: self.account.token), privacy: .public)")
                break
            }
        }
        // The socket is gone; the heartbeat must go with it.
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func handle(frame: String) async {
        guard let data = frame.data(using: .utf8),
              let payload = try? JSONHelp.object(data) else { return }
        if let sequence = (payload["s"] as? NSNumber)?.intValue { self.sequence = sequence }

        switch (payload["op"] as? NSNumber)?.intValue {
        case 10:                                        // Hello
            let interval = ((payload["d"] as? [String: Any])?["heartbeat_interval"] as? NSNumber)?
                .doubleValue ?? 45_000
            // Resume when there is a session to resume, identify when there is
            // not. A fresh identify after a dropped socket is not a slower
            // reconnect — it is a reconnect that **loses the messages sent
            // while we were away**, because only a resume makes the gateway
            // replay them.
            if sessionID != nil {
                await resume()
            } else {
                await identify()
            }
            startHeartbeat(milliseconds: interval)
        case 1:                                         // Discord asked for one now
            await beat()
        case 0:                                         // Dispatch
            await dispatch(payload)
        case 7:                                         // Reconnect, please
            // Discord asking us to move. The session stays valid, so the next
            // Hello resumes rather than starting again.
            log.info("discord asked for a reconnect — will resume")
        case 9:                                         // Invalid session
            // The session cannot be resumed, whatever we have stored. Keeping
            // it would mean resuming onto a session Discord has thrown away,
            // which is answered with another op 9 — a loop that never reaches
            // an identify.
            sessionID = nil
            resumeURL = nil
            log.error("discord rejected the session — check the bot token and its intents")
        default:
            break
        }
    }

    private func identify() async {
        guard let token = account.token else { return }
        // Intent 1<<15 is MESSAGE_CONTENT, which is what makes `content`
        // non-empty; without it Discord delivers messages with the text
        // stripped and everything looks like an empty prompt.
        let payload: [String: Any] = [
            "op": 2,
            "d": ["token": token,
                  "intents": (1 << 9) | (1 << 15),
                  "properties": ["os": "macOS", "browser": "co-ai", "device": "co-ai"]],
        ]
        try? await socket.send(String(decoding: JSONHelp.encode(payload), as: UTF8.self))
    }

    /// Picks the session back up (op 6) instead of starting a new one.
    ///
    /// The sequence number is the whole point: it tells the gateway the last
    /// event we actually saw, and everything after it is replayed. Sending
    /// this with a stale or missing sequence would ask for a replay from the
    /// wrong place, so it is only sent when there is a session *and* a
    /// sequence to go with it.
    private func resume() async {
        guard let token = account.token, let sessionID, let sequence else {
            await identify()
            return
        }
        let payload: [String: Any] = [
            "op": 6,
            "d": ["token": token, "session_id": sessionID, "seq": sequence],
        ]
        try? await socket.send(String(decoding: JSONHelp.encode(payload), as: UTF8.self))
    }

    /// Where to reconnect. Discord hands out a per-session URL in READY and
    /// asks that a resume goes there rather than to the front door.
    var reconnectURL: String? { sessionID == nil ? nil : resumeURL }

    private func startHeartbeat(milliseconds: Double) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(milliseconds)))
                guard !Task.isCancelled else { return }
                await self?.beat()
            }
        }
    }

    private func beat() async {
        let payload: [String: Any] = ["op": 1, "d": sequence as Any]
        try? await socket.send(String(decoding: JSONHelp.encode(payload), as: UTF8.self))
    }

    private func dispatch(_ payload: [String: Any]) async {
        let event = payload["t"] as? String
        let data = payload["d"] as? [String: Any] ?? [:]

        switch event {
        case "READY":
            selfID = ((data["user"] as? [String: Any])?["id"] as? String)
            sessionID = data["session_id"] as? String
            resumeURL = data["resume_gateway_url"] as? String
        case "RESUMED":
            // Everything sent while the socket was down has just been
            // replayed. Said out loud because a silent resume and a silent
            // reconnect-that-lost-messages look identical from outside.
            log.info("discord session resumed — missed messages replayed")
        case "MESSAGE_CREATE":
            await handleMessage(data)
        case "INTERACTION_CREATE":
            await handleInteraction(data)
        default:
            break
        }
    }

    private func handleMessage(_ data: [String: Any]) async {
        let author = data["author"] as? [String: Any] ?? [:]
        // Our own messages, and every other bot's. Without this the first reply
        // becomes the next prompt.
        if author["bot"] as? Bool == true { return }
        if let selfID, author["id"] as? String == selfID { return }

        guard let channel = data["channel_id"] as? String,
              let text = data["content"] as? String, !text.isEmpty else { return }
        guard account.allows(chat: channel) else {
            log.error("dropped a Discord message from a channel that is not on the allow-list")
            return
        }
        lastChannel = channel
        await handler?.handle(IncomingMessage(account: account.id,
                                              platform: .discord,
                                              chat: channel,
                                              sender: author["username"] as? String ?? "unknown",
                                              text: text,
                                              scope: account.scope))
    }

    private func handleInteraction(_ data: [String: Any]) async {
        guard let customID = (data["data"] as? [String: Any])?["custom_id"] as? String,
              let interactionID = data["id"] as? String,
              let token = data["token"] as? String else { return }
        let channel = data["channel_id"] as? String
        guard let channel, account.allows(chat: channel) else {
            log.error("dropped a Discord button press from a channel that is not allowed")
            return
        }
        let parts = customID.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let requestID = ApprovalRequest.ID(String(parts[1]))
        let decision: ApprovalDecision = parts[0] == "ok"
            ? .approved
            : .rejected(reason: "ไม่อนุมัติจาก Discord")

        let accepted = await answering?.submit(requestID, decision: decision, from: id) ?? false
        // Discord shows the button spinning until the interaction is answered,
        // and gives three seconds to do it.
        _ = try? await post(
            "interactions/\(interactionID)/\(token)/callback",
            body: ["type": 4,
                   "data": ["content": accepted ? TelegramChannel.outcome(decision)
                                                : "มีคนตอบไปก่อนแล้ว"]])
        if !accepted { await approvalResolved(requestID, decision: decision) }
    }

    // MARK: - Channel

    public func send(_ message: AgentMessage) async {
        guard let channel = message.conversationID.flatMap({ conversationChannels[$0] })
                ?? lastChannel else {
            log.debug("dropped a reply with no Discord channel to send it to")
            return
        }
        _ = try? await post("channels/\(channel)/messages",
                            body: ["content": String(message.text.prefix(1_900))])
    }

    public func present(_ request: ApprovalRequest) async {
        let components: [[String: Any]] = [[
            "type": 1,                                  // action row
            "components": [
                ["type": 2, "style": 3, "label": "อนุมัติ",
                 "custom_id": "ok:\(request.id.rawValue)"],
                ["type": 2, "style": 4, "label": "ไม่อนุมัติ",
                 "custom_id": "no:\(request.id.rawValue)"],
            ],
        ]]
        var posted: [(channel: String, message: String)] = []
        for channel in account.allowedChats {
            guard let data = try? await post("channels/\(channel)/messages", body: [
                "content": TelegramChannel.prompt(for: request),
                "components": components,
            ]) else { continue }
            if let id = (try? JSONHelp.object(data))?["id"] as? String {
                posted.append((channel, id))
            }
        }
        pendingApprovals[request.id] = posted
    }

    public func approvalResolved(_ id: ApprovalRequest.ID, decision: ApprovalDecision) async {
        guard let posted = pendingApprovals.removeValue(forKey: id) else { return }
        for entry in posted {
            // Editing removes the components: a button that no longer decides
            // anything must not still look pressable.
            _ = try? await patch("channels/\(entry.channel)/messages/\(entry.message)",
                                 body: ["content": TelegramChannel.outcome(decision),
                                        "components": []])
        }
    }

    // MARK: - the REST API

    @discardableResult
    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        try await call(path, method: "POST", body: body)
    }

    @discardableResult
    private func patch(_ path: String, body: [String: Any]) async throws -> Data {
        try await call(path, method: "PATCH", body: body)
    }

    private func call(_ path: String, method: String, body: [String: Any]) async throws -> Data {
        guard let token = account.token else {
            throw TransportError.platform("ยังไม่ได้ตั้งตัวแปร \(account.tokenVariable)")
        }
        var request = URLRequest(url: URL(string: "https://discord.com/api/v10/\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // "Bot " is not decoration — Discord rejects a bare token.
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = JSONHelp.encode(body)
        do {
            return try await transport.send(request)
        } catch {
            throw TransportError.platform(redacted("\(error)", token: token))
        }
    }
}
