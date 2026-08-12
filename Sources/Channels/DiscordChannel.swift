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

    private var handler: (any InboundHandling)?
    private var readTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// Discord's message sequence, echoed back with every heartbeat.
    private var sequence: Int?
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
                gatewayURL: URL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!) {
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
        do {
            try await socket.connect(to: gatewayURL)
        } catch {
            log.error("discord gateway: \(error)")
            return
        }
        readTask = Task { [weak self] in await self?.readLoop() }
    }

    public func stop() async {
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
            await identify()
            startHeartbeat(milliseconds: interval)
        case 1:                                         // Discord asked for one now
            await beat()
        case 0:                                         // Dispatch
            await dispatch(payload)
        case 9:                                         // Invalid session
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
