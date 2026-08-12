import Testing
import Foundation
import AgentKit
import CoreEngine
import Roster
@testable import MCPBridge

// ─────────────────────────────────────────────────────────────
// P8.4's Done-when: "ติดตั้ง plugin แล้ว tool ใช้ได้ทันที"
// (ARCHITECTURE §7.1, §7.3).
//
// Both halves of that sentence are load-bearing, and each is a way for this to
// be quietly false.
//
//  • **tool ใช้ได้** — the same D6 trap as P8.3, one layer up: a plugin can be
//    installed, listed, connected and still reach no session. So the test
//    calls it through the `ToolGateway`, by the name a model would use.
//  • **ทันที** — no restart. A plugin whose tools appear at the next launch is
//    a plugin whose install button lied, and nobody reads an install button as
//    "later".
//
// The join lives here rather than in either module because Roster may not
// import MCPBridge: `MCPTool` is an `AgentTool`, and the roster is not allowed
// to reach one (the rule in Package.swift, and the same one that keeps a
// channel away from the gateway). So Roster describes a package and this test
// is where "described" meets "running".
// ─────────────────────────────────────────────────────────────

/// A whole plugin: the manifest plus the MCP server it packages.
private let pluginServer = #"""
import json, sys

TOOLS = [{"name": "forecast", "description": "พยากรณ์อากาศ",
          "inputSchema": {"type": "object",
                          "properties": {"city": {"type": "string"}},
                          "required": ["city"]}}]

def handle(method, params):
    if method == "initialize":
        return {"protocolVersion": params.get("protocolVersion", "2025-11-25"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "weather", "version": "1.0.0"}}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        city = (params.get("arguments") or {}).get("city", "")
        return {"content": [{"type": "text", "text": "พรุ่งนี้ที่" + str(city) + " ฝนตก"}],
                "isError": False}
    raise KeyError(method)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    if "id" not in message:
        continue
    try:
        reply = {"jsonrpc": "2.0", "id": message["id"],
                 "result": handle(message["method"], message.get("params") or {})}
    except KeyError as error:
        reply = {"jsonrpc": "2.0", "id": message["id"],
                 "error": {"code": -32601, "message": str(error)}}
    sys.stdout.write(json.dumps(reply) + "\n")
    sys.stdout.flush()
"""#

private func python() -> String? {
    for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
    where FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    return nil
}

private struct AlwaysApproves: ApprovalRequesting {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision { .approved }
}

/// What the app does with an installed plugin: describe it as a server.
/// One mapping, in one place, so both the app and this test use the same one.
private func serverConfig(for plugin: InstalledPlugin) -> MCPServerConfig {
    MCPServerConfig(id: "plugin:\(plugin.id)",
                    name: plugin.name,
                    command: plugin.command,
                    arguments: plugin.arguments,
                    workingDirectory: plugin.workingDirectory,
                    environmentVariables: plugin.environmentVariables)
}

@Suite("Plugins as MCP servers", .serialized)
struct PluginToolTests {

    @Test("installing a plugin puts its tool on the tool list without a restart")
    func installedPluginIsImmediatelyUsable() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let root = FileManager.default.temporaryDirectory
            .appending(path: "coai-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "weather-plugin")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        {"name": "weather", "description": "ดูพยากรณ์อากาศ", "command": "python3",
         "arguments": ["server.py"]}
        """.write(to: source.appending(path: "plugin.json"), atomically: true, encoding: .utf8)
        try pluginServer.write(to: source.appending(path: "server.py"),
                               atomically: true, encoding: .utf8)

        // The session is already running, with its tool list already built.
        let gateway = ToolGateway(approver: AlwaysApproves())
        let mcp = MCPRegistry()
        #expect(await gateway.registeredNames.isEmpty)

        // Install → connect → register. The three steps the install button does.
        let registry = PluginRegistry(directory: root.appending(path: "plugins"))
        let plugin = try registry.install(from: source)
        let tools = try await mcp.connect(serverConfig(for: plugin))
        await gateway.register(tools)

        let names = await gateway.registeredNames
        #expect(names == ["mcp__weather__forecast"])

        let outcome = try await gateway.call("mcp__weather__forecast",
                                             argumentsJSON: #"{"city":"เชียงใหม่"}"#,
                                             context: ToolContext(scope: .central))
        guard case .executed(let output, _, _) = outcome else {
            Issue.record("ไม่ได้รัน: \(outcome)")
            return
        }
        #expect(output.text == "พรุ่งนี้ที่เชียงใหม่ ฝนตก")

        // The server was launched inside its own package, which is what makes
        // a plugin's relative `server.py` argument work.
        #expect(plugin.workingDirectory == plugin.directory.path(percentEncoded: false))

        // And uninstalling takes the tool off the list. A tool whose server is
        // gone must not still be advertised: the next turn would offer a model
        // something that cannot run.
        let removed = await mcp.disconnect(configID: serverConfig(for: plugin).id)
        for name in removed { await gateway.unregister(name) }
        try registry.uninstall(plugin.name)

        #expect(await gateway.registeredNames.isEmpty)
        #expect(await mcp.tools().isEmpty)
        #expect(registry.installed().isEmpty)
    }

    /// A package that cannot start is reported like any other server, and the
    /// tool list is unchanged rather than half-updated.
    @Test("a plugin whose server does not start leaves the tool list alone")
    func brokenPluginChangesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "coai-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "broken-plugin")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        {"name": "broken", "description": "x", "command": "definitely-not-a-command"}
        """.write(to: source.appending(path: "plugin.json"), atomically: true, encoding: .utf8)

        let gateway = ToolGateway()
        let mcp = MCPRegistry()
        let registry = PluginRegistry(directory: root.appending(path: "plugins"))
        // Installing succeeds: a command on PATH is resolved at launch, and
        // the machine that installs a plugin is not always the one that has
        // its interpreter yet.
        let plugin = try registry.install(from: source)

        await #expect(throws: (any Error).self) {
            let tools = try await mcp.connect(serverConfig(for: plugin))
            await gateway.register(tools)
        }
        #expect(await gateway.registeredNames.isEmpty)
        // Reported, not silent.
        let failures = await mcp.failures
        #expect(failures.contains { $0.name == "broken" })
    }
}
