import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// M3 PluginRegistry — a plugin is a packaged MCP server (ARCHITECTURE §7.1,
// §7.3, P8.4).
//
// §7.1 decides the layer: code that has to run as a process is a plugin, and a
// plugin gets the sandbox and the standard protocol for free by being an MCP
// server. So there is nothing here about tools, calling or risk — P8.3 already
// owns all of that. What is left is the part that is genuinely about files:
// what a package must contain, what makes one refusable, and what "uninstall"
// has to be able to undo.
//
// **This module still cannot reach a tool.** Roster depends on AgentKit and
// Observability and nothing else — not MCPBridge, whose `MCPTool` is an
// `AgentTool`. So a plugin is described here as data (a command, arguments, a
// directory) and connected somewhere that is allowed to. The rule is the one
// in Package.swift, and it is the same rule that keeps a channel away from the
// gateway.
//
// **A package is self-contained or it is not a package.** A manifest may name
// an interpreter on `PATH` — `python3`, `node`, `uvx` — or a file inside its
// own folder. It may not name an absolute path: a "plugin" pointing at
// something elsewhere on the machine is a shortcut, not a package, and
// uninstalling it would leave whatever it pointed at behind while reporting
// success.
// ─────────────────────────────────────────────────────────────

/// `plugin.json`, as the author writes it.
public struct PluginManifest: Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    public var version: String?
    /// An interpreter on `PATH`, or a path relative to the plugin's folder.
    public var command: String
    public var arguments: [String]
    /// `SERVER_VARIABLE: our-variable-name` — the same shape as everywhere
    /// else: the name of a variable, never a value (§8.2, §9.3, §12.2).
    public var environmentVariables: [String: String]

    public init(name: String, description: String, version: String? = nil,
                command: String, arguments: [String] = [],
                environmentVariables: [String: String] = [:]) {
        self.name = name
        self.description = description
        self.version = version
        self.command = command
        self.arguments = arguments
        self.environmentVariables = environmentVariables
    }

    /// Written out because the synthesised one makes every field mandatory,
    /// including the two that most plugins have no reason to mention. A
    /// manifest rejected for omitting `"environmentVariables": {}` would be a
    /// manifest rejected for being ordinary.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environmentVariables = try container
            .decodeIfPresent([String: String].self, forKey: .environmentVariables) ?? [:]
    }
}

/// A plugin that is on this machine, with its paths resolved.
public struct InstalledPlugin: Sendable, Equatable, Identifiable {
    public let manifest: PluginManifest
    /// Where the package lives now — inside the app's plugins directory, not
    /// wherever it was installed from.
    public let directory: URL
    public var id: String { manifest.name }

    public var name: String { manifest.name }

    /// The command as the launcher should use it: a bare interpreter name
    /// stays bare so `PATH` resolves it, and a bundled executable becomes the
    /// absolute path it now has.
    public var command: String {
        manifest.command.contains("/")
            ? directory.appending(path: manifest.command).path(percentEncoded: false)
            : manifest.command
    }

    public var arguments: [String] {
        // Arguments that name files in the package are relative to it, and the
        // server is launched with the package as its working directory — so
        // they are passed through untouched. This is why `workingDirectory`
        // below is not optional.
        manifest.arguments
    }

    /// Always the package's own folder. A server that reads its data files
    /// relatively then works regardless of where the app was launched from.
    public var workingDirectory: String { directory.path(percentEncoded: false) }

    public var environmentVariables: [String: String] { manifest.environmentVariables }
}

public enum PluginError: Error, CustomStringConvertible, Equatable {
    case noManifest(String)
    case unreadableManifest(String, reason: String)
    case missingField(String, field: String)
    case absoluteCommand(String, command: String)
    case escapingPath(String, path: String)
    case commandMissing(String, command: String)
    case alreadyInstalled(String)
    case notInstalled(String)

    public var description: String {
        switch self {
        case .noManifest(let folder):
            return "โฟลเดอร์ \(folder) ไม่มีไฟล์ plugin.json"
        case .unreadableManifest(let folder, let reason):
            return "plugin.json ใน \(folder) อ่านไม่ได้: \(reason)"
        case .missingField(let name, let field):
            return "plugin '\(name)' ไม่ได้ระบุ \(field)"
        case .absoluteCommand(let name, let command):
            return "plugin '\(name)' ชี้ไปที่ '\(command)' ซึ่งเป็นพาธเต็มนอกโฟลเดอร์ตัวเอง — "
                + "ปลั๊กอินต้องรันไฟล์ในแพ็กเกจของตัวเอง หรือใช้ล่ามที่อยู่บน PATH เท่านั้น"
        case .escapingPath(let name, let path):
            return "plugin '\(name)' อ้างพาธ '\(path)' ที่ออกไปนอกโฟลเดอร์ของตัวเอง"
        case .commandMissing(let name, let command):
            return "plugin '\(name)' ต้องใช้ '\(command)' แต่ไม่มีไฟล์นั้นในแพ็กเกจ"
        case .alreadyInstalled(let name):
            return "ติดตั้ง plugin ชื่อ '\(name)' ไว้อยู่แล้ว — ถอนตัวเดิมก่อนถ้าจะติดตั้งทับ"
        case .notInstalled(let name):
            return "ไม่ได้ติดตั้ง plugin ชื่อ '\(name)' ไว้"
        }
    }
}

