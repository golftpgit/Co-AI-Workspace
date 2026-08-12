import Testing
import Foundation
import AgentKit
@testable import Channels

// ─────────────────────────────────────────────────────────────
// Telegram, driven end to end without a bot token (ARCHITECTURE §8, P7.1/P7.3).
//
// The transport is injected, so these tests hand the channel the exact JSON
// Telegram sends and assert on what it does with it — including the two things
// that matter most and are hardest to check by hand: that a chat which is not
// on the allow-list gets nowhere, and that the token never appears in anything
// that can be logged.
// ─────────────────────────────────────────────────────────────

/// Records what was sent and replies with whatever the test queued.
private actor StubTransport: HTTPTransport {
    /// The request as it went out. The body is kept as bytes rather than as a
    /// dictionary because `[String: Any]` is not `Sendable` (App. C) — decoded
    /// on demand by whichever test wants to look inside.
    struct Call: Sendable {
        let method: String
        let bodyData: Data

        var body: [String: Any] {
            ((try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]) ?? [:]
        }

        func string(_ key: String) -> String? { body[key] as? String }
    }

    private var responses: [String: [Data]] = [:]
    private(set) var calls: [Call] = []
    /// Set when a request URL contains something it must not.
    private(set) var leakedToken = false
    private let token: String

    init(token: String) { self.token = token }

    func queue(_ method: String, _ json: String) {
        responses[method, default: []].append(Data(json.utf8))
    }

    func send(_ request: URLRequest) async throws -> Data {
        let method = request.url?.lastPathComponent ?? ""
        // The token lives in the URL path; if it ever reached a place it should
        // not, this is where it would show up.
        if request.url?.absoluteString.contains(token) != true { leakedToken = true }
        calls.append(Call(method: method, bodyData: request.httpBody ?? Data()))

        if var queued = responses[method], !queued.isEmpty {
            let next = queued.removeFirst()
            responses[method] = queued
            return next
        }
        // Anything not queued answers the way Telegram answers a no-op.
        return Data(#"{"ok":true,"result":[]}"#.utf8)
    }

    func calls(to method: String) -> [Call] { calls.filter { $0.method == method } }
    func noteLeak() { leakedToken = true }
}

private actor Recorder: InboundHandling {
    private(set) var messages: [IncomingMessage] = []
    func handle(_ message: IncomingMessage) async { messages.append(message) }
}

private actor Answerer: ApprovalAnswering {
    private(set) var submitted: [(ApprovalRequest.ID, ApprovalDecision)] = []
    private var accepts: Bool

    init(accepts: Bool = true) { self.accepts = accepts }

    func submit(_ id: ApprovalRequest.ID, decision: ApprovalDecision,
                from channel: ChannelID?) async -> Bool {
        submitted.append((id, decision))
        return accepts
    }
}

private func account(allowing chats: [String] = ["555"]) -> ChannelAccount {
    SecretStore.override("COAI_TEST_TELEGRAM_TOKEN", "123456:SECRET-TOKEN")
    return ChannelAccount(id: "acc1", platform: .telegram, name: "บอททดสอบ",
                          tokenVariable: "COAI_TEST_TELEGRAM_TOKEN",
                          allowedChats: chats)
}

private func update(chat: String, text: String, id: Int = 1) -> String {
    """
    {"ok":true,"result":[{"update_id":\(id),"message":{"message_id":9,
      "chat":{"id":\(chat)},"from":{"username":"panupong"},"text":"\(text)"}}]}
    """
}

@Suite("Telegram channel", .serialized)
struct TelegramChannelTests {

    @Test("a message from an allowed chat reaches the core, once")
    func allowedMessageIsDelivered() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        await transport.queue("getUpdates", update(chat: "555", text: "สรุปงานวันนี้ให้หน่อย"))
        let channel = TelegramChannel(account: account(), transport: transport, pollSeconds: 0)
        let recorder = Recorder()

        await channel.start(handler: recorder)
        try await Task.sleep(for: .milliseconds(300))
        await channel.stop()

        let messages = await recorder.messages
        #expect(messages.count == 1)
        #expect(messages[0].text == "สรุปงานวันนี้ให้หน่อย")
        #expect(messages[0].chat == "555")
        #expect(messages[0].sender == "panupong")
        #expect(messages[0].platform == .telegram)
    }

    /// §8.2's allow-list. A bot's username is public and its token is the only
    /// secret, so a stranger who finds the bot must get nowhere at all — not
    /// even an answer that confirms it is there.
    @Test("a message from a chat that is not on the allow-list gets nowhere")
    func allowListIsEnforced() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        await transport.queue("getUpdates", update(chat: "999", text: "rm -rf /"))
        let channel = TelegramChannel(account: account(allowing: ["555"]),
                                      transport: transport, pollSeconds: 0)
        let recorder = Recorder()

        await channel.start(handler: recorder)
        try await Task.sleep(for: .milliseconds(300))
        await channel.stop()

        #expect(await recorder.messages.isEmpty)
        // And it was not answered either: a reply would confirm the bot exists.
        #expect(await transport.calls(to: "sendMessage").isEmpty)
    }

    /// An empty allow-list means nobody, never everybody.
    @Test("an account with an empty allow-list does not start")
    func emptyAllowListMeansNobody() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        await transport.queue("getUpdates", update(chat: "555", text: "สวัสดี"))
        let empty = ChannelAccount(platform: .telegram, name: "ยังไม่ตั้ง",
                                   tokenVariable: "COAI_TEST_TELEGRAM_TOKEN",
                                   allowedChats: [])
        #expect(!empty.isReady)
        #expect(empty.blockers.contains { $0.contains("chat id") })

        let channel = TelegramChannel(account: empty, transport: transport, pollSeconds: 0)
        await channel.start(handler: Recorder())
        try await Task.sleep(for: .milliseconds(200))
        await channel.stop()
        #expect(await transport.calls.isEmpty)
    }

    @Test("an account with no token in the environment says so instead of polling")
    func missingTokenIsAState() async {
        let account = ChannelAccount(platform: .telegram, name: "ไม่มีโทเคน",
                                     tokenVariable: "COAI_DEFINITELY_UNSET_TOKEN",
                                     allowedChats: ["555"])
        #expect(account.token == nil)
        #expect(!account.isReady)
        #expect(account.blockers.contains { $0.contains("COAI_DEFINITELY_UNSET_TOKEN") })
    }

    /// §5.4: the person approving has to see what will actually run.
    @Test("an approval request goes out with buttons and the command verbatim")
    func approvalIsPresentedWithButtons() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        await transport.queue("sendMessage", #"{"ok":true,"result":{"message_id":42}}"#)
        let channel = TelegramChannel(account: account(), transport: transport)

        let request = ApprovalRequest(toolName: "run_shell", risk: .high,
                                      detail: "rm -rf ~/Documents/งานวิจัย")
        await channel.present(request)

        let sent = try #require(await transport.calls(to: "sendMessage").first)
        #expect(sent.string("chat_id") == "555")
        // Verbatim, not summarised: approving from a phone is still approving.
        #expect(sent.string("text")?.contains("rm -rf ~/Documents/งานวิจัย") == true)
        #expect(sent.string("text")?.contains("run_shell") == true)

        let keyboard = sent.body["reply_markup"] as? [String: Any]
        let rows = keyboard?["inline_keyboard"] as? [[[String: Any]]]
        let buttons = rows?.first ?? []
        #expect(buttons.count == 2)
        // Telegram caps callback_data at 64 bytes, which is why the verb is
        // two characters and the rest is the id.
        for button in buttons {
            let data = button["callback_data"] as? String ?? ""
            #expect(data.utf8.count <= 64)
            #expect(data.hasSuffix(request.id.rawValue))
        }
    }

    @Test("pressing approve submits the decision and stops the button spinning")
    func buttonPressIsAnApproval() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        let request = ApprovalRequest(toolName: "run_shell", risk: .high, detail: "ls")
        await transport.queue("getUpdates", """
        {"ok":true,"result":[{"update_id":7,"callback_query":{"id":"cb1","data":"ok:\(request.id.rawValue)",
          "message":{"message_id":42,"chat":{"id":555}}}}]}
        """)
        let answerer = Answerer()
        let channel = TelegramChannel(account: account(), transport: transport,
                                      answering: answerer, pollSeconds: 0)

        await channel.start(handler: Recorder())
        try await Task.sleep(for: .milliseconds(300))
        await channel.stop()

        let submitted = await answerer.submitted
        #expect(submitted.count == 1)
        #expect(submitted[0].0 == request.id)
        #expect(submitted[0].1 == .approved)
        // Telegram spins the button until this is answered.
        #expect(await !transport.calls(to: "answerCallbackQuery").isEmpty)
    }

    @Test("a button press from a chat that is not allowed decides nothing")
    func buttonPressRespectsTheAllowList() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        let request = ApprovalRequest(toolName: "run_shell", risk: .high, detail: "ls")
        await transport.queue("getUpdates", """
        {"ok":true,"result":[{"update_id":7,"callback_query":{"id":"cb1","data":"ok:\(request.id.rawValue)",
          "message":{"message_id":42,"chat":{"id":999}}}}]}
        """)
        let answerer = Answerer()
        let channel = TelegramChannel(account: account(allowing: ["555"]), transport: transport,
                                      answering: answerer, pollSeconds: 0)

        await channel.start(handler: Recorder())
        try await Task.sleep(for: .milliseconds(300))
        await channel.stop()

        #expect(await answerer.submitted.isEmpty)
    }

    /// First-response-wins is the broker's rule (§5.4); what this channel owes
    /// is to take its own prompt down when it loses, so nobody presses a button
    /// that no longer decides anything.
    @Test("when someone else answers first, the prompt here is edited away")
    func losingChannelRetractsItsPrompt() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        await transport.queue("sendMessage", #"{"ok":true,"result":{"message_id":42}}"#)
        let channel = TelegramChannel(account: account(), transport: transport)

        let request = ApprovalRequest(toolName: "run_shell", risk: .high, detail: "ls")
        await channel.present(request)
        await channel.approvalResolved(request.id, decision: .rejected(reason: "ตอบจากหน้าจอ"))

        let edits = await transport.calls(to: "editMessageText")
        #expect(edits.count == 1)
        #expect(edits[0].string("text")?.contains("ไม่อนุมัติ") == true)
        #expect((edits[0].body["message_id"] as? NSNumber)?.int64Value == 42)
        // Editing twice would mean the state was kept after it stopped being
        // true.
        await channel.approvalResolved(request.id, decision: .rejected(reason: "ซ้ำ"))
        #expect(await transport.calls(to: "editMessageText").count == 1)
    }

    @Test("a reply goes to the chat that asked, not to everyone")
    func repliesGoBackWhereTheyCameFrom() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        let channel = TelegramChannel(account: account(allowing: ["555", "556"]),
                                      transport: transport)

        await channel.bind(conversation: "conv-1", to: "556")
        await channel.send(AgentMessage(text: "เสร็จแล้วครับ", conversationID: "conv-1"))

        let sent = try #require(await transport.calls(to: "sendMessage").first)
        #expect(sent.string("chat_id") == "556")
    }

    @Test("a reply with nowhere to go is dropped rather than broadcast")
    func replyWithNoChatIsDropped() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        let channel = TelegramChannel(account: account(allowing: ["555", "556"]),
                                      transport: transport)
        await channel.send(AgentMessage(text: "ไม่รู้จะส่งไปไหน", conversationID: "conv-unknown"))
        #expect(await transport.calls(to: "sendMessage").isEmpty)
    }

    /// Telegram answers 200 with `ok: false` for real failures, so a status
    /// code is not a result.
    @Test("ok:false is an error, not an empty answer")
    func platformErrorsAreErrors() async throws {
        let transport = StubTransport(token: "123456:SECRET-TOKEN")
        await transport.queue("getUpdates",
                              #"{"ok":false,"description":"Unauthorized"}"#)
        let channel = TelegramChannel(account: account(), transport: transport, pollSeconds: 0)
        let recorder = Recorder()

        // The loop survives it and keeps polling rather than ending silently.
        await channel.start(handler: recorder)
        try await Task.sleep(for: .milliseconds(200))
        await channel.stop()
        #expect(await recorder.messages.isEmpty)
    }

    /// The token is in the URL path for every call Telegram takes, so anything
    /// logged about a failure would publish it.
    @Test("the token is scrubbed from anything that could be logged")
    func tokenIsRedacted() {
        let token = "123456:SECRET-TOKEN"
        let text = "request to https://api.telegram.org/bot\(token)/getUpdates failed"
        let safe = redacted(text, token: token)
        #expect(!safe.contains(token))
        #expect(safe.contains("••••"))
    }

    @Test("chat ids survive being large numbers")
    func largeChatIdsAreNotScientificNotation() {
        // A real supergroup id. Rendered through NSNumber's description this
        // would come out as -1.001234567891234e+12 and match nothing.
        #expect(TelegramChannel.identifier(NSNumber(value: Int64(-1001234567891234)))
                == "-1001234567891234")
    }
}
