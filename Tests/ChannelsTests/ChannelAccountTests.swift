import Testing
import Foundation
import AgentKit
@testable import Channels

// ─────────────────────────────────────────────────────────────
// Accounts and the allow-list (ARCHITECTURE §8.2, P7.3).
// ─────────────────────────────────────────────────────────────

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "coai-channels-\(UUID().uuidString)/accounts.json")
}

@Suite("Channel accounts")
struct ChannelAccountTests {

    /// §8.2: several bots per platform, each with its own chats.
    @Test("several accounts can exist on one platform, each with its own allow-list")
    func multipleAccountsPerPlatform() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ChannelAccountStore(file: file)

        try store.add(ChannelAccount(platform: .telegram, name: "บอทงานวิจัย",
                                     tokenVariable: "RESEARCH_BOT", allowedChats: ["111"]))
        try store.add(ChannelAccount(platform: .telegram, name: "บอทส่วนตัว",
                                     tokenVariable: "PERSONAL_BOT", allowedChats: ["222", "333"]))
        try store.add(ChannelAccount(platform: .discord, name: "เซิร์ฟเวอร์ทีม",
                                     tokenVariable: "DISCORD_BOT", allowedChats: ["444"]))

        #expect(store.load().count == 3)
        #expect(store.load(platform: .telegram).map(\.name) == ["บอทงานวิจัย", "บอทส่วนตัว"])
        // Each account's list is its own: a chat allowed on one bot is not
        // allowed on the other.
        let research = store.load(platform: .telegram)[0]
        #expect(research.allows(chat: "111"))
        #expect(!research.allows(chat: "222"))
    }

    /// The token is the only secret a bot has, so the file must not hold it.
    @Test("the bot token is not what gets written to disk")
    func tokensAreNotStored() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        SecretStore.override("COAI_TEST_BOT_TOKEN", "123456:SECRET-TOKEN")
        defer { SecretStore.override("COAI_TEST_BOT_TOKEN", nil) }

        let store = ChannelAccountStore(file: file)
        try store.add(ChannelAccount(platform: .telegram, name: "บอท",
                                     tokenVariable: "COAI_TEST_BOT_TOKEN",
                                     allowedChats: ["111"]))

        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("COAI_TEST_BOT_TOKEN"))
        #expect(!written.contains("SECRET-TOKEN"))
        // And it is still readable at the moment it is needed.
        #expect(store.load()[0].token == "123456:SECRET-TOKEN")
        #expect(store.load()[0].isReady)
    }

    /// The default that matters. A bot's username is public; if an empty
    /// allow-list meant "everyone", one leaked token would be a stranger with
    /// a shell.
    @Test("an empty allow-list means nobody, not everybody")
    func emptyListIsClosed() {
        let account = ChannelAccount(platform: .telegram, name: "ใหม่",
                                     tokenVariable: "ANY", allowedChats: [])
        #expect(!account.allows(chat: "111"))
        #expect(!account.allows(chat: ""))
        #expect(!account.isReady)
    }

    @Test("an account survives being saved and updated in place")
    func accountsPersist() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ChannelAccountStore(file: file)

        var account = ChannelAccount(platform: .line, name: "LINE ทีม",
                                     tokenVariable: "LINE_TOKEN", allowedChats: ["u1"],
                                     modelOverride: "qwen3.5-9b",
                                     scope: .project(ProjectID("diabetes")))
        try store.add(account)
        account.allowedChats.append("u2")
        try store.add(account)

        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].allowedChats == ["u1", "u2"])
        #expect(loaded[0].modelOverride == "qwen3.5-9b")
        #expect(loaded[0].scope == .project(ProjectID("diabetes")))

        try store.remove(account.id)
        #expect(store.load().isEmpty)
    }

    @Test("a corrupt account file is an empty list, not a crash at boot")
    func corruptFileIsSurvivable() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)

        #expect(ChannelAccountStore(file: file).load().isEmpty)
    }

    @Test("a disabled account is not ready even when everything else is set")
    func disabledAccountsDoNotRun() {
        SecretStore.override("COAI_TEST_BOT_TOKEN", "x")
        defer { SecretStore.override("COAI_TEST_BOT_TOKEN", nil) }
        let account = ChannelAccount(platform: .telegram, name: "ปิดไว้",
                                     tokenVariable: "COAI_TEST_BOT_TOKEN",
                                     allowedChats: ["111"], isEnabled: false)
        #expect(!account.isReady)
        #expect(account.blockers == ["ปิดอยู่"])
    }
}
