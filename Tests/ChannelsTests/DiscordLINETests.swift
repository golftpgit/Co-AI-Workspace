import Testing
import Foundation
import CryptoKit
import AgentKit
@testable import Channels

// ─────────────────────────────────────────────────────────────
// Discord and LINE (ARCHITECTURE §8.1, P7.2).
//
// Both are driven here without a token: Discord's gateway through an injected
// socket, LINE's webhook by handing it the bytes a delivery would have carried.
// The security-critical halves — the signature and the two allow-lists — are
// checked against forgeries rather than against the happy path, because that is
// what they exist for.
// ─────────────────────────────────────────────────────────────

private actor FakeSocket: GatewaySocket {
    private(set) var sent: [String] = []
    private var inbox: [String]
    private var connected = false

    init(frames: [String] = []) { self.inbox = frames }

    func connect(to url: URL) async throws { connected = true }
    func send(_ text: String) async throws { sent.append(text) }

    func receive() async throws -> String? {
        guard !inbox.isEmpty else {
            // Nothing left: behave like a socket that closed, so the read loop
            // ends instead of spinning.
            return nil
        }
        return inbox.removeFirst()
    }

    func close() { connected = false }

    /// Returned as bytes, not as a dictionary: `[String: Any]` is not
    /// `Sendable` and cannot leave an actor (App. C).
    func frame(at index: Int) -> Data {
        guard index < sent.count else { return Data() }
        return Data(sent[index].utf8)
    }
}

private func decoded(_ data: Data) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
}

private actor Sink: InboundHandling {
    private(set) var messages: [IncomingMessage] = []
    func handle(_ message: IncomingMessage) async { messages.append(message) }
}

private actor Answers: ApprovalAnswering {
    private(set) var submitted: [(ApprovalRequest.ID, ApprovalDecision)] = []
    func submit(_ id: ApprovalRequest.ID, decision: ApprovalDecision,
                from channel: ChannelID?) async -> Bool {
        submitted.append((id, decision))
        return true
    }
}

private func discordAccount(allowing channels: [String] = ["C1"]) -> ChannelAccount {
    SecretStore.override("COAI_TEST_DISCORD", "discord-secret-token")
    return ChannelAccount(id: "d1", platform: .discord, name: "บอททีม",
                          tokenVariable: "COAI_TEST_DISCORD", allowedChats: channels)
}

@Suite("Discord gateway", .serialized)
struct DiscordChannelTests {

