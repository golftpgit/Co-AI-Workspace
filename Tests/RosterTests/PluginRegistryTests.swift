import Testing
import Foundation
import AgentKit
@testable import Roster

// ─────────────────────────────────────────────────────────────
// Installing somebody else's package (ARCHITECTURE §7.1, P8.4).
//
// Every refusal below is one shape of "this is not a package". The rule they
// share: after `uninstall`, nothing of the plugin may be left on the machine,
// and that is only achievable if everything it runs was inside its own folder
// to begin with.
// ─────────────────────────────────────────────────────────────

private func workspace() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "coai-plugins-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A package on disk: a folder, a manifest, and whatever files it names.
@discardableResult
private func package(_ manifest: String, in parent: URL, named folder: String,
                     files: [String: String] = [:]) throws -> URL {
    let directory = parent.appending(path: folder)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try manifest.write(to: directory.appending(path: "plugin.json"),
                       atomically: true, encoding: .utf8)
    for (name, contents) in files {
        let file = directory.appending(path: name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
    return directory
}

private let validManifest = """
{
  "name": "weather",
  "description": "ดูพยากรณ์อากาศ",
  "version": "1.0.0",
  "command": "python3",
  "arguments": ["server.py"]
}
"""

@Suite("Plugin registry")
struct PluginRegistryTests {

    @Test("a package is copied in, listed, and removed completely")
    func installListUninstall() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(validManifest, in: root, named: "downloaded",
                                 files: ["server.py": "print('hi')"])
        let registry = PluginRegistry(directory: root.appending(path: "plugins"))

        let installed = try registry.install(from: source)
        #expect(installed.name == "weather")
        #expect(registry.installed().map(\.name) == ["weather"])
        // Copied, not referenced: the folder somebody installed from is
        // usually in Downloads and will not be there next month.
        #expect(installed.directory != source)
        #expect(FileManager.default.fileExists(
            atPath: installed.directory.appending(path: "server.py").path(percentEncoded: false)))

        try registry.uninstall("weather")
        #expect(registry.installed().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: installed.directory.path(percentEncoded: false)))
        // And the source is untouched — uninstall removes what we copied.
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    /// The rule that makes uninstall meaningful. A "plugin" that runs
    /// something elsewhere on the machine is a shortcut to that thing, and
    /// removing the folder would report success while leaving it behind.
    @Test("a package that points outside its own folder is refused")
    func absolutePathsAreRefused() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PluginRegistry(directory: root.appending(path: "plugins"))

        let absolute = try package("""
        {"name": "sneaky", "description": "x", "command": "/bin/sh",
         "arguments": ["-c", "echo hi"]}
        """, in: root, named: "absolute")
        #expect(throws: PluginError.self) { try registry.install(from: absolute) }

        let escaping = try package("""
        {"name": "escaping", "description": "x", "command": "python3",
         "arguments": ["../../elsewhere/server.py"]}
        """, in: root, named: "escaping")
        #expect(throws: PluginError.self) { try registry.install(from: escaping) }

        #expect(registry.installed().isEmpty)
    }

    @Test("a package whose own executable is not in it is refused at install time")
    func missingBundledCommandIsRefused() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package("""
        {"name": "broken", "description": "x", "command": "bin/server"}
        """, in: root, named: "broken")
        let registry = PluginRegistry(directory: root.appending(path: "plugins"))

        #expect(throws: PluginError.self) { try registry.install(from: source) }
        // Named, so the message says which file is missing rather than "failed".
        #expect(PluginError.commandMissing("broken", command: "bin/server")
            .description.contains("bin/server"))
    }

    /// The manifest loader's philosophy (P8.1), applied to plugins: reject the
    /// file where it is wrong, and name the field.
    @Test("a manifest with a missing field is refused with the field in the message")
    func malformedManifestNamesTheField() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package("""
        {"description": "ไม่มีชื่อ", "command": "python3"}
        """, in: root, named: "nameless")
        let registry = PluginRegistry(directory: root.appending(path: "plugins"))

        do {
            try registry.install(from: source)
            Issue.record("ควรถูกปฏิเสธ")
        } catch let error as PluginError {
            #expect(error.description.contains("name"))
        }
    }

    @Test("a folder with no manifest is not a plugin")
    func noManifest() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let registry = PluginRegistry(directory: root.appending(path: "plugins"))

        #expect(throws: PluginError.self) { try registry.install(from: empty) }
    }

    /// Installing over a plugin that is running is not an upgrade — it is two
    /// servers with one name. Refused rather than silently replaced.
    @Test("installing a name that is already installed is refused")
    func duplicateNamesAreRefused() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(validManifest, in: root, named: "first",
                                 files: ["server.py": ""])
        let again = try package(validManifest, in: root, named: "second",
                                files: ["server.py": ""])
        let registry = PluginRegistry(directory: root.appending(path: "plugins"))

        try registry.install(from: source)
        #expect(throws: PluginError.self) { try registry.install(from: again) }
        #expect(registry.installed().count == 1)
    }

    /// One broken package must not empty the registry — the same rule the
    /// manifest loader follows for one broken file.
    @Test("a package that went bad is skipped, and the others still load")
    func oneBadPackageDoesNotHideTheRest() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appending(path: "plugins")
        let registry = PluginRegistry(directory: plugins)
        try registry.install(from: package(validManifest, in: root, named: "good",
                                           files: ["server.py": ""]))
        // Installed correctly, then edited by hand into something invalid.
        try package("{ not json", in: plugins, named: "rotten")

        #expect(registry.installed().map(\.name) == ["weather"])
    }

    /// How a package is launched, which is the only thing the MCP side needs
    /// from this module.
    @Test("an interpreter stays bare and a bundled executable becomes absolute")
    func launchDescription() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PluginRegistry(directory: root.appending(path: "plugins"))

        let interpreted = try registry.install(from: package(
            validManifest, in: root, named: "interpreted", files: ["server.py": ""]))
        // `python3` is resolved on PATH at launch, not here.
        #expect(interpreted.command == "python3")
        #expect(interpreted.arguments == ["server.py"])
        // The package is the working directory, so relative arguments work.
        #expect(interpreted.workingDirectory == interpreted.directory.path(percentEncoded: false))

        let bundled = try registry.install(from: package("""
        {"name": "bundled", "description": "x", "command": "bin/server"}
        """, in: root, named: "bundled", files: ["bin/server": "#!/bin/sh\n"]))
        #expect(bundled.command.hasPrefix(bundled.directory.path(percentEncoded: false)))
        #expect(bundled.command.hasSuffix("bin/server"))
    }

    @Test("uninstalling something that is not installed says so")
    func uninstallingNothing() {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: PluginError.self) {
            try PluginRegistry(directory: root).uninstall("ghost")
        }
    }
}
