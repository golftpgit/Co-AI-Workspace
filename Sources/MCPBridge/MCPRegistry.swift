import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Every configured server, connected (P8.3).
//
// The rule is the manifest loader's, for the same reason: one server that
// cannot start must not take the others with it, and it must not be silent
// either. A failure is a value with a reason in it that the status screen
// shows — an MCP server that quietly is not there looks exactly like a model
// that has stopped following instructions.
// ─────────────────────────────────────────────────────────────

public actor MCPRegistry {
    public struct Connected: Sendable, Equatable, Identifiable {
        public let configID: String
        public let name: String
        /// What the server calls itself, which is not always what we call it.
        public let serverName: String
        public let serverVersion: String
        public let toolNames: [String]
        public let resourceCount: Int
        public let promptCount: Int
        public var id: String { configID }
    }

    public struct Failure: Sendable, Equatable, Identifiable {
        public let configID: String
        public let name: String
        public let reason: String
        public var id: String { configID }
    }

    private var connections: [String: MCPConnection] = [:]
    private var advertisedTools: [any AgentTool] = []
    private(set) public var connected: [Connected] = []
    private(set) public var failures: [Failure] = []
    /// For the composer's prompt picker (§6.2) — not tools, on purpose.
    private(set) public var prompts: [MCPPrompt] = []
    private let log = AppLog.logger("mcp")

    public init() {}

    /// Connects to everything that is ready and returns what came up. Servers
    /// are started concurrently: a slow one should cost its own handshake, not
    /// everybody else's.
    @discardableResult
    public func connectAll(_ configs: [MCPServerConfig],
                           handshakeTimeout: Duration = .seconds(20)) async
        -> (connected: [Connected], failures: [Failure]) {
        var results: [(MCPServerConfig, Result<MCPConnection, any Error>)] = []
        await withTaskGroup(of: (MCPServerConfig, Result<MCPConnection, any Error>).self) { group in
            for config in configs {
                guard config.isEnabled else { continue }
                guard config.isReady else {
                    let reason = config.blockers.joined(separator: " · ")
                    failures.append(Failure(configID: config.id, name: config.name, reason: reason))
                    continue
                }
                group.addTask {
                    do {
                        return (config, .success(
                            try await MCPConnection.connect(config,
                                                            handshakeTimeout: handshakeTimeout)))
                    } catch {
                        return (config, .failure(error))
                    }
                }
            }
            for await result in group { results.append(result) }
        }

        // Sorted after the fact: the order servers finish handshaking in is
        // not an order anybody chose, and a tool list that reshuffles between
        // boots is a tool list nobody can diff.
        for (config, result) in results.sorted(by: { $0.0.name < $1.0.name }) {
            switch result {
            case .success(let connection):
                await adopt(connection, config: config)
            case .failure(let error):
                let reason = (error as? MCPServerError)?.description ?? "\(error)"
                log.error("MCP '\(config.name, privacy: .public)' — \(reason, privacy: .public)")
                failures.append(Failure(configID: config.id, name: config.name, reason: reason))
            }
        }
        return (connected, failures)
    }

    /// Connects one server after boot and returns the tools it brought, so the
    /// caller can register them in the live gateway.
    ///
    /// This is P8.4's "ติดตั้งแล้วใช้ได้ทันที" in one method: a plugin that
    /// needs a restart to become usable is a plugin whose install button lies.
    public func connect(_ config: MCPServerConfig,
                        handshakeTimeout: Duration = .seconds(20)) async throws
        -> [any AgentTool] {
        if connections[config.id] != nil { await disconnect(configID: config.id) }
        failures.removeAll { $0.configID == config.id }
        guard config.isReady else {
            let reason = config.blockers.joined(separator: " · ")
            failures.append(Failure(configID: config.id, name: config.name, reason: reason))
            throw MCPServerError.notConnected(reason)
        }
        let before = advertisedTools.count
        do {
            let connection = try await MCPConnection.connect(config,
                                                             handshakeTimeout: handshakeTimeout)
            await adopt(connection, config: config)
        } catch {
            // Recorded here as well as in `connectAll`, and not only rethrown:
            // the status screen reads `failures`, and a server that failed
            // after boot would otherwise be a tool list that is silently
            // shorter than the one the roster was validated against.
            let reason = (error as? MCPServerError)?.description ?? "\(error)"
            log.error("MCP '\(config.name, privacy: .public)' — \(reason, privacy: .public)")
            failures.append(Failure(configID: config.id, name: config.name, reason: reason))
            throw error
        }
        return Array(advertisedTools.dropFirst(before))
    }

    /// Stops one server and forgets what it offered. The names are returned
    /// because the gateway is the thing that has to be told: a tool whose
    /// server is gone must leave the tool list, or the next turn advertises a
    /// tool that cannot run.
    @discardableResult
    public func disconnect(configID: String) async -> [String] {
        guard let connection = connections.removeValue(forKey: configID) else { return [] }
        await connection.disconnect()
        let entry = connected.first { $0.configID == configID }
        let names = entry?.toolNames ?? []
        advertisedTools.removeAll { names.contains($0.name) }
        connected.removeAll { $0.configID == configID }
        failures.removeAll { $0.configID == configID }
        if let name = entry?.name { prompts.removeAll { $0.server == name } }
        return names
    }

    private func adopt(_ connection: MCPConnection, config: MCPServerConfig) async {
        let namespace = config.namespace
        let serverName = await connection.serverName
        let tools = await connection.tools
        let resources = await connection.resources
        let prompts = await connection.prompts

        var made: [any AgentTool] = tools.map {
            MCPTool(tool: $0, connection: connection, namespace: namespace, serverName: serverName)
        }
        if !resources.isEmpty {
            made.append(MCPResourceTool(connection: connection, namespace: namespace,
                                        serverName: serverName, resources: resources))
        }

        connections[config.id] = connection
        advertisedTools.append(contentsOf: made)
        self.prompts.append(contentsOf: prompts)
        connected.append(Connected(configID: config.id,
                                   name: config.name,
                                   serverName: serverName,
                                   serverVersion: await connection.serverVersion,
                                   toolNames: made.map(\.name),
                                   resourceCount: resources.count,
                                   promptCount: prompts.count))
    }

    /// What goes on the tool list. The app registers these in the one
    /// `ToolGateway`; nothing here can call anything itself.
    public func tools() -> [any AgentTool] { advertisedTools }

    /// Renders a prompt, for the composer. Routed by the server the prompt
    /// came from rather than to whichever connection answers first.
    public func renderPrompt(_ prompt: MCPPrompt,
                             arguments: [String: String] = [:]) async throws -> String {
        for candidate in connections.values where candidate.config.name == prompt.server {
            return try await candidate.prompt(prompt.name, arguments: arguments)
        }
        throw MCPServerError.notConnected(prompt.server)
    }

    public func shutdown() async {
        for connection in connections.values { await connection.disconnect() }
        connections.removeAll()
        advertisedTools.removeAll()
        connected.removeAll()
        prompts.removeAll()
    }
}
