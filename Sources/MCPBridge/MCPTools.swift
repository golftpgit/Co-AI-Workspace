import Foundation
import AgentKit
import MCP

// ─────────────────────────────────────────────────────────────
// MCP, as tools (ARCHITECTURE §6.2, §5.3, P8.3 / v1 bug D6).
//
// D6 was an MCP client that worked and that no session could reach, because
// nothing ever put its tools on the tool list. So the type that matters in
// this file is the smallest one: an `AgentTool` that a server's tool becomes,
// which the app registers in the same `ToolGateway` as `run_shell`. From
// CoreEngine's side there is nothing to know — that is the point of §6.2's one
// uniform shape.
//
// **Every MCP tool declares High, and none of them may say otherwise.** A
// server's `readOnlyHint` is a claim by code we did not write and cannot read;
// honouring it would be the same mistake P8.2 rejected in manifests, where a
// file that grades its own risk is refused rather than believed. It costs
// nothing either way: §5.3's scorer has no baseline for a name it has never
// seen and returns High regardless — so declaring anything lower would only
// put a number in the UI that the gate does not act on.
// ─────────────────────────────────────────────────────────────

/// Namespacing. Two servers may both offer `search`, and a server may offer
/// `run_shell`; the prefix is what keeps either from quietly shadowing
/// something. It is also what a manifest's `tools:` list has to name (P8.1),
/// so it has to be stable and typeable.
public enum MCPToolNaming {
    public static func toolName(namespace: String, tool: String) -> String {
        "mcp__\(namespace)__\(sanitised(tool))"
    }

    public static func resourceToolName(namespace: String) -> String {
        "mcp__\(namespace)__read_resource"
    }

    static func sanitised(_ name: String) -> String {
        String(name.map {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_"
        })
    }
}

public struct MCPTool: AgentTool {
    public let name: String
    public let toolDescription: String
    public let parametersJSON: String
    /// See the note above: not negotiable, and not derived from anything the
    /// server said about itself.
    public let riskLevel: RiskLevel = .high

    /// The name on the server, which is not the name we advertise.
    private let remoteName: String
    private let connection: MCPConnection

    public init(tool: Tool, connection: MCPConnection, namespace: String, serverName: String) {
        self.name = MCPToolNaming.toolName(namespace: namespace, tool: tool.name)
        self.remoteName = tool.name
        self.connection = connection
        self.toolDescription = Self.describe(tool, serverName: serverName)
        self.parametersJSON = Self.schema(tool.inputSchema)
    }

    /// Refuses what can be known without a round trip: arguments that are not
    /// a JSON object, and a server that has gone away. Both would otherwise
    /// become an approval prompt for a call that cannot run (§5.3).
    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Self.arguments(from: argumentsJSON)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let arguments = try Self.arguments(from: argumentsJSON)
        guard await connection.isLive else {
            throw ToolError.executionFailed(MCPServerError.notConnected(remoteName).description)
        }
        do {
            let text = try await connection.callTool(remoteName, arguments: arguments)
            return ToolOutput(text: text.isEmpty ? "(เซิร์ฟเวอร์ตอบกลับโดยไม่มีเนื้อหา)" : text)
        } catch let error as MCPServerError {
            throw ToolError.executionFailed(error.description)
        }
    }

    static func arguments(from json: String) throws -> [String: Value] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: Value].self,
                                                      from: Data(trimmed.utf8)) else {
            throw ToolError.invalidArguments("อาร์กิวเมนต์ต้องเป็น JSON object")
        }
        return decoded
    }

    private static func describe(_ tool: Tool, serverName: String) -> String {
        let body = tool.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (body?.isEmpty == false ? body! : tool.title ?? tool.name)
        return "\(text)\n(เครื่องมือจาก MCP server '\(serverName)')"
    }

    /// The server's schema, verbatim where possible. A server that sends
    /// something that is not an object schema gets an empty one rather than a
    /// malformed tool definition that makes the endpoint reject the whole list.
    static func schema(_ value: Value) -> String {
        guard case .object = value,
              let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"type":"object","properties":{}}"#
        }
        return text
    }
}

/// `resources/*`, as one tool per server (§6.2). One rather than one per
/// resource: a server can expose thousands, and a tool list is something a
/// model reads in full on every turn.
public struct MCPResourceTool: AgentTool {
    public let name: String
    public let toolDescription: String
    public let riskLevel: RiskLevel = .high
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "uri": { "type": "string", "description": "URI ของ resource ที่จะอ่าน" }
      },
      "required": ["uri"]
    }
    """

    private let connection: MCPConnection

    public init(connection: MCPConnection, namespace: String, serverName: String,
                resources: [MCPResourceInfo]) {
        self.name = MCPToolNaming.resourceToolName(namespace: namespace)
        self.connection = connection
        // The list goes in the description because that is the only place a
        // model will see it. Capped: a description is spent context on every
        // turn, and a server with a thousand files must not eat the window.
        let shown = resources.prefix(30).map { resource in
            let label = resource.description.map { " — \($0)" } ?? ""
            return "• \(resource.uri) (\(resource.name))\(label)"
        }
        let more = resources.count > 30 ? "\n…และอีก \(resources.count - 30) รายการ" : ""
        self.toolDescription = """
        อ่านเนื้อหาของ resource จาก MCP server '\(serverName)'
        resource ที่มี:
        \(shown.joined(separator: "\n"))\(more)
        """
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Self.uri(from: argumentsJSON)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let uri = try Self.uri(from: argumentsJSON)
        do {
            let text = try await connection.readResource(uri: uri)
            return ToolOutput(text: text.isEmpty ? "(resource ว่าง)" : text, artifacts: [uri])
        } catch let error as MCPServerError {
            throw ToolError.executionFailed(error.description)
        }
    }

    private static func uri(from json: String) throws -> String {
        let arguments = try MCPTool.arguments(from: json)
        guard case .string(let uri)? = arguments["uri"], !uri.isEmpty else {
            throw ToolError.invalidArguments("ต้องระบุ 'uri' ของ resource")
        }
        return uri
    }
}