public struct PluginRegistry: Sendable {
    public static let manifestName = "plugin.json"

    public let directory: URL
    private let log = AppLog.logger("roster")

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - reading

    /// Everything installed, by name. A folder that stopped being a valid
    /// package is skipped rather than fatal — the same rule as the manifest
    /// loader: one bad file must not empty the registry.
    public func installed() -> [InstalledPlugin] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            do {
                return InstalledPlugin(manifest: try Self.manifest(in: folder), directory: folder)
            } catch {
                let reason = (error as? PluginError)?.description ?? "\(error)"
                log.error("plugin in \(folder.lastPathComponent, privacy: .public) skipped: \(reason, privacy: .public)")
                return nil
            }
        }.sorted { $0.name < $1.name }
    }

    public func plugin(named name: String) -> InstalledPlugin? {
        installed().first { $0.name == name }
    }

    // MARK: - installing

    /// Copies a package into the app's plugins directory and returns it.
    ///
    /// Copied rather than referenced: the folder somebody installed from is
    /// usually in Downloads, and a plugin that stops working because its
    /// source folder was tidied away is a plugin that fails for a reason
    /// nobody will connect to what they did.
    @discardableResult
    public func install(from source: URL) throws -> InstalledPlugin {
        let manifest = try Self.manifest(in: source)
        try Self.validate(manifest, in: source)
        guard plugin(named: manifest.name) == nil else {
            throw PluginError.alreadyInstalled(manifest.name)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: Self.folderName(for: manifest.name))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        log.info("plugin '\(manifest.name, privacy: .public)' installed")
        return InstalledPlugin(manifest: manifest, directory: destination)
    }

    /// Removes the package from disk. Whoever is running its server has to be
    /// told separately — this module cannot reach a process any more than it
    /// can reach a tool.
    public func uninstall(_ name: String) throws {
        guard let plugin = plugin(named: name) else { throw PluginError.notInstalled(name) }
        try FileManager.default.removeItem(at: plugin.directory)
        log.info("plugin '\(name, privacy: .public)' uninstalled")
    }

    // MARK: - the rules

    static func manifest(in folder: URL) throws -> PluginManifest {
        let file = folder.appending(path: manifestName)
        guard let data = try? Data(contentsOf: file) else {
            throw PluginError.noManifest(folder.lastPathComponent)
        }
        do {
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            // The decoder's own message names the field, which is the useful
            // half of it.
            throw PluginError.unreadableManifest(folder.lastPathComponent,
                                                 reason: Self.reason(for: error))
        }
    }

    static func validate(_ manifest: PluginManifest, in folder: URL) throws {
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.missingField("(ไม่มีชื่อ)", field: "name")
        }
        guard !manifest.command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.missingField(manifest.name, field: "command")
        }
        guard !manifest.command.hasPrefix("/") && !manifest.command.hasPrefix("~") else {
            throw PluginError.absoluteCommand(manifest.name, command: manifest.command)
        }
        // `..` in the command or in any argument would reach outside the
        // package — which is the one thing a package may not do.
        for path in [manifest.command] + manifest.arguments
        where path.split(separator: "/").contains("..") {
            throw PluginError.escapingPath(manifest.name, path: path)
        }
        // A bundled command has to be in the bundle. An interpreter on PATH is
        // resolved at launch, where a missing one is reported by the launcher.
        if manifest.command.contains("/") {
            let executable = folder.appending(path: manifest.command)
            guard FileManager.default.fileExists(atPath: executable.path(percentEncoded: false))
            else {
                throw PluginError.commandMissing(manifest.name, command: manifest.command)
            }
        }
    }

    /// A folder name derived from the plugin's own, so the plugins directory
    /// is readable by a person looking at it in Finder.
    static func folderName(for name: String) -> String {
        let safe = name.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
                ? character : "-"
        }
        let joined = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return joined.isEmpty ? "plugin-\(abs(name.hashValue))" : joined
    }

    private static func reason(for error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case .keyNotFound(let key, _): return "ขาดฟิลด์ '\(key.stringValue)'"
        case .typeMismatch(_, let context):
            return "ฟิลด์ '\(context.codingPath.map(\.stringValue).joined(separator: "."))' ผิดชนิด"
        case .valueNotFound(_, let context):
            return "ฟิลด์ '\(context.codingPath.map(\.stringValue).joined(separator: "."))' ว่าง"
        default: return "รูปแบบ JSON ไม่ถูกต้อง"
        }
    }
}