    /// §8.1's handshake: Hello carries the interval, Identify answers it.
    @Test("hello is answered with identify, asking for the intents it needs")
    func handshake() async throws {
        let socket = FakeSocket(frames: [#"{"op":10,"d":{"heartbeat_interval":41250}}"#])
        let channel = DiscordChannel(account: discordAccount(), socket: socket)
        await channel.start(handler: Sink())
        try await Task.sleep(for: .milliseconds(200))
        await channel.stop()

        let identify = decoded(await socket.frame(at: 0))
        #expect((identify["op"] as? NSNumber)?.intValue == 2)
        let data = identify["d"] as? [String: Any]
        #expect(data?["token"] as? String == "discord-secret-token")
        // MESSAGE_CONTENT (1<<15) is what makes `content` non-empty; without it
        // every message arrives looking like an empty prompt.
        let intents = (data?["intents"] as? NSNumber)?.intValue ?? 0
        #expect(intents & (1 << 15) != 0)
        #expect(intents & (1 << 9) != 0)
    }

    @Test("a message in an allowed channel reaches the core")
    func messageIsDelivered() async throws {
        let socket = FakeSocket(frames: [
            #"{"op":10,"d":{"heartbeat_interval":41250}}"#,
            #"{"op":0,"s":1,"t":"READY","d":{"user":{"id":"BOT"}}}"#,
            #"{"op":0,"s":2,"t":"MESSAGE_CREATE","d":{"channel_id":"C1","content":"สรุปให้หน่อย","author":{"id":"U1","username":"golf"}}}"#,
        ])
        let sink = Sink()
        let channel = DiscordChannel(account: discordAccount(), socket: socket)
        await channel.start(handler: sink)
        try await Task.sleep(for: .milliseconds(300))
        await channel.stop()

        let messages = await sink.messages
        #expect(messages.count == 1)
        #expect(messages[0].text == "สรุปให้หน่อย")
        #expect(messages[0].platform == .discord)
        #expect(messages[0].chat == "C1")
    }

    /// Without this the bot's own reply becomes the next prompt and it talks to
    /// itself — on a system that can run shell commands.
    @Test("the bot does not answer itself")
    func selfMessagesAreIgnored() async throws {
        let socket = FakeSocket(frames: [
            #"{"op":10,"d":{"heartbeat_interval":41250}}"#,
            #"{"op":0,"s":1,"t":"READY","d":{"user":{"id":"BOT"}}}"#,
            #"{"op":0,"s":2,"t":"MESSAGE_CREATE","d":{"channel_id":"C1","content":"คำตอบของบอทเอง","author":{"id":"BOT","username":"co-ai"}}}"#,
            #"{"op":0,"s":3,"t":"MESSAGE_CREATE","d":{"channel_id":"C1","content":"จากบอทอื่น","author":{"id":"X","bot":true}}}"#,
        ])
        let sink = Sink()
        let channel = DiscordChannel(account: discordAccount(), socket: socket)
        await channel.start(handler: sink)
        try await Task.sleep(for: .milliseconds(300))
        await channel.stop()

        #expect(await sink.messages.isEmpty)
    }

    @Test("a message from a channel that is not allowed gets nowhere")
    func allowListIsEnforced() async throws {
        let socket = FakeSocket(frames: [
            #"{"op":10,"d":{"heartbeat_interval":41250}}"#,
            #"{"op":0,"s":1,"t":"MESSAGE_CREATE","d":{"channel_id":"C999","content":"rm -rf /","author":{"id":"U9"}}}"#,
        ])
        let sink = Sink()
        let channel = DiscordChannel(account: discordAccount(allowing: ["C1"]), socket: socket)
        await channel.start(handler: sink)
        try await Task.sleep(for: .milliseconds(300))
        await channel.stop()

        #expect(await sink.messages.isEmpty)
    }

    @Test("a button press is submitted as a decision")
    func buttonPress() async throws {
        let request = ApprovalRequest(toolName: "run_shell", risk: .high, detail: "ls")
        let socket = FakeSocket(frames: [
            #"{"op":10,"d":{"heartbeat_interval":41250}}"#,
            """
            {"op":0,"s":1,"t":"INTERACTION_CREATE","d":{"id":"I1","token":"tok","channel_id":"C1",
             "data":{"custom_id":"ok:\(request.id.rawValue)"}}}
            """,
        ])
        let answers = Answers()
        let channel = DiscordChannel(account: discordAccount(), socket: socket,
                                     answering: answers)
        await channel.start(handler: Sink())
        try await Task.sleep(for: .milliseconds(300))
        await channel.stop()

        let submitted = await answers.submitted
        #expect(submitted.count == 1)
        #expect(submitted[0].0 == request.id)
        #expect(submitted[0].1 == .approved)
    }

    /// Discord asks for a heartbeat with op 1 and expects the last sequence
    /// number echoed back.
    @Test("an immediate heartbeat request is answered with the current sequence")
    func heartbeatOnDemand() async throws {
        let socket = FakeSocket(frames: [
            #"{"op":10,"d":{"heartbeat_interval":41250}}"#,
            #"{"op":0,"s":7,"t":"TYPING_START","d":{}}"#,
            #"{"op":1,"d":null}"#,
        ])
        let channel = DiscordChannel(account: discordAccount(), socket: socket)
        await channel.start(handler: Sink())
        try await Task.sleep(for: .milliseconds(300))
        await channel.stop()

        let beat = decoded(await socket.frame(at: 1))
        #expect((beat["op"] as? NSNumber)?.intValue == 1)
        #expect((beat["d"] as? NSNumber)?.intValue == 7)
    }
}

// ─────────────────────────────────────────────────────────────

private func lineAccount(allowing sources: [String] = ["U-abc"]) -> ChannelAccount {
    SecretStore.override("COAI_TEST_LINE_TOKEN", "line-access-token")
    SecretStore.override("COAI_TEST_LINE_SECRET", "line-channel-secret")
    return ChannelAccount(id: "l1", platform: .line, name: "LINE ทีม",
                          tokenVariable: "COAI_TEST_LINE_TOKEN", allowedChats: sources)
}

private func signed(_ body: String, secret: String = "line-channel-secret") -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    return Data(HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key))
        .base64EncodedString()
}

private func textEvent(from source: String, _ text: String) -> String {
    """
    {"events":[{"type":"message","source":{"type":"user","userId":"\(source)"},
      "message":{"type":"text","text":"\(text)"}}]}
    """
}

@Suite("LINE webhook", .serialized)
struct LINEChannelTests {

    private func channel(allowing sources: [String] = ["U-abc"],
                         answering: (any ApprovalAnswering)? = nil) -> LINEChannel {
        LINEChannel(account: lineAccount(allowing: sources),
                    secretVariable: "COAI_TEST_LINE_SECRET",
                    answering: answering)
    }

