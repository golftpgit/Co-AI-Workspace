import Testing
import Foundation
import AgentKit
import CoreEngine
@testable import MCPBridge

// ─────────────────────────────────────────────────────────────
// P8.3's Done-when, which is not "the client works" (ARCHITECTURE §6.2, v1 D6).
//
// v1 shipped a complete, working MCP client that no session could ever reach,
// because nothing put its tools on the tool list. The lesson written down in
// the plan is that an implementation is not a feature — so the test below that
// matters is the one that connects a real server, registers what it offers in
// a real `ToolGateway`, and then calls it *through the gate* by the name a
// model would use.
//
// The server on the other end is a real one and deliberately not ours: a
// Python script speaking the wire protocol. Talking to a server written with
// the same SDK would prove the SDK agrees with itself. This proves the bytes
// are right, and it exercises the part that is ours — spawning, the working
// directory, the handshake deadline, and what happens to a server that never
// answers.
// ─────────────────────────────────────────────────────────────

/// A server that answers the three primitives, plus the two failure shapes
/// worth having: a tool that reports an error, and `where`, which returns the
/// directory it was launched in.
private let probeServerSource = #"""
import json, os, sys

TOOLS = [
    {"name": "echo", "description": "คืนข้อความเดิม",
     "inputSchema": {"type": "object",
                     "properties": {"text": {"type": "string"}},
                     "required": ["text"]}},
    {"name": "where", "description": "คืนโฟลเดอร์ที่เซิร์ฟเวอร์ถูกรัน",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "explode", "description": "ล้มเหลวเสมอ",
     "inputSchema": {"type": "object", "properties": {}}},
]

RESOURCES = [
    {"uri": "note://one", "name": "บันทึกแรก",
     "description": "ตัวอย่าง", "mimeType": "text/plain"},
]

PROMPTS = [
    {"name": "summarise", "description": "สรุปหัวข้อ",
     "arguments": [{"name": "topic", "required": True}]},
]


def text(value):
    return {"content": [{"type": "text", "text": value}], "isError": False}


def handle(method, params):
    if method == "initialize":
        return {"protocolVersion": params.get("protocolVersion", "2025-11-25"),
                "capabilities": {"tools": {}, "resources": {}, "prompts": {}},
                "serverInfo": {"name": "probe", "version": "0.1.0"},
                "instructions": "เซิร์ฟเวอร์ทดสอบ"}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name == "echo":
            return text("echo: " + str(arguments.get("text", "")))
        if name == "where":
            return text(os.getcwd())
        if name == "explode":
            return {"content": [{"type": "text", "text": "ระเบิด"}], "isError": True}
        return {"content": [{"type": "text", "text": "ไม่รู้จักเครื่องมือ"}], "isError": True}
    if method == "resources/list":
        return {"resources": RESOURCES}
    if method == "resources/read":
        return {"contents": [{"uri": params.get("uri"), "mimeType": "text/plain",
                              "text": "เนื้อหาของบันทึกแรก"}]}
    if method == "prompts/list":
        return {"prompts": PROMPTS}
    if method == "prompts/get":
        topic = (params.get("arguments") or {}).get("topic", "")
        return {"description": "สรุปหัวข้อ",
                "messages": [{"role": "user",
                              "content": {"type": "text", "text": "ช่วยสรุป " + topic}}]}
    raise KeyError(method)


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    if "id" not in message:          # a notification: nothing goes back
        continue
    try:
        result = handle(message["method"], message.get("params") or {})
        reply = {"jsonrpc": "2.0", "id": message["id"], "result": result}
    except KeyError as error:
        reply = {"jsonrpc": "2.0", "id": message["id"],
                 "error": {"code": -32601, "message": "ไม่มีเมท็อด " + str(error)}}
    sys.stdout.write(json.dumps(reply) + "\n")
    sys.stdout.flush()
