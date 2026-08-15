import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Turning what somebody typed into an `MCPServerConfig` (ARCHITECTURE §6.2).
//
// `MCPServerStore` has been on the engine since P8.3 and no screen ever read
// it. A packaged plugin can be installed (P8.4), but adding a server by naming
// the command it runs meant editing JSON beside the database — the same shape
// of gap as the channels, found by the same `check.sh` rule.
//
// Two pieces of parsing with teeth in them:
//
//  • **Arguments are not split on spaces.** `--root "/Users/me/My Papers"`
//    split naively is three arguments, the server starts against the wrong
//    directory or refuses to start, and nothing on screen suggests the quotes
//    were the problem. This honours quotes.
//  • **The namespace is shown, because it is not the name.** Every tool from a
//    server is prefixed `mcp__<namespace>__`, and the namespace keeps only
//    ASCII letters, digits and `-`. A server called "งานวิจัย" therefore
//    namespaces as `server` — and so does a second one, at which point their
//    tools collide and one of them silently wins. The editor shows the prefix
//    that will actually appear and says when the name produced none of it.
// ─────────────────────────────────────────────────────────────

public struct MCPServerDraft: Sendable, Equatable {
    public var name: String
    public var command: String
    /// As typed, one line or space-separated, quotes honoured.
    public var argumentsText: String
    public var workingDirectory: String
    /// One `SERVER_VARIABLE = name-we-filed-it-under` per line.
    public var environmentText: String
    public var isEnabled: Bool

    public init(name: String = "", command: String = "", argumentsText: String = "",
                workingDirectory: String = "", environmentText: String = "",
                isEnabled: Bool = true) {
        self.name = name
        self.command = command
        self.argumentsText = argumentsText
        self.workingDirectory = workingDirectory
        self.environmentText = environmentText
        self.isEnabled = isEnabled
    }

    public init(_ config: MCPServerConfig) {
        self.name = config.name
        self.command = config.command
        self.argumentsText = config.arguments
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
        self.workingDirectory = config.workingDirectory ?? ""
        self.environmentText = config.environmentVariables
            .sorted { $0.key < $1.key }
            .map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n")
        self.isEnabled = config.isEnabled
    }

    /// The arguments, with quoted runs kept whole.
    public var arguments: [String] {
        var found: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        for character in argumentsText {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                // An empty quoted string is an argument, not nothing.
                started = true
            } else if character.isWhitespace {
                if started { found.append(current); current = ""; started = false }
            } else {
                current.append(character)
                started = true
            }
        }
        if started { found.append(current) }
        return found
    }

    /// `SERVER_VARIABLE: the-name-we-filed-it-under`, one per line.
    ///
    /// Lines without a separator are dropped rather than guessed at: half a
    /// mapping launched with an empty value is a server that starts and fails
    /// its first authenticated call.
    public var environmentVariables: [String: String] {
        var mapping: [String: String] = [:]
        for line in environmentText.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let wanted = parts[0].trimmingCharacters(in: .whitespaces)
            let variable = parts[1].trimmingCharacters(in: .whitespaces)
            guard !wanted.isEmpty, !variable.isEmpty else { continue }
            mapping[wanted] = variable
        }
        return mapping
    }

    /// The prefix every tool from this server will carry.
    public var namespace: String { config().namespace }

    public var problems: [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("ตั้งชื่อเซิร์ฟเวอร์ก่อน — ชื่อนี้กลายเป็นคำนำหน้าของทูลทุกตัวที่มันให้")
        }
        if command.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("ต้องระบุคำสั่งที่จะรัน เช่น npx, uvx หรือ python3")
        }
        return found
    }

    public var canSave: Bool { problems.isEmpty }

    public var warnings: [String] {
        var found: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, namespace == "server" {
            // The collision case: two servers whose names are entirely
            // non-ASCII both namespace as `server`, and their tools then have
            // the same names.
            found.append("ชื่อนี้ไม่มีตัวอักษรอังกฤษหรือตัวเลขเลย ทูลจึงจะขึ้นต้นว่า "
                         + "`mcp__server__` — ถ้ามีเซิร์ฟเวอร์อื่นแบบเดียวกัน ชื่อทูลจะชนกัน "
                         + "ใส่ชื่ออังกฤษสั้น ๆ ไว้ด้วยจะปลอดภัยกว่า")
        }
        if !workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty,
           !FileManager.default.fileExists(atPath:
                workingDirectory.trimmingCharacters(in: .whitespaces)) {
            found.append("โฟลเดอร์ที่ระบุยังไม่มีอยู่ — เซิร์ฟเวอร์หลายตัวถือรากจากโฟลเดอร์นี้")
        }
        if command.hasPrefix("/") {
            // §6.2's note, at the moment somebody is about to do it.
            found.append("ใส่พาธเต็มไว้ จะพังบนเครื่องถัดไปที่ติดตั้งไว้คนละที่ — "
                         + "ใส่ชื่อคำสั่งเปล่า ๆ แล้วให้ระบบหาให้ดีกว่า")
        }
        return found
    }

    public func config(id: String? = nil) -> MCPServerConfig {
        let directory = workingDirectory.trimmingCharacters(in: .whitespaces)
        return MCPServerConfig(
            id: id ?? OpaqueID.make("mcp"),
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            arguments: arguments,
            workingDirectory: directory.isEmpty ? nil : directory,
            environmentVariables: environmentVariables,
            isEnabled: isEnabled)
    }
}
