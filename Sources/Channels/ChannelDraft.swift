import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Turning what somebody typed into a `ChannelAccount` (ARCHITECTURE §8.2).
//
// P7.3/P7.4 built all four channels and `ChannelAccountStore` to keep them.
// Nothing in the app ever read that store — the engine held it and no view
// touched it — so the only way to configure a bot was to write the JSON by
// hand, and after P9.3 there was still nowhere to put the token. Found while
// auditing secrets; it is a P7 gap rather than a security one, which is why it
// is its own task.
//
// The part with rules in it is here rather than in the view, because the view
// target has no tests and the rules are about a list that decides who may run
// commands on this machine.
//
// **The allow-list is the whole security model of a chat channel.** A bot's
// username is public and guessable; the token is the only secret; and §8.2's
// answer to "then who may talk to it" is a list of chat ids. So the way this
// parsing fails matters more than it looks: an id typed as `123, 456` splits
// into `"123"` and `" 456"`, and `allows(chat:)` compares exactly. The second
// person is then silently ignored by a bot that looks configured, and the
// symptom is "it does not reply to me" with nothing anywhere saying why.
// ─────────────────────────────────────────────────────────────

public struct ChannelAccountDraft: Sendable, Equatable {
    public var platform: ChannelPlatform
    public var name: String
    public var tokenVariable: String
    /// As typed: separated by commas, spaces or newlines, in either script's
    /// punctuation. Kept as text so the field round-trips what a person wrote.
    public var allowedChatsText: String
    public var signingSecretVariable: String
    public var modelOverride: String
    public var scope: Scope
    public var isEnabled: Bool

    public init(platform: ChannelPlatform = .telegram,
                name: String = "",
                tokenVariable: String = "",
                allowedChatsText: String = "",
                signingSecretVariable: String = "",
                modelOverride: String = "",
                scope: Scope = .central,
                isEnabled: Bool = true) {
        self.platform = platform
        self.name = name
        self.tokenVariable = tokenVariable
        self.allowedChatsText = allowedChatsText
        self.signingSecretVariable = signingSecretVariable
        self.modelOverride = modelOverride
        self.scope = scope
        self.isEnabled = isEnabled
    }

    public init(_ account: ChannelAccount) {
        self.platform = account.platform
        self.name = account.name
        self.tokenVariable = account.tokenVariable
        self.allowedChatsText = account.allowedChats.joined(separator: ", ")
        self.signingSecretVariable = account.signingSecretVariable ?? ""
        self.modelOverride = account.modelOverride ?? ""
        self.scope = account.scope
        self.isEnabled = account.isEnabled
    }

    /// The chat ids, one per entry, with nothing left clinging to them.
    ///
    /// Splits on both scripts' punctuation and on whitespace, because a person
    /// pasting ids from a phone gets whichever comma their keyboard is in.
    /// Duplicates are dropped and order is kept — a list with the same id twice
    /// is a list somebody will read as two people.
    public var allowedChats: [String] {
        let separators = CharacterSet(charactersIn: ", \n\t;、，")
        var seen = Set<String>()
        return allowedChatsText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// What stops this from being saved. Empty means it can be.
    ///
    /// Deliberately shorter than `ChannelAccount.blockers`: *saving* an account
    /// that will not start is fine and often what a person is in the middle of
    /// doing. What must not be saved is one that could not be corrected later —
    /// an account with no name is a row nobody can find again.
    public var problems: [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("ตั้งชื่อให้บอทนี้ก่อน — ชื่อคือสิ่งที่ใช้หามันเจอในรายการ")
        }
        if !platform.isLocal, tokenVariable.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("ต้องตั้งชื่อที่ใช้เก็บโทเคน — ค่าโทเคนเก็บใน Keychain "
                         + "ส่วนไฟล์เก็บแค่ชื่อนี้")
        }
        return found
    }

    public var canSave: Bool { problems.isEmpty }

    /// What the person should know before this will actually run. Separate
    /// from `problems` because none of these stop a draft being kept.
    public var warnings: [String] {
        var found: [String] = []
        if !platform.isLocal, allowedChats.isEmpty {
            // §8.2's rule, said where somebody is about to make the mistake:
            // an empty list is *nobody*, and a bot that defaults to everybody
            // is one leaked token away from a stranger running commands here.
            found.append("ยังไม่มี chat id ที่อนุญาต — รายการว่างแปลว่า**ไม่รับจากใครเลย** "
                         + "บอทจะเปิดแต่ไม่ตอบใคร")
        }
        if platform == .line,
           signingSecretVariable.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("LINE ต้องมี channel secret ไว้ตรวจลายเซ็น webhook — "
                         + "คนละค่ากับ access token ที่ใช้ส่งข้อความ")
        }
        return found
    }

    /// The account, keeping `id` when this is an edit rather than a new one.
    public func account(id: String? = nil) -> ChannelAccount {
        let trimmed = { (text: String) -> String? in
            let value = text.trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return ChannelAccount(
            id: id ?? OpaqueID.make("ch"),
            platform: platform,
            name: name.trimmingCharacters(in: .whitespaces),
            tokenVariable: tokenVariable.trimmingCharacters(in: .whitespaces),
            allowedChats: allowedChats,
            signingSecretVariable: platform == .line ? trimmed(signingSecretVariable) : nil,
            modelOverride: trimmed(modelOverride),
            scope: scope,
            isEnabled: isEnabled)
    }
}
