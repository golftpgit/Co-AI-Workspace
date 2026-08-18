import Foundation
import Security

// ─────────────────────────────────────────────────────────────
// The one place a secret is looked up (ARCHITECTURE §9.3, §12.2, §8.2 · P9.3).
//
// Three parts of the system agree on the same shape: an endpoint, a database
// connector and a bot account all store the *name* of a secret and never the
// value. This is where that name becomes a value.
//
// **What P9.3 found.** Until now the name was an environment variable name and
// this file read `ProcessInfo.processInfo.environment`. Measured, not assumed:
//
//     $ export COAI_PROBE_SECRET=hunter2
//     $ launchctl getenv COAI_PROBE_SECRET      # what a Finder-launched .app gets
//     (nothing)
//     $ launchctl getenv PATH
//     (nothing)
//
// A `.app` double-clicked in Finder inherits none of the user's shell. So every
// feature that needs a secret — paid endpoints, all three chat bots, a
// connector with a password, an MCP server with a token — **could not be given
// one at all in the shipping app**, and there was no screen anywhere to type it
// into. The code was right and unreachable: D6, for the eighth time.
//
// So the secret now lives in the Keychain, which is the thing on this machine
// that is actually built to hold one. Three decisions:
//
// 1. **The Keychain wins, the environment still works.** Lookup order is
//    override (tests) → vault → environment. Dropping the environment would
//    break every CI run and every `swift run` from a terminal for no gain; the
//    vault comes first so that rotating a key in the app is not silently
//    overruled by a stale `launchctl setenv`.
// 2. **"Could not read" is not "not set".** A locked or denied Keychain
//    returns `.unreadable`, never `.absent`. The two look identical to
//    anything that only asks yes/no, and the screens that tell a person why
//    their bot is not running must not answer "you never set the token" when
//    the truth is "this Mac would not open the Keychain". Same rule as U21-2's
//    grey dash and P1.8's "no channel to ask is a refusal".
// 3. **Nothing here ever returns a secret for display.** `names()` lists which
//    secrets exist; there is no API that hands a stored value back to the UI,
//    because a value on screen is a value in a screenshot.
// ─────────────────────────────────────────────────────────────

/// What is actually known about one secret.
public enum SecretStatus: Sendable, Equatable {
    /// A value is there. The value itself is deliberately not attached.
    case present(source: SecretSource)
    case absent
    /// The vault could not be asked. Distinct from `absent` on purpose — see
    /// decision 2 in the header.
    case unreadable(String)

    public var isPresent: Bool { if case .present = self { return true }; return false }
}

public enum SecretSource: String, Sendable, Equatable {
    case keychain
    /// Set in the process environment. Works, and worth saying out loud on the
    /// status screen: a `launchctl setenv` value is readable by every process
    /// this user runs, which the Keychain item is not.
    case environment
    /// A test override.
    case override
}

/// Where a secret actually lives. A protocol so tests stay hermetic — the
/// Keychain is shared machine state, and a suite that writes to it is a suite
/// that changes the computer it runs on (`LinkageKeySource`'s reason, unchanged).
public protocol SecretVault: Sendable {
    func read(_ name: String) throws -> String?
    /// Whether a secret of this name is stored — **without** fetching its
    /// value. Separate from `read` because on macOS the two are different
    /// questions to the Keychain: returning the bytes is what an item's access
    /// control guards, so `read` can stop and wait for a person to approve it,
    /// and asking for attributes cannot. Anything that only needs to know
    /// "is this configured" must ask this one; boot hung on the difference
    /// (Tests/ChannelsTests/BootDoesNotReadSecretsTests.swift).
    func exists(_ name: String) throws -> Bool
    /// `nil` deletes.
    func write(_ value: String?, for name: String) throws
    /// The names in the vault. Names only, never values.
    func names() throws -> [String]
}

extension SecretVault {
    /// Vaults with nothing to guard — the in-memory one tests use — answer by
    /// reading, which for them costs nothing and cannot prompt.
    public func exists(_ name: String) throws -> Bool {
        try read(name).map { !$0.isEmpty } ?? false
    }
}

public enum SecretVaultError: Error, CustomStringConvertible, Equatable {
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .keychain(let status):
            localised("the Keychain could not be reached (OSStatus \(status))", "A Keychain failure. Placeholder: the status code.")
        }
    }
}

/// The real vault.
public struct KeychainVault: SecretVault {
    private let service: String

    public init(service: String = "com.coaiworkspace.app.secrets") {
        self.service = service
    }

    public func read(_ name: String) throws -> String? {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            let value = String(decoding: data, as: UTF8.self)
            // Same rule the environment path has always had: a token set to ""
            // is not a token, and treating it as one moves the failure to the
            // first request.
            return value.isEmpty ? nil : value
        case errSecItemNotFound:
            return nil
        default:
            throw SecretVaultError.keychain(status)
        }
    }

    /// Attributes, never data. This is the call that does not prompt.
    public func exists(_ name: String) throws -> Bool {
        var query = baseQuery(name)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw SecretVaultError.keychain(status)
        }
    }

    public func write(_ value: String?, for name: String) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(name) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretVaultError.keychain(status)
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(name) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretVaultError.keychain(update) }

        var query = baseQuery(name)
        query[kSecValueData as String] = data
        // Only while this Mac is unlocked, and never synced anywhere: a token
        // that roams to iCloud is a token on a machine nobody audited
        // (`KeychainLinkageKeys` settled this).
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add = SecItemAdd(query as CFDictionary, nil)
        guard add == errSecSuccess else { throw SecretVaultError.keychain(add) }
    }

    public func names() throws -> [String] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            let entries = item as? [[String: Any]] ?? []
            return entries.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw SecretVaultError.keychain(status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// For tests, and for the audit: a vault in memory that leaves no trace on the
/// machine's Keychain. `failing` exists so the "could not read" path is
/// something a test can actually reach.
public final class MemoryVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private let failing: Bool

    public init(_ values: [String: String] = [:], failing: Bool = false) {
        self.values = values
        self.failing = failing
    }

    public func read(_ name: String) throws -> String? {
        if failing { throw SecretVaultError.keychain(errSecInteractionNotAllowed) }
        return lock.withLock { values[name] }
    }

    public func write(_ value: String?, for name: String) throws {
        if failing { throw SecretVaultError.keychain(errSecInteractionNotAllowed) }
        lock.withLock {
            if let value, !value.isEmpty { values[name] = value } else { values[name] = nil }
        }
    }

    public func names() throws -> [String] {
        if failing { throw SecretVaultError.keychain(errSecInteractionNotAllowed) }
        return lock.withLock { values.keys.sorted() }
    }
}