"""#

/// Never answers, and says why on stderr — the shape a misconfigured server
/// actually has.
private let muteServerSource = #"""
import sys, time
sys.stderr.write("ต้องตั้งค่า API key ก่อน\n")
sys.stderr.flush()
time.sleep(600)
"""#

private struct Fixture {
    let directory: URL
    let script: URL
}

private func writeServer(_ source: String, named name: String) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "coai-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appending(path: name)
    try source.write(to: script, atomically: true, encoding: .utf8)
    return Fixture(directory: directory, script: script)
}

private func python() -> String? {
    for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
    where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return nil
}

private func probeConfig(_ fixture: Fixture, name: String = "probe",
                         workingDirectory: URL? = nil) -> MCPServerConfig {
    MCPServerConfig(name: name,
                    command: python() ?? "/usr/bin/python3",
                    arguments: [fixture.script.path(percentEncoded: false)],
                    workingDirectory: (workingDirectory ?? fixture.directory)
                        .path(percentEncoded: false))
}

private struct AlwaysApproves: ApprovalRequesting {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision { .approved }
}

private func context() -> ToolContext {
    ToolContext(scope: .central, workingDirectory: nil, conversationID: "c1", role: nil)
}

@Suite("MCP client", .serialized)
struct MCPBridgeTests {

    /// **The Done-when.** Not "the client can list tools" — the tool is on the
    /// session's tool list, under the name a model would call it by, and it
    /// runs when called through the gate.
    @Test("an MCP tool reaches a real session's tool list and runs through the gate")
    func mcpToolIsOnTheToolList() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(probeServerSource, named: "probe_server.py")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let registry = MCPRegistry()
        let outcome = await registry.connectAll([probeConfig(fixture)])
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.reason))")
        #expect(outcome.connected.count == 1)
        #expect(outcome.connected.first?.serverName == "probe")

        // The step v1 never took.
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(registry.tools())

        let names = await gateway.registeredNames
        #expect(names.contains("mcp__probe__echo"))
        #expect(names.contains("mcp__probe__where"))
        #expect(names.contains("mcp__probe__read_resource"))

        // And it is on the list a model is *shown*, with the server's own
        // schema on it, not a placeholder.
        let adverts = await gateway.adverts
        let echo = try #require(adverts.first { $0.name == "mcp__probe__echo" })
        #expect(echo.parametersJSON.contains("\"text\""))
        #expect(echo.description.contains("probe"))

        let outcomeOfCall = try await gateway.call("mcp__probe__echo",
                                                   argumentsJSON: #"{"text":"สวัสดี"}"#,
                                                   context: context())
        guard case .executed(let output, _, _) = outcomeOfCall else {
            Issue.record("ไม่ได้รัน: \(outcomeOfCall)")
            return
        }
        #expect(output.text == "echo: สวัสดี")
        await registry.shutdown()
    }

    /// The plan's "stdio cwd", asked of the server itself rather than of our
    /// own configuration: many servers take their root from the directory they
    /// were launched in, so one launched in the wrong place serves the wrong
    /// project and says nothing about it.
    @Test("the server is launched in the configured working directory")
    func workingDirectoryIsApplied() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(probeServerSource, named: "probe_server.py")
        let elsewhere = fixture.directory.appending(path: "โฟลเดอร์งาน")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let registry = MCPRegistry()
        await registry.connectAll([probeConfig(fixture, workingDirectory: elsewhere)])
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(registry.tools())

        let outcome = try await gateway.call("mcp__probe__where",
                                             argumentsJSON: "{}", context: context())
        guard case .executed(let output, _, _) = outcome else {
            Issue.record("ไม่ได้รัน: \(outcome)")
            return
        }
        // Compared by resolved path: /var is a symlink to /private/var, and
        // the server reports where it actually is.
        #expect(URL(fileURLWithPath: output.text).resolvingSymlinksInPath()
                == elsewhere.resolvingSymlinksInPath())
        await registry.shutdown()
    }

    /// §5.3 and P8.2's rule, applied to code we did not write: an MCP tool is
    /// High, and High needs a human. No approval channel is a denial, not a
    /// default to running.
    @Test("an MCP tool is high risk and cannot run without approval")
    func mcpToolsAreGated() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(probeServerSource, named: "probe_server.py")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let registry = MCPRegistry()
        await registry.connectAll([probeConfig(fixture)])
        let gateway = ToolGateway(approver: nil, modes: OperatingModes(autonomy: .balanced))
        await gateway.register(registry.tools())

        let adverts = await gateway.adverts
        #expect(adverts.first { $0.name == "mcp__probe__echo" }?.declaredRisk == .high)

        let outcome = try await gateway.call("mcp__probe__echo",
                                             argumentsJSON: #"{"text":"hi"}"#,
                                             context: context())
        if case .denied = outcome {} else {
            Issue.record("เครื่องมือ MCP ผ่านโดยไม่ต้องอนุมัติ: \(outcome)")
        }
        await registry.shutdown()
    }

    /// `resources/*` is the second primitive, and it arrives as one tool per
    /// server rather than one per resource.
    @Test("resources are readable as a tool, and the resource list is in its description")
    func resourcesBecomeATool() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(probeServerSource, named: "probe_server.py")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let registry = MCPRegistry()
        await registry.connectAll([probeConfig(fixture)])
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(registry.tools())

        let adverts = await gateway.adverts
        let reader = try #require(adverts.first { $0.name == "mcp__probe__read_resource" })
        #expect(reader.description.contains("note://one"))

        let outcome = try await gateway.call("mcp__probe__read_resource",
                                             argumentsJSON: #"{"uri":"note://one"}"#,
                                             context: context())
        guard case .executed(let output, _, _) = outcome else {
            Issue.record("ไม่ได้รัน: \(outcome)")
            return
        }
        #expect(output.text == "เนื้อหาของบันทึกแรก")
        #expect(output.artifacts == ["note://one"])
        await registry.shutdown()
    }

    /// §6.2's third primitive, and the one that must *not* become a tool: a
    /// prompt is something a person picks in the composer. A model that could
    /// invoke it would be reaching for the user's half of the interface.
    @Test("prompts are offered to the composer and are not on the tool list")
    func promptsAreNotTools() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(probeServerSource, named: "probe_server.py")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let registry = MCPRegistry()
        await registry.connectAll([probeConfig(fixture)])
        let gateway = ToolGateway()
        await gateway.register(registry.tools())

        let names = await gateway.registeredNames
        #expect(!names.contains { $0.contains("summarise") })

        let prompts = await registry.prompts
        let summarise = try #require(prompts.first { $0.name == "summarise" })
        #expect(summarise.server == "probe")
        #expect(summarise.arguments == ["topic"])

        let rendered = try await registry.renderPrompt(summarise, arguments: ["topic": "เมตฟอร์มิน"])
        #expect(rendered == "ช่วยสรุป เมตฟอร์มิน")
        await registry.shutdown()
    }

    /// A tool that reports failure fails. Returning the server's error text as
    /// ordinary output would record a span that says the call succeeded.
    @Test("a tool that answers isError is a failed call, not output")
    func toolErrorsAreErrors() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(probeServerSource, named: "probe_server.py")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let registry = MCPRegistry()
        await registry.connectAll([probeConfig(fixture)])
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(registry.tools())

        await #expect(throws: ToolError.self) {
            try await gateway.call("mcp__probe__explode", argumentsJSON: "{}", context: context())
        }
        await registry.shutdown()
    }

    /// The manifest loader's rule (P8.1), applied here: one server that cannot
    /// start must not take the others with it, and it must not be silent.
    @Test("a server that cannot start is reported, and the others still connect")
    func oneBadServerDoesNotTakeTheRest() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(probeServerSource, named: "probe_server.py")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let missing = MCPServerConfig(name: "ghost", command: "definitely-not-a-real-command")
        let registry = MCPRegistry()
        let outcome = await registry.connectAll([missing, probeConfig(fixture)])

        #expect(outcome.connected.map(\.name) == ["probe"])
        let failure = try #require(outcome.failures.first { $0.name == "ghost" })
        #expect(failure.reason.contains("definitely-not-a-real-command"))
        // The one that did come up is on the tool list regardless.
        let live = await registry.tools()
        #expect(live.contains { $0.name == "mcp__probe__echo" })
        await registry.shutdown()
    }

    /// A server that never finishes the handshake must not be a boot that
    /// never finishes — and the reason it gives on stderr is the only useful
    /// thing about the failure, so it is carried into the error.
    @Test("a server that never answers times out, and its stderr is in the reason")
    func handshakeHasADeadline() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(muteServerSource, named: "mute_server.py")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let registry = MCPRegistry()
        let outcome = await registry.connectAll([probeConfig(fixture, name: "mute")],
                                                handshakeTimeout: .seconds(2))
        #expect(outcome.connected.isEmpty)
        let failure = try #require(outcome.failures.first)
        #expect(failure.reason.contains("ไม่ตอบ initialize"))
        #expect(failure.reason.contains("ต้องตั้งค่า API key ก่อน"))
    }

    /// §13 — nothing we start outlives us. A shut-down registry leaves no
    /// server process behind.
    @Test("shutdown stops the server process")
    func shutdownStopsTheProcess() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(probeServerSource, named: "probe_server.py")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let registry = MCPRegistry()
        await registry.connectAll([probeConfig(fixture)])
        let running = await runningPIDs(of: fixture.script.path(percentEncoded: false))
        #expect(running.count == 1)

        await registry.shutdown()
        // SIGTERM first, SIGKILL two seconds later; either way it is gone.
        var remaining = await runningPIDs(of: fixture.script.path(percentEncoded: false))
        for _ in 0..<40 where !remaining.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            remaining = await runningPIDs(of: fixture.script.path(percentEncoded: false))
        }
        #expect(remaining.isEmpty)
        let left = await registry.tools()
        #expect(left.isEmpty)
    }

    /// Names are what a manifest has to reference (P8.1), so they are checked
    /// on their own rather than only observed in passing.
    @Test("a server name that cannot be a tool name is made into one")
    func namespacesAreSanitised() {
        #expect(MCPServerConfig(name: "งานวิจัย", command: "x").namespace == "server")
        #expect(MCPServerConfig(name: "git hub", command: "x").namespace == "git_hub")
        #expect(MCPServerConfig(name: "fs-2", command: "x").namespace == "fs-2")
        #expect(MCPToolNaming.toolName(namespace: "fs-2", tool: "read file")
                == "mcp__fs-2__read_file")
    }

    /// A config whose secret is not set does not launch, and says which
    /// variable is missing — the same shape as a channel account (§8.2).
    @Test("a server whose environment variable is unset is blocked, with the name in the reason")
    func missingSecretIsABlocker() async {
        let config = MCPServerConfig(name: "paid", command: "/bin/echo",
                                     environmentVariables: ["API_KEY": "COAI_TEST_MISSING_KEY"])
        #expect(!config.isReady)
        #expect(config.blockers.contains { $0.contains("COAI_TEST_MISSING_KEY") })

        let registry = MCPRegistry()
        let outcome = await registry.connectAll([config])
        #expect(outcome.connected.isEmpty)
        #expect(outcome.failures.first?.reason.contains("COAI_TEST_MISSING_KEY") == true)
    }
}

/// PIDs of processes whose command line mentions this script. `pgrep -f`
/// rather than our own bookkeeping: the question is whether the *operating
/// system* still has it, which is not something our records can answer.
private func runningPIDs(of scriptPath: String) async -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", scriptPath]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n").map(String.init)
}

/// Exits the moment it starts, the way a server with a missing dependency
/// does. Found in the app, not here: the first plugin installed through the
/// real UI hung the install instead of failing it.
private let deadOnArrivalServer = #"""
import sys
sys.stderr.write("ModuleNotFoundError: no module named 'mcp'\n")
sys.exit(1)
"""#

@Suite("MCP client — a server that dies", .serialized)
struct MCPDeadServerTests {

    /// The case the deadline test did not cover. A server that never *answers*
    /// keeps its pipe open, so the client sits on a continuation and the timer
    /// wins. A server that **exits** closes the pipe: the read loop finishes,
    /// the pending `initialize` is never resumed, and the timeout's own
    /// cleanup — `client.disconnect()`, which awaits that loop — is where it
    /// hung. Silent, and indistinguishable from a slow install.
    @Test("a server that exits immediately fails the connection instead of hanging")
    func deadServerDoesNotHang() async throws {
        try #require(python() != nil, "ต้องมี python3 บนเครื่อง")
        let fixture = try writeServer(deadOnArrivalServer, named: "dead_server.py")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let registry = MCPRegistry()
        let started = ContinuousClock.now
        let outcome = await registry.connectAll([probeConfig(fixture, name: "dead")],
                                                handshakeTimeout: .seconds(30))

        // Well inside the 30s deadline: the point is that it notices the
        // server is gone rather than waiting for a timer that then hangs.
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(outcome.connected.isEmpty)
        let failure = try #require(outcome.failures.first)
        // And it says what the server said on its way out, which is the only
        // useful thing about this failure.
        #expect(failure.reason.contains("ModuleNotFoundError"))
    }
}
