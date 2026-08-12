import Testing
import Foundation
import AgentKit
@testable import Channels

// ─────────────────────────────────────────────────────────────
// Siri and Shortcuts (ARCHITECTURE §8.1, §14.3, P7.5).
//
// The Done-when is "งานสั่งจาก Shortcuts ได้", and the thing that makes that
// true or false is not the intent struct — it is whether an intent goes down
// the same road as a Telegram message and whether the caller waiting on the
// other end is told something useful. So these tests stand where the app's
// router stands: they receive the `IncomingMessage`, reply the way the router
// replies, and check what the caller heard.
// ─────────────────────────────────────────────────────────────

/// Stands in for `ChannelRouter`: creates a conversation, binds it to the
/// request, and answers. The same three steps, in the same order.
private actor FakeRouter: InboundHandling {
    private let channel: AppIntentsChannel
    private let reply: String?
    private let raiseApproval: ApprovalRequest?
    private(set) var received: [IncomingMessage] = []

    init(channel: AppIntentsChannel, reply: String?,
         raiseApproval: ApprovalRequest? = nil) {
        self.channel = channel
        self.reply = reply
        self.raiseApproval = raiseApproval
    }

    func handle(_ message: IncomingMessage) async {
        received.append(message)
        let conversation = "conv:\(message.chat)"
        await channel.bind(conversation: conversation, to: message.chat)
        if let raiseApproval {
            await channel.present(raiseApproval)
        }
        guard let reply else { return }   // a turn that never answers
        await channel.send(AgentMessage(text: reply, conversationID: conversation))
    }
}

@Suite("App Intents channel")
struct AppIntentsChannelTests {

    /// The Done-when, at the level this module can prove it: a question asked
    /// the way Shortcuts asks it goes out as an ordinary inbound message and
    /// the answer comes back to the caller.
    @Test("a question from Shortcuts runs through the normal inbound path and answers")
    func askAnswers() async {
        let channel = AppIntentsChannel()
        let router = FakeRouter(channel: channel, reply: "มี 3 งานที่ยังไม่เสร็จ")
        await channel.start(handler: router)

        let answer = await channel.ask("สรุปความคืบหน้าโปรเจกต์ A")
        #expect(answer == .answered("มี 3 งานที่ยังไม่เสร็จ"))

        // Not a private path: what the handler saw is the same shape a bot's
        // message would have been.
        let seen = await router.received
        #expect(seen.count == 1)
        #expect(seen.first?.platform == .appIntents)
        #expect(seen.first?.account == AppIntentsChannel.accountID)
        #expect(seen.first?.text == "สรุปความคืบหน้าโปรเจกต์ A")
    }

    /// §8.1: Siri is the wrong place to approve something you are meant to
    /// read first. What the caller must not get is silence followed by "took
    /// too long" — the decision is sitting in the app, and saying so is the
    /// difference between a Shortcut somebody keeps and one they delete.
    @Test("an approval raised mid-turn sends the caller to the app, not to a timeout")
    func approvalIsHandedToTheGUI() async {
        let channel = AppIntentsChannel()
        let router = FakeRouter(channel: channel, reply: nil,
                                raiseApproval: ApprovalRequest(toolName: "run_shell",
                                                               risk: .high,
                                                               detail: "rm -rf build/"))
        await channel.start(handler: router)

        let answer = await channel.ask("ลบโฟลเดอร์ build", timeout: .milliseconds(300))
        #expect(answer == .needsApproval(tool: "run_shell"))
        #expect(answer.spoken.contains("run_shell"))
    }

    @Test("a turn that never answers times out rather than hanging Shortcuts")
    func silenceTimesOut() async {
        let channel = AppIntentsChannel()
        await channel.start(handler: FakeRouter(channel: channel, reply: nil))

        let answer = await channel.ask("อะไรก็ได้", timeout: .milliseconds(200))
        #expect(answer == .timedOut)
    }

    /// An intent fired at login, before the database has answered, is the
    /// ordinary case rather than an edge one.
    @Test("asking before the workspace has started says so instead of hanging")
    func notStartedIsAnAnswer() async {
        let answer = await AppIntentsChannel().ask("ถามอะไรสักอย่าง", timeout: .seconds(5))
        #expect(answer == .notRunning)
    }

    @Test("progress messages do not answer the caller")
    func progressIsNotAnAnswer() async {
        let channel = AppIntentsChannel()
        let router = ProgressThenReply(channel: channel)
        await channel.start(handler: router)

        let answer = await channel.ask("ถาม", timeout: .seconds(2))
        #expect(answer == .answered("คำตอบจริง"))
    }

    /// Two Shortcuts running at once get their own answers. The router keys
    /// replies by conversation, and a channel that kept one waiter would give
    /// the second caller the first one's answer.
    @Test("two questions at once do not get each other's answers")
    func concurrentAsksStaySeparate() async {
        let channel = AppIntentsChannel()
        await channel.start(handler: EchoRouter(channel: channel))

        async let first = channel.ask("หนึ่ง", timeout: .seconds(2))
        async let second = channel.ask("สอง", timeout: .seconds(2))
        let answers = await [first, second]

        #expect(answers.contains(.answered("ตอบ: หนึ่ง")))
        #expect(answers.contains(.answered("ตอบ: สอง")))
    }

    /// The exemption in `ChannelPlatform.isLocal` is a hole in the rule that
    /// protects `run_shell` from a stranger, so it is checked here rather than
    /// trusted: it applies to Siri and to nothing else.
    @Test("only the local platform is exempt from the token and the allow-list")
    func onlyAppIntentsSkipsTheAllowList() {
        let siri = ChannelAccount(platform: .appIntents, name: "Siri", tokenVariable: "")
        #expect(siri.isReady)
        #expect(siri.blockers.isEmpty)

        for platform in ChannelPlatform.allCases where !platform.isLocal {
            let account = ChannelAccount(platform: platform, name: "bot",
                                         tokenVariable: "COAI_TEST_UNSET", allowedChats: [])
            #expect(!account.isReady, "\(platform) ต้องไม่พร้อมเมื่อไม่มีโทเคนและ allow-list")
        }
    }

    @Test("stopping the channel releases anyone waiting")
    func stopReleasesWaiters() async {
        let channel = AppIntentsChannel()
        await channel.start(handler: FakeRouter(channel: channel, reply: nil))

        async let answer = channel.ask("ค้างไว้", timeout: .seconds(30))
        try? await Task.sleep(for: .milliseconds(100))
        await channel.stop()
        #expect(await answer == .notRunning)
    }
}

/// Sends progress first, then the real answer.
private actor ProgressThenReply: InboundHandling {
    private let channel: AppIntentsChannel
    init(channel: AppIntentsChannel) { self.channel = channel }

    func handle(_ message: IncomingMessage) async {
        let conversation = "conv:\(message.chat)"
        await channel.bind(conversation: conversation, to: message.chat)
        await channel.send(AgentMessage(kind: .progress, text: "กำลังทำ",
                                        conversationID: conversation))
        await channel.send(AgentMessage(text: "คำตอบจริง", conversationID: conversation))
    }
}

private actor EchoRouter: InboundHandling {
    private let channel: AppIntentsChannel
    init(channel: AppIntentsChannel) { self.channel = channel }

    func handle(_ message: IncomingMessage) async {
        let conversation = "conv:\(message.chat)"
        await channel.bind(conversation: conversation, to: message.chat)
        await channel.send(AgentMessage(text: "ตอบ: \(message.text)",
                                        conversationID: conversation))
    }
}
