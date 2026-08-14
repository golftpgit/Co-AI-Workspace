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
public struct KeychainLinkageKeys: LinkageKeySource {
    private let service: String
    private let log = AppLog.logger("linkage-key")

    public init(service: String = "com.coaiworkspace.app.linkage") {
        self.service = service
    }

    public func key(for project: String) throws -> SymmetricKey {
        if let existing = try read(project) { return SymmetricKey(data: existing) }
        let fresh = SymmetricKey(size: .bits256)
        let bytes = fresh.withUnsafeBytes { Data($0) }
        try write(project, bytes)
        log.info("created a linkage key for a project")
        return fresh
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
