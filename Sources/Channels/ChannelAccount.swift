import Foundation
import os
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// M4 Channels — who may talk to this workspace (ARCHITECTURE §8, P7.3/P7.4).
//
// The single most important fact about this module is what it *cannot* reach.
// It depends on AgentKit, Config and Observability, and on nothing else — no
// ToolBelt, no CoreEngine, no gateway. A channel therefore has no way to invoke
// a tool even if it wanted to: the types are not in scope. v1's bug B2 was a
// Telegram bridge that ran tools without going through the hook chain, and the
// fix is not a rule anybody has to remember but a line in Package.swift that
// `scripts/check.sh` will not let anyone quietly change.
//
// What a channel may do with an inbound message is hand it to something that
// conforms to `InboundHandling`, which is implemented in the app where the
// engine lives. One method, one direction, no return value that could carry a
// tool result back around the side.
// ─────────────────────────────────────────────────────────────

public enum ChannelPlatform: String, Sendable, Codable, CaseIterable, Identifiable {
    case telegram
    case discord
    case line
    /// Siri, Shortcuts and Spotlight (§14.3). A channel like the others — it
    /// goes through the same core — but see `isLocal`: it is the only one
    /// whose sender is already the owner of this machine.
    case appIntents

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .telegram: "Telegram"
        case .discord: "Discord"
        case .line: "LINE"
        case .appIntents: "Siri / Shortcuts"
        }
    }

    /// Whether the sender is on this Mac.
    ///
    /// This is the *only* thing that may excuse a channel from the token and
    /// the allow-list, and it is worth being precise about why. The allow-list
    /// exists because a bot's id is public and its token is the single secret
    /// standing between a stranger and `run_shell` (§8.2). An intent has no
    /// remote sender at all: it is dispatched by macOS to this app, on behalf
    /// of whoever is logged in, and someone who can run Shortcuts here can
    /// already open the app. There is nothing an allow-list of chat ids would
    /// be listing.
    public var isLocal: Bool { self == .appIntents }
}

/// One bot on one platform. §8.2 asks for several per platform, so this is a
/// value with an id rather than a singleton per platform.
public struct ChannelAccount: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var platform: ChannelPlatform
    /// What a person calls it — "บอทกลุ่มวิจัย", not a token prefix.
    public var name: String
    /// The environment variable the bot token is read from. The token itself is
    /// never written down, the same shape §9.3's endpoints and §12.2's
    /// connectors settled on.
    public var tokenVariable: String
    /// Chat ids allowed to talk to this bot. **Empty means nobody**, not
    /// everybody: a bot's id is guessable and its token is the only secret, so
    /// an empty list defaulting to open is one leaked token away from a stranger
    /// running commands on this machine.
    public var allowedChats: [String]
    /// LINE only: the variable holding the *channel secret*, which is what its
    /// webhook signature is computed under. A second name rather than a second
    /// meaning for the first: the access token sends messages, the channel
    /// secret proves an inbound one is real, and mixing them up fails in a way
    /// that looks like LINE being broken.
    public var signingSecretVariable: String?
    /// §8.2: a channel may pin its own model. Nil follows the router.
    public var modelOverride: String?
    public var scope: Scope
    public var isEnabled: Bool

    public init(id: String = OpaqueID.make("ch"),
                platform: ChannelPlatform,
                name: String,
                tokenVariable: String,
                allowedChats: [String] = [],
                signingSecretVariable: String? = nil,
                modelOverride: String? = nil,
                scope: Scope = .central,
                isEnabled: Bool = true) {
        self.id = id
        self.platform = platform
        self.name = name
        self.tokenVariable = tokenVariable
        self.allowedChats = allowedChats
        self.signingSecretVariable = signingSecretVariable
        self.modelOverride = modelOverride
        self.scope = scope
        self.isEnabled = isEnabled
    }

    /// The token, read at the moment it is needed. Nil when the variable is
    /// unset — reported as a state the screen can show rather than as a crash
    /// at the first poll.
    public var token: String? { SecretStore.value(tokenVariable) }

    public var isReady: Bool {
        guard isEnabled else { return false }
        // Written as one condition rather than two so a future platform cannot
        // become ready by having neither: `isLocal` is an exemption from the
        // token *and* the allow-list together, and only for a sender that is
        // already on this machine.
        return platform.isLocal || (token != nil && !allowedChats.isEmpty)
    }

    /// Why this account is not running, in the words the screen shows.
    public var blockers: [String] {
        var reasons: [String] = []
        if !isEnabled { reasons.append("ปิดอยู่") }
        if platform.isLocal { return reasons }
        if token == nil { reasons.append("ยังไม่ได้ตั้งตัวแปร \(tokenVariable) ที่เก็บโทเคน") }
        if allowedChats.isEmpty {
            reasons.append("ยังไม่มี chat id ที่อนุญาต — รายการว่างแปลว่าไม่รับจากใครเลย")
        }
        if platform == .line, signingSecretVariable.map({ !SecretStore.has($0) }) ?? true {
            reasons.append("LINE ต้องมีตัวแปรที่เก็บ channel secret สำหรับตรวจลายเซ็น webhook")
        }
        return reasons
    }

    /// The allow-list, applied. §8.2's rule, and the only thing standing
    /// between a leaked bot username and a stranger's `run_shell`.
    public func allows(chat: String) -> Bool {
        allowedChats.contains(chat)
    }
}

