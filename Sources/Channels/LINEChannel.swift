import Foundation
import CryptoKit
import Network
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// LINE (ARCHITECTURE §8.1, P7.2).
//
// The only channel that has to listen. LINE has no polling API, so this runs a
// small HTTP server and LINE posts to it — which makes two things load-bearing
// that no other channel needs:
//
//  • **The signature.** Anyone who learns the URL can post to it. Every request
//    carries `x-line-signature`, an HMAC-SHA256 of the raw body under the
//    channel secret, and a request that fails it is rejected before it is even
//    parsed as JSON. Compared in constant time, because a comparison that
//    returns early tells an attacker how much of their guess was right.
//  • **The raw body.** The HMAC is over the exact bytes LINE sent. Re-encoding
//    the parsed JSON and hashing that would produce a different digest for the
//    same message, which is the kind of bug that looks like "LINE is broken".
//
// §8.1 also settles the reply mechanism: **push, never the reply token**. A
// reply token is valid for about a minute, and an agent turn that runs a tool
// and waits for an approval is routinely longer than that. Answering with a
// token that has expired fails silently, which is the worst possible way for a
// channel to not work.
// ─────────────────────────────────────────────────────────────

public actor LINEChannel: RunnableChannel {
    public nonisolated let id: ChannelID
    private let account: ChannelAccount
    /// The channel secret, for the signature. Held as a name like every other
    /// secret; read when a request arrives.
    private let secretVariable: String
    private let transport: any HTTPTransport
    private let answering: (any ApprovalAnswering)?
    private let port: UInt16

    private var listener: NWListener?
    private var handler: (any InboundHandling)?
    private var conversationChats: [String: String] = [:]
    private var lastChat: String?
    private var pendingApprovals: [ApprovalRequest.ID: [String]] = [:]

    private let log = AppLog.logger("line")

    public init(account: ChannelAccount,
                secretVariable: String? = nil,
                port: UInt16 = 8_443,
                transport: any HTTPTransport = URLSessionTransport(),
                answering: (any ApprovalAnswering)? = nil) {
        self.id = ChannelID("line:\(account.id)")
        self.account = account
        // The account carries it; the parameter is there for a test that wants
        // to be explicit.
        self.secretVariable = secretVariable ?? account.signingSecretVariable ?? ""
        self.port = port
        self.transport = transport
        self.answering = answering
    }

    // MARK: - lifecycle

    public func start(handler: any InboundHandling) async {
        guard account.isReady else {
            let why = account.blockers.joined(separator: ", ")
            log.error("line '\(self.account.name, privacy: .public)' not started: \(why, privacy: .public)")
            return
        }
        guard SecretStore.has(secretVariable) else {
            log.error("line not started: ยังไม่ได้ตั้ง \(self.secretVariable, privacy: .public)")
            return
        }
        self.handler = handler
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                Task { await self?.serve(connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            log.info("line webhook listening on \(self.port, privacy: .public)")
        } catch {
            log.error("line listener failed: \(error)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        handler = nil
    }

    public func bind(conversation: String, to chat: String) {
        conversationChats[conversation] = chat
    }

    // MARK: - the webhook

    /// Reads one request, answers it, closes. HTTP/1.1 without keep-alive:
    /// LINE opens a connection per delivery, and a connection this server keeps
    /// open is one it has to manage.
    private func serve(_ connection: NWConnection) async {
        guard let request = await Self.readRequest(connection) else {
            connection.cancel()
            return
        }
        let status = await handle(body: request.body, signature: request.signature)
        let response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Unauthorized")\r\n"
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Verifies, parses, filters, delivers. Split out from the socket so the
    /// whole path can be tested by handing it bytes.
    func handle(body: Data, signature: String?) async -> Int {
        guard let secret = SecretStore.value(secretVariable) else { return 401 }
        guard let signature, Self.verify(body: body, signature: signature, secret: secret) else {
            // Not answered with a reason: a server that explains why a
            // signature failed is a server that helps somebody guess.
            log.error("rejected a webhook delivery with a bad signature")
            return 401
        }

        guard let root = try? JSONHelp.object(body),
              let events = root["events"] as? [[String: Any]] else { return 200 }

        for event in events {
            let sourceID = (event["source"] as? [String: Any])
                .flatMap { $0["userId"] as? String ?? $0["groupId"] as? String }
            guard let chat = sourceID else { continue }
            guard account.allows(chat: chat) else {
                log.error("dropped a LINE event from a source that is not on the allow-list")
                continue
            }

            if event["type"] as? String == "postback" {
                await handlePostback(event, chat: chat)
                continue
            }
            guard event["type"] as? String == "message",
                  let message = event["message"] as? [String: Any],
                  message["type"] as? String == "text",
                  let text = message["text"] as? String, !text.isEmpty else { continue }

            lastChat = chat
            await handler?.handle(IncomingMessage(account: account.id,
                                                  platform: .line,
                                                  chat: chat,
                                                  sender: sourceID ?? "unknown",
                                                  text: text,
                                                  scope: account.scope))
        }
        return 200
    }

    private func handlePostback(_ event: [String: Any], chat: String) async {
        guard let data = (event["postback"] as? [String: Any])?["data"] as? String else { return }
        let parts = data.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let requestID = ApprovalRequest.ID(String(parts[1]))
        let decision: ApprovalDecision = parts[0] == "ok"
            ? .approved
            : .rejected(reason: "ไม่อนุมัติจาก LINE")
        let accepted = await answering?.submit(requestID, decision: decision, from: id) ?? false
        if !accepted {
            _ = try? await push(to: chat, text: "มีคนตอบคำขอนี้ไปก่อนแล้ว")
        }
    }

    /// Constant-time comparison of the digest. An early return leaks how many
    /// bytes of a guess were right.
    static func verify(body: Data, signature: String, secret: String) -> Bool {
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let expected = Data(digest).base64EncodedString()
        guard let given = signature.data(using: .utf8),
              let mine = expected.data(using: .utf8),
              given.count == mine.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(given, mine) { difference |= a ^ b }
        return difference == 0
    }

    // MARK: - Channel

    public func send(_ message: AgentMessage) async {
        guard let chat = message.conversationID.flatMap({ conversationChats[$0] }) ?? lastChat else {
            log.debug("dropped a reply with no LINE source to send it to")
            return
        }
        _ = try? await push(to: chat, text: message.text)
    }

    public func present(_ request: ApprovalRequest) async {
        // Quick reply, per §8.1's table. Two buttons and the command itself,
        // for the same reason as everywhere else: a person approves what will
        // actually run.
        let actions: [[String: Any]] = [
            ["type": "action",
             "action": ["type": "postback", "label": "อนุมัติ",
                        "data": "ok:\(request.id.rawValue)", "displayText": "อนุมัติ"]],
            ["type": "action",
             "action": ["type": "postback", "label": "ไม่อนุมัติ",
                        "data": "no:\(request.id.rawValue)", "displayText": "ไม่อนุมัติ"]],
        ]
        var reached: [String] = []
        for chat in account.allowedChats {
            if (try? await push(to: chat, text: TelegramChannel.prompt(for: request),
                                quickReply: ["items": actions])) != nil {
                reached.append(chat)
            }
        }
        pendingApprovals[request.id] = reached
    }

    public func approvalResolved(_ id: ApprovalRequest.ID, decision: ApprovalDecision) async {
        guard let chats = pendingApprovals.removeValue(forKey: id) else { return }
        // LINE has no way to edit a message that has already been delivered, so
        // the outcome is a second message. Saying it twice is better than
        // leaving a live-looking prompt that decides nothing.
        for chat in chats {
            _ = try? await push(to: chat, text: TelegramChannel.outcome(decision))
        }
    }

    // MARK: - the API

    @discardableResult
    private func push(to chat: String, text: String,
                      quickReply: [String: Any]? = nil) async throws -> Data {
        guard let token = account.token else {
            throw TransportError.platform("ยังไม่ได้ตั้งตัวแปร \(account.tokenVariable)")
        }
        var message: [String: Any] = ["type": "text", "text": String(text.prefix(4_900))]
        if let quickReply { message["quickReply"] = quickReply }
        let body: [String: Any] = ["to": chat, "messages": [message]]

        var request = URLRequest(url: URL(string: "https://api.line.me/v2/bot/message/push")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = JSONHelp.encode(body)
        do {
            return try await transport.send(request)
        } catch {
            throw TransportError.platform(redacted("\(error)", token: token))
        }
    }

    // MARK: - a very small HTTP reader

    private struct Request {
        let body: Data
        let signature: String?
    }

    /// Enough HTTP to read one POST: headers, then `Content-Length` bytes. Not
    /// a web server — it answers exactly one correspondent, and anything it
    /// cannot parse is dropped rather than guessed at.
    private static func readRequest(_ connection: NWConnection) async -> Request? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)

        func receive() async -> Data? {
            await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, isComplete, _ in
                    continuation.resume(returning: isComplete && (data?.isEmpty ?? true)
                                        ? nil : data)
                }
            }
        }

        // Headers first.
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard buffer.count < 1_048_576, let chunk = await receive() else { return nil }
            buffer.append(chunk)
            headerEnd = buffer.range(of: separator)
        }
        guard let headerEnd else { return nil }

        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var signature: String?
        var length = 0
        for line in headerText.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "x-line-signature" { signature = value }
            if name == "content-length" { length = Int(value) ?? 0 }
        }

        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < length {
            guard let chunk = await receive() else { break }
            body.append(chunk)
        }
        // The bytes as they arrived. The signature is over these, and
        // re-encoding parsed JSON would hash something else.
        return Request(body: body.prefix(max(length, body.count)), signature: signature)
    }
}
