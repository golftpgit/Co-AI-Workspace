import Foundation

// ─────────────────────────────────────────────────────────────
// Finding a program a sandboxed app can actually run (P9.6).
//
// **The fact this file exists for**, measured rather than assumed: on macOS
// 26, `/usr/bin/python3`, `/usr/bin/git` and `/usr/bin/swift` are the *same
// binary* — identical SHA-256 — a single multiplexed shim that forwards to the
// selected toolchain through `xcrun`. And `xcrun` refuses to run inside an App
// Sandbox:
//
//     xcrun: error: cannot be used within an App Sandbox.
//
// So a sandboxed app that resolves `python3` the way a shell would finds a
// program that cannot start. Both of this project's interpreters walked into
// it: the notebook kernel (§12.5) and, visibly, the first plugin installed
// through the real app (P8.4) — which was reported as "installed, not
// connected" with no explanation anybody could act on.
//
// The real interpreters underneath the shim run fine sandboxed; that was
// checked with a signed, sandboxed probe before any of this was written. So
// the fix is only an ordering: look where the real ones live, first.
//
// **The same probe measured something the order below cannot fix.** Inside the
// sandbox, `/opt/homebrew` and `/usr/local` are not merely unlikely — they are
// invisible:
//
//     sandboxed:     INVISIBLE /opt/homebrew/bin/python3
//                    INVISIBLE /usr/local/bin/python3
//                    visible   /Library/Developer/CommandLineTools/usr/bin/python3
//     not sandboxed: visible   /opt/homebrew/bin/python3   (339 entries in that directory)
//
// So the app can only ever run an interpreter that ships with the developer
// tools, and that one has no third-party packages in it. Homebrew stays first
// in the list because it is right for every unsandboxed caller — the tests,
// the scripts, a command-line run — but a plugin or a notebook that needs
// `pandas` needs its own interpreter inside the bundle, and that is a
// packaging job, not a search-order one (P9.6, and the reason P3.1's SearXNG
// venv cannot simply be copied in: it is a Homebrew 3.14 venv).
// ─────────────────────────────────────────────────────────────

public enum ExecutableSearchError: Error, CustomStringConvertible, Equatable {
    case notFound(String, searched: [String])
    /// Found, but only as the shim — which inside a sandbox is the same as not
    /// found, and needs to say so in words somebody can act on.
    case onlyDeveloperShim(String, path: String)

    public var description: String {
        switch self {
        case .notFound(let command, let searched):
            return "ไม่พบคำสั่ง '\(command)' — หาใน: \(searched.joined(separator: ", "))"
        case .onlyDeveloperShim(let command, let path):
            return "'\(command)' ที่มีอยู่คือ \(path) ซึ่งเป็นตัวแทน (shim) ของ Apple ที่เรียก xcrun "
                + "และ xcrun ทำงานใน App Sandbox ไม่ได้ — ต้องมีตัวจริง เช่นติดตั้ง Command Line Tools "
                + "(xcode-select --install) หรือ Homebrew แล้วลองใหม่"
        }
    }
}

public enum ExecutableSearch {

    /// Where the real ones live, in the order a person would want them: their
    /// own installs first, then the toolchains that ship with the developer
    /// tools. Searched *before* `PATH` — the point of this type.
    public static let toolchainDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/Library/Developer/CommandLineTools/usr/bin",
        "/Applications/Xcode.app/Contents/Developer/usr/bin",
    ]

    /// Directories whose developer tools are the shim.
    static let shimDirectories = ["/usr/bin"]

    /// Whether this process is inside an App Sandbox. Set by the system for
    /// every sandboxed process; absent everywhere else, including in tests,
    /// which is why it is injectable below.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Resolves a command to a path this process can actually execute.
    ///
    /// A command containing a slash is taken as given — the caller has said
    /// exactly what it wants. Otherwise the real toolchains are searched
    /// first, then `PATH`, and `/usr/bin` last.
    public static func resolve(
        _ command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sandboxed: Bool? = nil,
        fileManager: FileManager = .default
    ) throws -> String {
        if command.contains("/") {
            guard fileManager.isExecutableFile(atPath: command) else {
                throw ExecutableSearchError.notFound(command, searched: [])
            }
            return command
        }

        let inSandbox = sandboxed ?? isSandboxed
        // The app's own PATH is short when it is launched from Finder rather
        // than a shell, so the toolchain directories are not merely preferred
        // — often they are the only ones that would be looked at at all.
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var searched: [String] = []
        var shim: String?

        for directory in toolchainDirectories + path + shimDirectories + ["/bin"] {
            guard !searched.contains(directory) else { continue }
            searched.append(directory)
            let candidate = directory + "/" + command
            guard fileManager.isExecutableFile(atPath: candidate) else { continue }
            if inSandbox && shimDirectories.contains(directory) {
                // Remember it, but keep looking: /usr/bin is last anyway, so
                // reaching here means nothing better exists.
                shim = shim ?? candidate
                continue
            }
            return candidate
        }

        if let shim { throw ExecutableSearchError.onlyDeveloperShim(command, path: shim) }
        throw ExecutableSearchError.notFound(command, searched: searched)
    }

    /// Every interpreter of this name on the machine, best first. For callers
    /// that want to report what they tried rather than only what they picked.
    public static func candidates(_ command: String,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  fileManager: FileManager = .default) -> [String] {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen: [String] = []
        var found: [String] = []
        for directory in toolchainDirectories + path + shimDirectories + ["/bin"] {
            guard !seen.contains(directory) else { continue }
            seen.append(directory)
            let candidate = directory + "/" + command
            if fileManager.isExecutableFile(atPath: candidate) { found.append(candidate) }
        }
        return found
    }
}
