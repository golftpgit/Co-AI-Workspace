import Foundation
import os
import AgentKit
import Observability
import Execution

// ─────────────────────────────────────────────────────────────
// M6/MCP — which servers to run (ARCHITECTURE §6.2, §10, P8.3).
//
// A file, for the same reasons as the channels and the DB connectors: it is
// read before anything is connected to anything, and a person should be able
// to open it and see exactly what will be launched on their machine. Secrets
// are named, never written — `environmentVariables` maps a variable the server
// wants to a name we look up at launch, so a token lives in the Keychain
// (P9.3) and not in a file that gets copied around.
// ─────────────────────────────────────────────────────────────

public struct MCPServerConfig: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    /// What the tools will be namespaced under. Kept short: it is a prefix on
    /// every tool name the model sees.
    public var name: String
    /// The program to run. A bare name is looked up on `PATH` — an MCP server
    /// is nearly always `npx`, `uvx` or `python3`, and writing the absolute
    /// path of a Homebrew binary into a config file is how it breaks on the
    /// next machine.
    public var command: String
    public var arguments: [String]
    /// §"stdio cwd" — the directory the server is launched in. Many servers
    /// take their root from it rather than from an argument, so a server with
    /// the wrong cwd is a server serving the wrong project.
    public var workingDirectory: String?
    /// `SERVER_VARIABLE: the-name-we-filed-it-under`. The value is looked up
    /// at launch; a name with nothing behind it is a blocker, not an empty
    /// string quietly passed along.
    public var environmentVariables: [String: String]
    public var isEnabled: Bool

    public init(id: String = OpaqueID.make("mcp"),
                name: String,
                command: String,
                arguments: [String] = [],
                workingDirectory: String? = nil,
                environmentVariables: [String: String] = [:],
                isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentVariables = environmentVariables
        self.isEnabled = isEnabled
    }

    /// The prefix every tool from this server carries. Sanitised because a
    /// tool name travels to the model inside a JSON schema, and providers
    /// restrict it to `[A-Za-z0-9_-]`; a server called "งานวิจัย" must not
    /// produce a tool list that the endpoint rejects wholesale.
    public var namespace: String {
        let allowed = name.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
                ? character : "_"
        }
        let joined = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return joined.isEmpty ? "server" : joined
    }

    /// Why this server will not be launched, in the words the screen shows.
    public var blockers: [String] {
        var reasons: [String] = []
        if !isEnabled { reasons.append("ปิดอยู่") }
        if command.trimmingCharacters(in: .whitespaces).isEmpty {
            reasons.append("ยังไม่ได้ระบุคำสั่งที่จะรัน")
        }
        for (wanted, variable) in environmentVariables.sorted(by: { $0.key < $1.key }) {
            switch SecretStore.status(variable) {
            case .present: continue
            case .absent:
                reasons.append("ยังไม่ได้ตั้งค่าของ \(wanted) (“\(variable)”)")
            case .unreadable(let detail):
                // Not the same sentence as "not set" — P9.3's rule.
                reasons.append("อ่านค่าของ \(wanted) (“\(variable)”) ไม่ได้: \(detail)")
            }
        }
        if let workingDirectory,
           !FileManager.default.fileExists(atPath: workingDirectory) {
            reasons.append("โฟลเดอร์ \(workingDirectory) ไม่มีอยู่")
        }
        return reasons
    }

    public var isReady: Bool { blockers.isEmpty }

    /// The environment to launch with, resolved now.
    public func resolvedEnvironment() -> [String: String] {
        var resolved: [String: String] = [:]
        for (wanted, variable) in environmentVariables {
            if let value = SecretStore.value(variable) { resolved[wanted] = value }
        }
        return resolved
    }
}

/// Where the list is kept.
public struct MCPServerStore: Sendable {
    public let file: URL
    private let log = AppLog.logger("mcp")

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            reportUnreadable(file, kind: "MCP server", log: log)
            return []
        }
        return servers
    }

    public func save(_ servers: [MCPServerConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(servers).write(to: file, options: .atomic)
    }
}

// ─────────────────────────────────────────────────────────────

public enum MCPServerError: Error, CustomStringConvertible, Equatable {
    case commandNotFound(String, searched: [String])
    case launchFailed(String)
    /// The handshake did not finish in time. Carries whatever the server put
    /// on stderr, which is usually the actual explanation.
    case handshakeTimedOut(seconds: Int, stderr: String)
    case handshakeFailed(String, stderr: String)
    case notConnected(String)
    case callFailed(String)

    public var description: String {
        switch self {
        case .commandNotFound(let command, let searched):
            return "ไม่พบคำสั่ง '\(command)' — หาใน: \(searched.joined(separator: ", "))"
        case .launchFailed(let reason):
            return "เริ่มเซิร์ฟเวอร์ไม่ได้: \(reason)"
        case .handshakeTimedOut(let seconds, let stderr):
            return "เซิร์ฟเวอร์ไม่ตอบ initialize ภายใน \(seconds) วินาที"
                + (stderr.isEmpty ? "" : " — stderr: \(stderr.trimmed(to: 400))")
        case .handshakeFailed(let reason, let stderr):
            return "handshake ล้มเหลว: \(reason)"
                + (stderr.isEmpty ? "" : " — stderr: \(stderr.trimmed(to: 400))")
        case .notConnected(let name):
            return "เซิร์ฟเวอร์ '\(name)' ไม่ได้เชื่อมต่ออยู่"
        case .callFailed(let reason):
            return "เรียกเครื่องมือไม่สำเร็จ: \(reason)"
        }
    }
}

extension String {
    func trimmed(to limit: Int) -> String {
        let compact = trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.count <= limit ? compact : String(compact.prefix(limit)) + "…"
    }
}

/// Finds the program a plugin or MCP server named.
///
/// Delegates to `ExecutableSearch` (P9.6) rather than walking `PATH` itself:
/// a sandboxed app that resolves `python3` the way a shell would gets Apple's
/// `xcrun` shim, which cannot start inside a sandbox — which is precisely how
/// the first plugin installed in the real app failed, silently.
public enum CommandLookup {
    public static func resolve(_ command: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> String {
        do {
            return try ExecutableSearch.resolve(command, environment: environment)
        } catch let error as ExecutableSearchError {
            // Re-thrown in this module's vocabulary so the status screen shows
            // one kind of error, with the searched paths still in it.
            switch error {
            case .notFound(let name, let searched):
                throw MCPServerError.commandNotFound(name, searched: searched)
            case .onlyDeveloperShim:
                throw MCPServerError.launchFailed(error.description)
            }
        }
    }
}

/// A list file that will not decode. The copy is taken here, before anything
/// can save over it, and the report is kept where a screen can show it — a
/// corrupt file that only ever reached the unified log is a list that went
/// empty one morning with no explanation (P9.4).
private func reportUnreadable(_ file: URL, kind: String, log: Logger) {
    let failure = FileStoreSafety.reportUnreadable(file, describedAs: kind)
    log.error("\(failure.summary, privacy: .public)")
}
