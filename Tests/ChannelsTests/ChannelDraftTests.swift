import Testing
import Foundation
import AgentKit
@testable import Channels

// ─────────────────────────────────────────────────────────────
// The editor's rules (ARCHITECTURE §8.2).
//
// Most of these are about one field. The allow-list is the entire security
// model of a chat channel — the bot's username is public, the token is the only
// secret, and this list is §8.2's answer to "then who may talk to it" — so the
// way the text somebody typed becomes that list is worth more care than a form
// field usually gets.
// ─────────────────────────────────────────────────────────────

@Suite("Channel account draft")
struct ChannelAccountDraftTests {

    // The failure this parsing exists to prevent: `123, 456` splitting into
    // `"123"` and `" 456"`, `allows(chat:)` comparing exactly, and the second
    // person being silently ignored by a bot that looks configured.
    @Test("chat ids are split and trimmed however they were typed")
    func parsesChatIds() {
        var draft = ChannelAccountDraft()
        draft.allowedChatsText = "123, 456\n789  1011;1213"
        #expect(draft.allowedChats == ["123", "456", "789", "1011", "1213"])
    }

    // A phone keyboard set to Thai gives a different comma. The person cannot
    // see the difference, and the bot would ignore everybody after the first.
    @Test("the Thai and full-width commas separate too")
    func parsesOtherPunctuation() {
        var draft = ChannelAccountDraft()
        draft.allowedChatsText = "123，456、789"
        #expect(draft.allowedChats == ["123", "456", "789"])
    }

    @Test("a repeated id appears once, in the order it was first typed")
    func dropsDuplicates() {
        var draft = ChannelAccountDraft()
        draft.allowedChatsText = "456, 123, 456"
        #expect(draft.allowedChats == ["456", "123"])
    }

    @Test("an account with no name cannot be saved — nobody could find it again")
    func nameIsRequired() {
        var draft = ChannelAccountDraft(platform: .telegram, name: "",
                                        tokenVariable: "BOT_TOKEN")
        #expect(draft.canSave == false)
        draft.name = "บอทกลุ่มวิจัย"
        #expect(draft.canSave)
    }

    @Test("a remote bot must name where its token is kept")
    func tokenNameIsRequired() {
        let draft = ChannelAccountDraft(platform: .discord, name: "บอท", tokenVariable: "")
        #expect(draft.canSave == false)
        #expect(draft.problems.contains { $0.contains("Keychain") })
    }

    // Siri and Shortcuts have no remote sender: whoever can run a Shortcut here
    // can already open the app (§8.2's `isLocal`).
    @Test("the local channel needs neither a token nor an allow-list")
    func localNeedsNoToken() {
        let draft = ChannelAccountDraft(platform: .appIntents, name: "Siri")
        #expect(draft.canSave)
        #expect(draft.warnings.isEmpty)
    }

    // An empty allow-list is a valid thing to save half-way through typing.
    // What it must not be is silent: it means *nobody*, and the symptom is a
    // bot that runs and never answers.
    @Test("an empty allow-list warns without blocking the save")
    func emptyAllowListWarnsOnly() {
        let draft = ChannelAccountDraft(platform: .telegram, name: "บอท",
                                        tokenVariable: "BOT_TOKEN")
        #expect(draft.canSave)
        #expect(draft.warnings.contains { $0.contains("ไม่รับจากใครเลย") })
    }

    @Test("LINE is warned about its channel secret, which is not its access token")
    func lineNeedsSigningSecret() {
        var draft = ChannelAccountDraft(platform: .line, name: "บอท LINE",
                                        tokenVariable: "LINE_TOKEN",
                                        allowedChatsText: "U123")
        #expect(draft.warnings.contains { $0.contains("channel secret") })
        draft.signingSecretVariable = "LINE_SECRET"
        #expect(draft.warnings.isEmpty)
    }

    // The signing secret belongs to LINE alone. Carrying one on a Telegram
    // account would put a name in the file that nothing ever reads, and make
    // `blockers` ask for a secret that platform has no use for.
    @Test("a signing secret is only kept for LINE")
    func signingSecretIsLineOnly() {
        var draft = ChannelAccountDraft(platform: .telegram, name: "บอท",
                                        tokenVariable: "T", signingSecretVariable: "LEFTOVER")
        #expect(draft.account().signingSecretVariable == nil)
        draft.platform = .line
        #expect(draft.account().signingSecretVariable == "LEFTOVER")
    }

    @Test("editing keeps the id, so a save updates rather than adds a second bot")
    func editKeepsIdentity() {
        let original = ChannelAccount(platform: .telegram, name: "บอทเดิม",
                                      tokenVariable: "T", allowedChats: ["1"])
        var draft = ChannelAccountDraft(original)
        draft.name = "บอทที่เปลี่ยนชื่อ"

        let updated = draft.account(id: original.id)
        #expect(updated.id == original.id)
        #expect(updated.name == "บอทที่เปลี่ยนชื่อ")
        #expect(updated.allowedChats == ["1"])
    }

    @Test("a draft made from an account round-trips it")
    func roundTrips() {
        let original = ChannelAccount(platform: .line, name: "บอท", tokenVariable: "T",
                                      allowedChats: ["U1", "U2"],
                                      signingSecretVariable: "S", modelOverride: "qwen",
                                      scope: .project(ProjectID("pj")), isEnabled: false)
        let rebuilt = ChannelAccountDraft(original).account(id: original.id)
        #expect(rebuilt == original)
    }
}
