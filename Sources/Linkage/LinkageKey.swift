import Foundation
import CryptoKit
import Security
import Observability

// ─────────────────────────────────────────────────────────────
// The key that connects a code to a person (ARCHITECTURE §20.7, P11.7b).
//
// §20.7 says the identity table lives in a different file from the answers and
// its key lives in the Keychain. Both halves matter and they defend against
// different things: separate files mean a copy of the response data — the thing
// that gets emailed to a supervisor, dropped on a USB stick, attached to a
// submission — carries no identities at all; the Keychain means the identity
// file on its own is ciphertext, so a stolen laptop backup is not a list of who
// answered what.
//
// The key is per project. One key for the whole app would make two studies one
// breach, and a research project's data outlives the study by years.
// ─────────────────────────────────────────────────────────────

/// Where the sealing key comes from. A protocol so tests can be hermetic —
/// the Keychain is a shared, stateful thing on a real machine, and a test suite
/// that writes to it is a test suite that changes the machine it runs on.
public protocol LinkageKeySource: Sendable {
    func key(for project: String) throws -> SymmetricKey
}

public enum LinkageKeyError: Error, CustomStringConvertible, Equatable {
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .keychain(let status):
            "เข้าถึง Keychain ไม่ได้ (OSStatus \(status)) — "
                + "ตารางเชื่อมตัวตนจึงเปิดไม่ได้ ซึ่งถูกต้องกว่าการเปิดโดยไม่มีการเข้ารหัส"
        }
    }
}

/// The real one: a 256-bit key per project, created on first use.
///
/// **Read once per project per launch.** Every `SecItemCopyMatching` on a
/// keychain item whose ACL does not already trust this exact binary raises the
/// "…wants to use your confidential information" panel, and a `LinkageStore` is
/// built afresh every time the workspace switches projects — so without the
/// cache, moving between two studies asked twice, and moving back asked twice
/// more. The key cannot change under us: it is written once and never rotated
/// here, so a value read at 09:00 is the same value at 17:00.
///
/// This reduces how often the panel appears. It does not stop it: while the app
/// is signed ad-hoc its code signature *is* its hash, so every rebuild is a
/// different program as far as the keychain is concerned and the ACL granted to
/// the previous build no longer matches. The fix for that is a stable signing
/// identity, which is a build-time thing — see `scripts/build-app.sh`.
public struct KeychainLinkageKeys: LinkageKeySource {
    private let service: String
    private let log = AppLog.logger("linkage-key")

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: SymmetricKey] = [:]

    public init(service: String = "com.coaiworkspace.app.linkage") {
        self.service = service
    }

    /// Forgets the cached keys. For tests, and for anything that has reason to
    /// believe the keychain changed underneath it.
    public static func forgetCachedKeys() {
        cacheLock.withLock { cache.removeAll() }
    }

    public func key(for project: String) throws -> SymmetricKey {
        let cacheKey = "\(service)|\(project)"
        if let cached = Self.cacheLock.withLock({ Self.cache[cacheKey] }) { return cached }

        let key: SymmetricKey
        if let existing = try read(project) {
            key = SymmetricKey(data: existing)
        } else {
            key = SymmetricKey(size: .bits256)
            try write(project, key.withUnsafeBytes { Data($0) })
            log.info("created a linkage key for a project")
        }
        Self.cacheLock.withLock { Self.cache[cacheKey] = key }
        return key
    }

    private func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw LinkageKeyError.keychain(status)
        }
    }

    private func write(_ account: String, _ data: Data) throws {
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        // Available only when this Mac is unlocked, and never synced to another
        // device: a linkage key that roams is a linkage key on a machine nobody
        // audited.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw LinkageKeyError.keychain(status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// For tests: a key held in memory, so a test run leaves no trace on the
/// machine's Keychain.
public struct InMemoryLinkageKeys: LinkageKeySource {
    private let key: SymmetricKey
    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) { self.key = key }
    public func key(for project: String) throws -> SymmetricKey { key }
}
