import Testing
import Foundation
@testable import AgentKit

// ─────────────────────────────────────────────────────────────
// P9.3 — the store every secret in the app goes through.
//
// Almost everything here goes at `resolve`, the pure function, rather than at
// the process-wide store. That is not squeamishness about globals: a test that
// installs a *failing* vault into the shared slot makes every other suite
// running in parallel see a Keychain that will not open, and Swift Testing runs
// suites in parallel. The one thing that genuinely needs the global — that
// `install` is what makes a stored secret visible at all — gets its own test
// with a vault that answers normally, which is invisible to anybody else.
// ─────────────────────────────────────────────────────────────

@Suite("Secret lookup")
struct SecretLookupTests {

    @Test("a secret in the vault is found, and says it came from the Keychain")
    func readsFromVault() {
        let found = SecretStore.resolve("BOT_TOKEN", override: nil,
                                        vault: MemoryVault(["BOT_TOKEN": "123:abc"]),
                                        environment: [:])
        #expect(found.value == "123:abc")
        #expect(found.status == .present(source: .keychain))
    }

    // The environment stays supported on purpose: dropping it would break every
    // CI run and every `swift run` from a terminal, for no gain.
    @Test("with nothing in the vault the environment still works, and says so")
    func fallsBackToEnvironment() {
        let found = SecretStore.resolve("BOT_TOKEN", override: nil, vault: MemoryVault(),
                                        environment: ["BOT_TOKEN": "from-shell"])
        #expect(found.value == "from-shell")
        // Worth telling apart on screen: a `launchctl setenv` value is readable
        // by every process this user runs. The Keychain item is not.
        #expect(found.status == .present(source: .environment))
    }

    @Test("the vault wins over a stale environment variable")
    func vaultBeatsEnvironment() {
        let found = SecretStore.resolve("KEY", override: nil,
                                        vault: MemoryVault(["KEY": "rotated"]),
                                        environment: ["KEY": "old"])
        #expect(found.value == "rotated", "a key rotated in the app was overruled by the shell")
    }

    // The rule this whole file exists for. Before P9.3 there was one answer for
    // both, and it was the wrong one.
    @Test("a vault that will not open reports unreadable, never absent")
    func unreadableIsNotAbsent() {
        let found = SecretStore.resolve("KEY", override: nil, vault: MemoryVault(failing: true),
                                        environment: [:])
        #expect(found.value == nil)
        guard case .unreadable = found.status else {
            Issue.record("a locked Keychain reported the secret as never set: \(found.status)")
            return
        }
        #expect(found.status.isPresent == false)
    }

    // And it must not quietly fall through to the environment either: that
    // would turn a Keychain failure into "whatever the shell happens to hold",
    // which is how the wrong key reaches a paid endpoint.
    @Test("a failing vault does not fall through to the environment")
    func unreadableDoesNotFallThrough() {
        let found = SecretStore.resolve("KEY", override: nil, vault: MemoryVault(failing: true),
                                        environment: ["KEY": "something-else"])
        #expect(found.value == nil)
    }

    @Test("an empty string is not a secret, wherever it comes from")
    func emptyIsAbsent() {
        #expect(SecretStore.resolve("K", override: nil, vault: MemoryVault(["K": ""]),
                                    environment: [:]).status == .absent)
        #expect(SecretStore.resolve("K", override: nil, vault: nil,
                                    environment: ["K": ""]).status == .absent)
        #expect(SecretStore.resolve("K", override: "", vault: nil,
                                    environment: [:]).status == .absent)
    }

    @Test("with no vault installed the store behaves exactly as it did before")
    func noVaultIsTheOldBehaviour() {
        let found = SecretStore.resolve("K", override: nil, vault: nil,
                                        environment: ["K": "v"])
        #expect(found.value == "v")
    }
}

@Suite("Secret vault — storing and forgetting")
struct SecretVaultTests {

    @Test("writing then reading returns the secret; writing nil forgets it")
    func writeThenRead() throws {
        let vault = MemoryVault()
        try vault.write("s3cret", for: "KEY")
        #expect(try vault.read("KEY") == "s3cret")

        try vault.write(nil, for: "KEY")
        #expect(try vault.read("KEY") == nil)
    }

    // The UI needs to show which secrets exist. It must never be able to show
    // what they are.
    @Test("the vault lists names and offers no way to list values")
    func namesOnly() throws {
        let vault = MemoryVault(["B": "2", "A": "1"])
        #expect(try vault.names() == ["A", "B"])
    }

    @Test("saving an empty string deletes rather than storing an empty secret")
    func emptyDeletes() throws {
        let vault = MemoryVault(["KEY": "old"])
        try vault.write("", for: "KEY")
        #expect(try vault.read("KEY") == nil)
    }
}

@Suite("Secret store — the process-wide install", .serialized)
struct SecretStoreInstallTests {

    // The point of the whole change: a `.app` from Finder has no shell
    // environment (measured — `launchctl getenv` returns nothing), so a secret
    // is reachable only if something installed a vault at boot.
    @Test("installing a vault makes a stored secret visible; uninstalling hides it again")
    func installMakesSecretsReachable() throws {
        let name = "COAI_TEST_INSTALLED_\(UUID().uuidString.prefix(8))"
        defer { SecretStore.install(nil) }

        #expect(SecretStore.has(name) == false)

        let vault = MemoryVault()
        SecretStore.install(vault)
        try SecretStore.set("stored-in-the-vault", for: name)

        #expect(SecretStore.value(name) == "stored-in-the-vault")
        #expect(SecretStore.storedNames().contains(name))

        SecretStore.install(nil)
        #expect(SecretStore.has(name) == false, "the value survived the vault being removed")
    }

    // Better than writing a secret nowhere and reporting success.
    @Test("saving with no vault installed fails loudly")
    func savingWithoutAVaultThrows() {
        SecretStore.install(nil)
        #expect(throws: SecretStoreError.noVault) {
            try SecretStore.set("x", for: "COAI_TEST_NO_VAULT")
        }
    }
}
