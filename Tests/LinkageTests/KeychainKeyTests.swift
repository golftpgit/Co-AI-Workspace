import Testing
import Foundation
import CryptoKit
@testable import Linkage

// ─────────────────────────────────────────────────────────────
// The real key source (ARCHITECTURE §20.7, P11.7b).
//
// Every other test here uses the in-memory key source, so that a test run leaves
// nothing behind on the machine's Keychain. That is right, and it leaves one
// thing unproven: whether the implementation the app actually uses works. This
// suite exercises it once, against a service name of its own that it deletes
// afterwards.
//
// It skips rather than fails when the Keychain refuses. A CI machine with no
// login keychain is not a broken build, and a test that fails there teaches
// people to ignore red.
// ─────────────────────────────────────────────────────────────

@Suite("Keychain linkage keys", .serialized)
struct KeychainKeyTests {

    private static let service = "com.coaiworkspace.app.linkage.tests"

    private func cleanUp(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    @Test("the same project gets the same key back, and a different one does not")
    func keysArePerProjectAndStable() throws {
        let first = "pj_keychain_\(UUID().uuidString.prefix(8))"
        let second = "pj_keychain_\(UUID().uuidString.prefix(8))"
        defer { cleanUp(first); cleanUp(second) }

        let keys = KeychainLinkageKeys(service: Self.service)
        let one: SymmetricKey
        do {
            one = try keys.key(for: first)
        } catch {
            // No usable keychain in this environment — see the note above.
            withKnownIssue("Keychain unavailable here: \(error)") { Issue.record("skipped") }
            return
        }

        // Stable, or every restart would orphan every identity ever sealed.
        let again = try keys.key(for: first)
        #expect(one.withUnsafeBytes { Data($0) } == again.withUnsafeBytes { Data($0) })

        // Per project, because one key for the whole app would make two studies
        // one breach.
        let other = try keys.key(for: second)
        #expect(one.withUnsafeBytes { Data($0) } != other.withUnsafeBytes { Data($0) })
        #expect(one.bitCount == 256)
    }

    // Why the cache exists: every keychain read whose ACL does not already
    // trust this exact binary raises a panel at the user, and a `LinkageStore`
    // is rebuilt on every project switch. Without this, moving between two
    // studies asked twice and moving back asked twice more.
    @Test("a project's key is read from the keychain once, then remembered")
    func keyIsReadOncePerLaunch() throws {
        let project = "pj_cache_\(UUID().uuidString.prefix(8))"
        defer { cleanUp(project); KeychainLinkageKeys.forgetCachedKeys() }
        KeychainLinkageKeys.forgetCachedKeys()

        let keys = KeychainLinkageKeys(service: Self.service)
        let first: SymmetricKey
        do {
            first = try keys.key(for: project)
        } catch {
            withKnownIssue("Keychain unavailable here: \(error)") { Issue.record("skipped") }
            return
        }

        // Delete the item behind our back. A second call that still returns the
        // same key proves it did not go back to the keychain — and returning
        // the same key is also the *correct* answer, because the file on disk
        // is still encrypted with it.
        cleanUp(project)
        #expect(try keys.key(for: project) == first)

        // And forgetting really forgets: with the item gone, this makes a new
        // one rather than handing back the old.
        KeychainLinkageKeys.forgetCachedKeys()
        #expect(try keys.key(for: project) != first)
    }

    // Two services are two keychains as far as this type is concerned; the
    // cache must not confuse them, or a test service would hand its key to the
    // real one.
    @Test("the cache is keyed by service as well as by project")
    func cacheDistinguishesServices() throws {
        let project = "pj_svc_\(UUID().uuidString.prefix(8))"
        let other = Self.service + ".second"
        defer {
            cleanUp(project)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: other,
                           kSecAttrAccount as String: project] as CFDictionary)
            KeychainLinkageKeys.forgetCachedKeys()
        }
        KeychainLinkageKeys.forgetCachedKeys()

        let a: SymmetricKey
        do {
            a = try KeychainLinkageKeys(service: Self.service).key(for: project)
        } catch {
            withKnownIssue("Keychain unavailable here: \(error)") { Issue.record("skipped") }
            return
        }
        let b = try KeychainLinkageKeys(service: other).key(for: project)
        #expect(a != b, "two services shared one cached key")
    }
}
