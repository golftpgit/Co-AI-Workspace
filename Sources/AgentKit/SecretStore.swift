import Foundation

// ─────────────────────────────────────────────────────────────
// The one place a secret is looked up (ARCHITECTURE §9.3, §12.2, §8.2).
//
// Three parts of the system now agree on the same shape: an endpoint, a
// database connector and a bot account all store the *name* of an environment
// variable and never the value. This is where that name becomes a value, and
// having one such place is what will make P9.2's move to the Keychain a change
// to one file rather than to three.
//
// The override exists for tests, and it exists because the obvious alternative
// is a real crash: `setenv` is not thread-safe against another thread reading
// `environ`, and Swift Testing runs suites in parallel. A test that set a
// variable while another test read one took the whole run down with SIGSEGV —
// intermittently, which is the worst way to find out.
// ─────────────────────────────────────────────────────────────

public enum SecretStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [String: String] = [:]

    /// The value behind a variable name, or nil when it is unset or empty.
    /// Empty and unset are the same thing here: a token set to "" is not a
    /// token, and treating it as one moves the failure to the first request.
    public static func value(_ name: String) -> String? {
        if let override = lock.withLock({ overrides[name] }) {
            return override.isEmpty ? nil : override
        }
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        return value.isEmpty ? nil : value
    }

    public static func has(_ name: String) -> Bool { value(name) != nil }

    /// Sets a value for this process without touching the environment. Nil
    /// removes the override and falls back to the real one.
    public static func override(_ name: String, _ value: String?) {
        lock.withLock {
            if let value { overrides[name] = value } else { overrides.removeValue(forKey: name) }
        }
    }

    public static func clearOverrides() {
        lock.withLock { overrides.removeAll() }
    }
}
