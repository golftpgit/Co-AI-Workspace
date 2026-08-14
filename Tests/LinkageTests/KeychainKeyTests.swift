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
}
