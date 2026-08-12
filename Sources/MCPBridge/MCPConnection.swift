import Foundation
import System
import AgentKit
import Execution
import Observability
import MCP

// ─────────────────────────────────────────────────────────────
// One MCP server, connected (ARCHITECTURE §6.2, P8.3).
//
// The JSON-RPC is the official Swift SDK's — v1 wrote and maintained that
// client itself, and there is nothing in it worth owning. What is ours is the
// two ends the SDK deliberately leaves open:
//
//  • **The process.** `StdioTransport` takes file descriptors and does not
//    spawn anything, which is correct of it: spawning is §13's business, and a
//    server started outside `Spawn` would be a child in our own process group
//    that the Stop button cannot reach.
//  • **The handshake having a deadline.** `initialize` on a server that never
//    answers is a boot that never finishes. Two ways to get this wrong were
//    worth avoiding: hanging forever, and reporting "no response" while the
//    server's actual explanation sits unread on its stderr.
//
// All three primitives are here (§6.2): `tools/*` and `resources/*` become
// agent tools, `prompts/*` does not — a prompt is something a person picks in
// the composer, and turning it into a tool would let a model invoke a template
// meant for a human.
// ─────────────────────────────────────────────────────────────

public struct MCPPrompt: Sendable, Equatable, Identifiable {
    public let server: String
    public let name: String
    public let description: String?
    public let arguments: [String]
    public var id: String { "\(server)/\(name)" }
}

public struct MCPResourceInfo: Sendable, Equatable {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?
}

public actor MCPConnection {
    public let config: MCPServerConfig
    private let child: PipedChild
    private let client: Client
    private let transport: StdioTransport
    private let log = AppLog.logger("mcp")

    public private(set) var serverName: String
    public private(set) var serverVersion: String
    public private(set) var instructions: String?
    public private(set) var tools: [Tool] = []
    public private(set) var resources: [MCPResourceInfo] = []
    public private(set) var prompts: [MCPPrompt] = []
    private var live = true

    private init(config: MCPServerConfig, child: PipedChild,
                 client: Client, transport: StdioTransport,
                 handshake: Initialize.Result) {
        self.config = config
        self.child = child
        self.client = client
        self.transport = transport
        self.serverName = handshake.serverInfo.name
        self.serverVersion = handshake.serverInfo.version
        self.instructions = handshake.instructions
    }

    public var isLive: Bool { live && child.isRunning }

    /// Launches the server and completes the handshake, or throws with a
    /// reason someone can act on.
    public static func connect(_ config: MCPServerConfig,
                               handshakeTimeout: Duration = .seconds(20)) async throws
        -> MCPConnection {
        let executable = try CommandLookup.resolve(config.command)
        let child = try PipedChild(
            executable: executable,
            arguments: config.arguments,
            workingDirectory: config.workingDirectory.map { URL(fileURLWithPath: $0) },
            environmentOverrides: config.resolvedEnvironment())

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: child.outputDescriptor),
            output: FileDescriptor(rawValue: child.inputDescriptor))
        let client = Client(name: "Co-AI Workspace", version: "2.0")

        let seconds = Int(handshakeTimeout.components.seconds)
        let handshake: Initialize.Result
        do {
            handshake = try await withDeadline(
                handshakeTimeout,
                // The server exiting is the other way this ends, and it is
                // knowable the moment it happens.
                abortWhen: { await child.waitForExit() },
                stop: {
                    // Not decoration — this is what makes a watchdog work at
                    // all. A client waiting on `initialize` is suspended on a
                    // continuation that only ever resumes when the server
                    // answers, and cancellation does not reach it.
                    // `disconnect` resumes the pending request with an error,
                    // which is what lets the handshake unwind instead of being
                    // waited on forever.
                    await client.disconnect()
                }) {
                    try await client.connect(transport: transport)
                }
        } catch is DeadlineExceeded {
            await transport.disconnect()
            child.terminate()
            throw MCPServerError.handshakeTimedOut(seconds: seconds,
                                                   stderr: child.standardErrorText())
        } catch is ServerExited {
            await transport.disconnect()
            child.terminate()
            throw MCPServerError.handshakeFailed("เซิร์ฟเวอร์ปิดตัวลงก่อนตอบ initialize",
                                                 stderr: child.standardErrorText())
        } catch {
            await transport.disconnect()
            child.terminate()
            throw MCPServerError.handshakeFailed("\(error)", stderr: child.standardErrorText())
        }

        let connection = MCPConnection(config: config, child: child,
                                       client: client, transport: transport,
                                       handshake: handshake)
        // What the server offers, asked for once at connect time. A server may
        // announce changes later (`listChanged`); until P8.4 needs it, a
        // reconnect is how the list is refreshed.
        await connection.discover(capabilities: handshake.capabilities)
        return connection
    }

    private func discover(capabilities: Server.Capabilities) async {
        if capabilities.tools != nil {
            do { tools = try await client.listTools().tools } catch {
                log.error("\(self.config.name, privacy: .public): tools/list failed — \(error)")
            }
        }
        if capabilities.resources != nil {
            do {
                resources = try await client.listResources().resources.map {
                    MCPResourceInfo(uri: $0.uri, name: $0.name,
                                    description: $0.description, mimeType: $0.mimeType)
                }
            } catch {
                log.error("\(self.config.name, privacy: .public): resources/list failed — \(error)")
            }
        }
        if capabilities.prompts != nil {
            do {
                prompts = try await client.listPrompts().prompts.map { prompt in
                    MCPPrompt(server: self.config.name, name: prompt.name,
                              description: prompt.description,
                              arguments: (prompt.arguments ?? []).map(\.name))
                }
            } catch {
                log.error("\(self.config.name, privacy: .public): prompts/list failed — \(error)")
            }
        }
    }

    // MARK: - using it

    /// Calls a tool by its *server-side* name and returns its content as text.
    ///
    /// `isError` is turned into a thrown error rather than returned as prose:
    /// the gateway records a failed tool call as failed, and a server error
    /// that arrives as ordinary output is a span that says the call succeeded.
    public func callTool(_ name: String, arguments: [String: Value]) async throws -> String {
        guard isLive else { throw MCPServerError.notConnected(config.name) }
        let result: (content: [Tool.Content], isError: Bool?)
        do {
            result = try await client.callTool(name: name, arguments: arguments)
        } catch {
            throw MCPServerError.callFailed("\(error)")
        }
        let text = Self.flatten(result.content)
        if result.isError == true {
            throw MCPServerError.callFailed(text.isEmpty ? "เซิร์ฟเวอร์แจ้งว่าเรียกไม่สำเร็จ" : text)
        }
        return text
    }

    public func readResource(uri: String) async throws -> String {
        guard isLive else { throw MCPServerError.notConnected(config.name) }
        do {
            let contents = try await client.readResource(uri: uri)
            return contents.map { content in
                if let text = content.text { return text }
                let size = content.blob.map { "\($0.count) ไบต์ (base64)" } ?? "ไม่มีเนื้อหา"
                return "[\(content.mimeType ?? "binary") — \(size)]"
            }.joined(separator: "\n\n")
        } catch {
            throw MCPServerError.callFailed("\(error)")
        }
    }

    /// A prompt, rendered. For the composer — never reachable from a tool call.
    public func prompt(_ name: String, arguments: [String: String]) async throws -> String {
        guard isLive else { throw MCPServerError.notConnected(config.name) }
        do {
            let result = try await client.getPrompt(name: name, arguments: arguments)
            return result.messages.map { message in
                switch message.content {
                case .text(let text): return text
                default: return ""
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        } catch {
            throw MCPServerError.callFailed("\(error)")
        }
    }

    /// Stops the reader first, then the process — the order `PipedChild`
    /// requires, and the reason this is the only place that calls `terminate`.
    public func disconnect() async {
        guard live else { return }
        live = false
        await client.disconnect()
        await transport.disconnect()
        child.terminate()
    }

    public func standardErrorText() -> String { child.standardErrorText() }

    private static func flatten(_ content: [Tool.Content]) -> String {
        content.compactMap { piece -> String? in
            switch piece {
            case .text(let text, _, _):
                return text
            case .image(_, let mimeType, _, _):
                return "[รูปภาพ \(mimeType)]"
            case .audio(_, let mimeType, _, _):
                return "[เสียง \(mimeType)]"
            case .resource(let resource, _, _):
                return resource.text ?? "[resource \(resource.uri)]"
            case .resourceLink(let uri, let name, _, _, _, _):
                return "[\(name) — \(uri)]"
            }
        }.joined(separator: "\n")
    }
}

// MARK: - deadlines

struct DeadlineExceeded: Error {}
/// The server is not slow; it is gone.
struct ServerExited: Error {}

/// Why the operation was stopped, if it was.
///
/// Needed because stopping it means breaking it on purpose, so the operation's
/// own failure and the watchdog race each other to the caller — and under load
/// the loser reports first. Without this, the same timeout is "handshake
/// failed: client disconnected" on a busy machine and "no response in 20s" on
/// an idle one.
private final class StopReason: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: (any Error)?
    /// First writer wins: whichever watchdog noticed first is the true cause.
    func set(_ error: any Error) { lock.withLock { if reason == nil { reason = error } } }
    var value: (any Error)? { lock.withLock { reason } }
}