public enum SecretStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [String: String] = [:]
    nonisolated(unsafe) private static var vault: (any SecretVault)?

    /// Called once at boot with the vault this process should use. Left unset
    /// — as it is in every test target that does not ask for one — the store
    /// falls back to the environment and touches no Keychain at all.
    public static func install(_ vault: (any SecretVault)?) {
        lock.withLock { Self.vault = vault }
    }

    /// The value behind a name, or nil when it is unset, empty, or unreadable.
    ///
    /// Callers that need to tell those apart — anything that puts a reason on
    /// screen — must use `status` instead.
    public static func value(_ name: String) -> String? { look(name).value }

    public static func has(_ name: String) -> Bool { status(name).isPresent }

    /// What is known about this secret, including the case where the answer is
    /// "we could not find out".
    public static func status(_ name: String) -> SecretStatus {
        let (override, vault) = lock.withLock { (overrides[name], Self.vault) }
        return presence(name, override: override, vault: vault,
                        environment: ProcessInfo.processInfo.environment)
    }

    private static func look(_ name: String) -> (value: String?, status: SecretStatus) {
        let (override, vault) = lock.withLock { (overrides[name], Self.vault) }
        return resolve(name, override: override, vault: vault,
                       environment: ProcessInfo.processInfo.environment)
    }

    /// The same walk as `resolve`, asking only whether each layer *has* the
    /// secret. It returns no value and has no way to produce one, so the
    /// invariant `resolve`'s note is about — a status that disagrees with the
    /// value a caller is about to use — cannot be reached from here: there is
    /// nothing to disagree with.
    static func presence(_ name: String,
                         override: String?,
                         vault: (any SecretVault)?,
                         environment: [String: String]) -> SecretStatus {
        if let override { return override.isEmpty ? .absent : .present(source: .override) }
        if let vault {
            do {
                if try vault.exists(name) { return .present(source: .keychain) }
            } catch {
                return .unreadable("\(error)")
            }
        }
        return (environment[name] ?? "").isEmpty ? .absent : .present(source: .environment)
    }

    /// One lookup, one pass, and no global state.
    ///
    /// Split into two public entry points above rather than two
    /// implementations, so a caller can never get a status that disagrees with
    /// the value it is about to use. Written as a pure function because the
    /// alternative — tests that install a failing vault into a process-wide
    /// slot — would make every *other* suite running in parallel see a broken
    /// Keychain, which is the same shape of crash the override mechanism below
    /// exists to avoid.
    static func resolve(_ name: String,
                        override: String?,
                        vault: (any SecretVault)?,
                        environment: [String: String]) -> (value: String?, status: SecretStatus) {
        if let override {
            return override.isEmpty ? (nil, .absent) : (override, .present(source: .override))
        }
        if let vault {
            do {
                if let stored = try vault.read(name), !stored.isEmpty {
                    return (stored, .present(source: .keychain))
                }
            } catch {
                // Not `.absent`. A Mac that will not open its Keychain has told
                // us nothing about whether the token exists, and reporting
                // "you never set it" sends somebody to re-enter a key that is
                // already there.
                return (nil, .unreadable("\(error)"))
            }
        }
        let value = environment[name] ?? ""
        return value.isEmpty ? (nil, .absent) : (value, .present(source: .environment))
    }

    /// Stores a secret. The only writer — the UI calls this and then forgets
    /// the string it was holding.
    public static func set(_ value: String?, for name: String) throws {
        guard let vault = lock.withLock({ vault }) else {
            throw SecretStoreError.noVault
        }
        try vault.write(value, for: name)
    }

    /// Which secrets are stored, for the status screen. Names only.
    public static func storedNames() -> [String] {
        guard let vault = lock.withLock({ vault }) else { return [] }
        return (try? vault.names()) ?? []
    }

    // ─────────────────────────────────────────────────────────
    // Test overrides. These exist because the obvious alternative is a real
    // crash: `setenv` is not thread-safe against another thread reading
    // `environ`, and Swift Testing runs suites in parallel. A test that set a
    // variable while another read one took the whole run down with SIGSEGV —
    // intermittently, which is the worst way to find out.
    // ─────────────────────────────────────────────────────────

    /// Sets a value for this process without touching the environment or the
    /// Keychain. Nil removes the override.
    public static func override(_ name: String, _ value: String?) {
        lock.withLock {
            if let value { overrides[name] = value } else { overrides.removeValue(forKey: name) }
        }
    }

    public static func clearOverrides() {
        lock.withLock { overrides.removeAll() }
    }
}

public enum SecretStoreError: Error, CustomStringConvertible, Equatable {
    case noVault

    public var description: String {
        switch self {
        case .noVault:
            localised("no secret store (Keychain) has been installed in this process, so nothing can be saved", "Why a secret cannot be saved.")
        }
    }
}
