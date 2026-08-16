import Testing
import Foundation
import AgentKit
@testable import Channels

// ─────────────────────────────────────────────────────────────
// Asking whether a channel is configured must not read the token.
//
// Found by driving the app after a rebuild: it sat on "กำลังเริ่มระบบ…" at 0%
// CPU forever, and the sample said why —
//
//   Engine.build → ChannelAccount.isReady → .token → SecretStore.value
//     → KeychainVault.read → SecItemCopyMatching   (blocked, main thread)
//
// `SecItemCopyMatching` with `kSecReturnData` asks the Keychain for the *bytes*,
// and returning bytes is what the item's access control guards. A rebuilt app
// is a different binary to that ACL, so macOS wants a person to approve the
// read — and until somebody does, the call does not return. The boot path was
// making that call on the main thread, so the whole app waited, with a spinner
// that could not say what for.
//
// The comment two lines above the call already knew the rule: *"a channel that
// cannot run must not stop the app from starting."* It was defeated by how the
// question was asked, not by what it decided — **`isReady` needs to know a
// token exists, and was reading its value to find out.**
//
// Asking for attributes instead of data answers exactly the question being
// asked and is not ACL-guarded, so it cannot prompt and cannot block. The token
// is still read later, by the channel that is about to send with it, off the
// boot path and off the main thread.
// ─────────────────────────────────────────────────────────────

/// Records which kind of question was asked. Presence and value are separate
/// calls precisely so this distinction can be tested.
final class SpyVault: SecretVault, @unchecked Sendable {
    private let stored: [String: String]
    private let lock = NSLock()
    private var _valueReads: [String] = []
    private var _existenceChecks: [String] = []

    var valueReads: [String] { lock.withLock { _valueReads } }
    var existenceChecks: [String] { lock.withLock { _existenceChecks } }

    init(_ stored: [String: String]) { self.stored = stored }

    func read(_ name: String) throws -> String? {
        lock.withLock { _valueReads.append(name) }
        return stored[name]
    }

    func exists(_ name: String) throws -> Bool {
        lock.withLock { _existenceChecks.append(name) }
        return stored[name] != nil
    }

    func write(_ value: String?, for name: String) throws {}
    func names() throws -> [String] { Array(stored.keys) }
}

@Suite("Boot does not read secret values", .serialized)
struct BootDoesNotReadSecretsTests {

    private func account(token: String = "TELEGRAM_TOKEN") -> ChannelAccount {
        ChannelAccount(id: "tg", platform: .telegram, name: "บอทของทีม",
                       tokenVariable: token, allowedChats: ["123"])
    }

    @Test("deciding a channel is ready asks whether the token exists, never what it is")
    func isReadyDoesNotReadTheValue() throws {
        let vault = SpyVault(["TELEGRAM_TOKEN": "12345:AAAA"])
        SecretStore.install(vault)
        defer { SecretStore.install(nil) }

        #expect(account().isReady)
        // The whole finding, as one assertion: a value read here is a Keychain
        // prompt on the boot path.
        #expect(vault.valueReads.isEmpty,
                "boot อ่านค่าโทเคนจริง — นั่นคือจุดที่ Keychain หยุดรอคนกดอนุญาต")
        #expect(vault.existenceChecks == ["TELEGRAM_TOKEN"])
    }

    @Test("the reason a channel is not running is also answered without the value")
    func blockersDoNotReadTheValue() throws {
        let vault = SpyVault([:])
        SecretStore.install(vault)
        defer { SecretStore.install(nil) }

        let reasons = account().blockers
        #expect(reasons.contains { $0.contains("TELEGRAM_TOKEN") })
        #expect(vault.valueReads.isEmpty)
    }

    @Test("a channel with no token is not ready, and one with a token is")
    func readinessStillFollowsTheToken() throws {
        let empty = SpyVault([:])
        SecretStore.install(empty)
        #expect(!account().isReady)

        let full = SpyVault(["TELEGRAM_TOKEN": "12345:AAAA"])
        SecretStore.install(full)
        defer { SecretStore.install(nil) }
        #expect(account().isReady)
    }

    @Test("sending still reads the value — the token is fetched where it is used")
    func theValueIsStillReachable() throws {
        let vault = SpyVault(["TELEGRAM_TOKEN": "12345:AAAA"])
        SecretStore.install(vault)
        defer { SecretStore.install(nil) }

        #expect(account().token == "12345:AAAA")
        #expect(vault.valueReads == ["TELEGRAM_TOKEN"],
                "การอ่านค่าจริงต้องยังทำได้ — ย้ายที่ ไม่ใช่เอาออก")
    }
}