/// One inbound message, already stripped of anything platform-specific.
public struct IncomingMessage: Sendable, Equatable {
    public let account: String
    public let platform: ChannelPlatform
    /// The chat this came from, used for replying and for the allow-list.
    public let chat: String
    /// Who sent it, for the record. Never used to authorise anything — the
    /// chat id is what the allow-list checks.
    public let sender: String
    public let text: String
    public let scope: Scope

    public init(account: String, platform: ChannelPlatform, chat: String,
                sender: String, text: String, scope: Scope = .central) {
        self.account = account
        self.platform = platform
        self.chat = chat
        self.sender = sender
        self.text = text
        self.scope = scope
    }
}

/// The only thing a channel may do with what it receives.
///
/// Deliberately one method with no useful return: a channel hands work to the
/// core and is told nothing it could act on by itself. Everything that decides
/// anything — routing, the hook chain, approval — is on the other side of this
/// call, in a module this one cannot import.
public protocol InboundHandling: Sendable {
    func handle(_ message: IncomingMessage) async
}

/// A running channel. Started and stopped by the app, never by itself.
public protocol RunnableChannel: Channel {
    func start(handler: any InboundHandling) async
    func stop() async
    /// Remembers which chat a conversation belongs to, so a reply goes back
    /// where the question came from rather than to everyone on the allow-list.
    func bind(conversation: String, to chat: String) async
}

// ─────────────────────────────────────────────────────────────
// Where accounts are kept. A file, for the same reasons as the connectors: it
// is read before anything connects, and a person should be able to open it and
// see that their bot token is not in it.
// ─────────────────────────────────────────────────────────────

public struct ChannelAccountStore: Sendable {
    public let file: URL
    private let log = AppLog.logger("channels")

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [ChannelAccount] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let accounts = try? JSONDecoder().decode([ChannelAccount].self, from: data) else {
            reportUnreadable(file, kind: "channel account", log: log)
            return []
        }
        return accounts
    }

    public func load(platform: ChannelPlatform) -> [ChannelAccount] {
        load().filter { $0.platform == platform }
    }

    public func save(_ accounts: [ChannelAccount]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: file, options: .atomic)
    }

    @discardableResult
    public func add(_ account: ChannelAccount) throws -> [ChannelAccount] {
        var all = load()
        if let index = all.firstIndex(where: { $0.id == account.id }) {
            all[index] = account
        } else {
            all.append(account)
        }
        try save(all)
        return all
    }

    @discardableResult
    public func remove(_ id: String) throws -> [ChannelAccount] {
        let all = load().filter { $0.id != id }
        try save(all)
        return all
    }
}

/// A list file that will not decode. The copy is taken here, before anything
/// can save over it — see `FileStoreSafety`.
private func reportUnreadable(_ file: URL, kind: String, log: Logger) {
    let backup = FileStoreSafety.preserveUnreadable(file)
    if let backup {
        log.error("""
            \(kind, privacy: .public) file unreadable — kept a copy at \(backup.lastPathComponent, privacy: .public)             and starting from an empty list
            """)
    } else {
        log.error("\(kind, privacy: .public) file unreadable — starting from an empty list")
    }
}