/// Races an operation against the two ways a handshake fails to arrive.
///
/// **`stop` is not a convenience.** A task group does not return until every
/// child has finished, and `cancelAll` only *asks* — an operation suspended on
/// a continuation nobody will resume ignores it, and the watchdog becomes the
/// same hang it was meant to prevent. So a watchdog gets to do the one thing
/// that will actually free the operation, and only then throws.
///
/// **`abortWhen` exists because a timer is the wrong instrument for half the
/// problem.** A server that says nothing keeps its pipe open and there is
/// nothing to notice but the passage of time. A server that has *exited* is a
/// fact available immediately — and waiting out a 20-second timer to discover
/// it is 20 seconds of an install button doing nothing visible. Found by
/// installing a plugin in the real app, not by a test: the test suite only had
/// the server that stays alive and stays quiet.
func withDeadline<T: Sendable>(_ duration: Duration,
                               abortWhen: (@Sendable () async -> Void)? = nil,
                               stop: @escaping @Sendable () async -> Void = {},
                               _ operation: @escaping @Sendable () async throws -> T)
    async throws -> T {
    let stopped = StopReason()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            stopped.set(DeadlineExceeded())
            await stop()
            throw DeadlineExceeded()
        }
        if let abortWhen {
            group.addTask {
                await abortWhen()
                try Task.checkCancellation()
                stopped.set(ServerExited())
                await stop()
                throw ServerExited()
            }
        }
        defer { group.cancelAll() }
        do {
            guard let first = try await group.next() else { throw DeadlineExceeded() }
            return first
        } catch {
            // Success still wins — it is returned above. But once a watchdog
            // has fired, every failure downstream of it is that watchdog's.
            throw stopped.value ?? error
        }
    }
}