    @Test("a correctly signed message reaches the core")
    func signedDeliveryIsAccepted() async throws {
        let sink = Sink()
        let line = channel()
        await line.start(handler: sink)
        defer { Task { await line.stop() } }

        let body = textEvent(from: "U-abc", "ช่วยสรุปให้หน่อย")
        let status = await line.handle(body: Data(body.utf8), signature: signed(body))
        #expect(status == 200)

        let messages = await sink.messages
        #expect(messages.count == 1)
        #expect(messages[0].text == "ช่วยสรุปให้หน่อย")
        #expect(messages[0].platform == .line)
    }

    /// The whole reason the signature exists: anyone who learns the URL can
    /// post to it.
    @Test("a forged delivery is rejected and reaches nothing")
    func forgedDeliveryIsRejected() async throws {
        let sink = Sink()
        let line = channel()
        await line.start(handler: sink)
        defer { Task { await line.stop() } }

        let body = textEvent(from: "U-abc", "rm -rf /")
        let status = await line.handle(body: Data(body.utf8),
                                       signature: signed(body, secret: "wrong-secret"))
        #expect(status == 401)
        #expect(await sink.messages.isEmpty)

        // And a delivery with no signature at all.
        #expect(await line.handle(body: Data(body.utf8), signature: nil) == 401)
        #expect(await sink.messages.isEmpty)
    }

    /// The digest is over the exact bytes LINE sent. Re-encoding the parsed
    /// JSON and hashing that gives a different digest for the same message.
    @Test("the signature is over the raw body, not over a re-encoding of it")
    func signatureIsOverRawBytes() {
        let body = #"{"events":[{"type":"message","source":{"userId":"U-abc"}}]}"#
        let reserialised = #"{ "events" : [ { "type" : "message" } ] }"#
        #expect(LINEChannel.verify(body: Data(body.utf8),
                                   signature: signed(body), secret: "line-channel-secret"))
        #expect(!LINEChannel.verify(body: Data(reserialised.utf8),
                                    signature: signed(body), secret: "line-channel-secret"))
    }

    @Test("a signed message from a source that is not on the allow-list still gets nowhere")
    func allowListAppliesAfterTheSignature() async throws {
        let sink = Sink()
        let line = channel(allowing: ["U-abc"])
        await line.start(handler: sink)
        defer { Task { await line.stop() } }

        let body = textEvent(from: "U-stranger", "สวัสดี")
        // Correctly signed — the secret is not what decides who may talk.
        let status = await line.handle(body: Data(body.utf8), signature: signed(body))
        #expect(status == 200)
        #expect(await sink.messages.isEmpty)
    }

    @Test("a postback from a quick reply is submitted as a decision")
    func postbackIsAnApproval() async throws {
        let request = ApprovalRequest(toolName: "run_shell", risk: .high, detail: "ls")
        let answers = Answers()
        let line = channel(answering: answers)
        await line.start(handler: Sink())
        defer { Task { await line.stop() } }

        let body = """
        {"events":[{"type":"postback","source":{"type":"user","userId":"U-abc"},
          "postback":{"data":"no:\(request.id.rawValue)"}}]}
        """
        #expect(await line.handle(body: Data(body.utf8), signature: signed(body)) == 200)

        let submitted = await answers.submitted
        #expect(submitted.count == 1)
        #expect(submitted[0].0 == request.id)
        if case .rejected = submitted[0].1 {} else { Issue.record("expected a rejection") }
    }

    @Test("events that are not text messages are ignored without complaint")
    func nonTextEventsAreIgnored() async throws {
        let sink = Sink()
        let line = channel()
        await line.start(handler: sink)
        defer { Task { await line.stop() } }

        let body = """
        {"events":[{"type":"message","source":{"userId":"U-abc"},
          "message":{"type":"sticker","packageId":"1"}},
         {"type":"follow","source":{"userId":"U-abc"}}]}
        """
        #expect(await line.handle(body: Data(body.utf8), signature: signed(body)) == 200)
        #expect(await sink.messages.isEmpty)
    }

    @Test("a group source is matched by its group id")
    func groupSourcesWork() async throws {
        let sink = Sink()
        let line = channel(allowing: ["G-team"])
        await line.start(handler: sink)
        defer { Task { await line.stop() } }

        let body = """
        {"events":[{"type":"message","source":{"type":"group","groupId":"G-team"},
          "message":{"type":"text","text":"ทีมถามมา"}}]}
        """
        #expect(await line.handle(body: Data(body.utf8), signature: signed(body)) == 200)
        #expect(await sink.messages.first?.chat == "G-team")
    }
}
