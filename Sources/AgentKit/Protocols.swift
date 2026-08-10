import Foundation

// ─────────────────────────────────────────────────────────────
// The three contracts the whole system is built on (ARCHITECTURE §3, §6).
// Everything plugs into CoreEngine through one of these, which is what keeps
// the hierarchy hub-and-spoke instead of drifting back into layers.
// ─────────────────────────────────────────────────────────────

// MARK: - Tools

public struct ToolContext: Sendable {
    public let scope: Scope
    public let workingDirectory: URL?
    public let conversationID: String?
    /// Set when the call is part of an assignment, for span attribution.
    public let role: Role?

    public init(scope: Scope,
                workingDirectory: URL? = nil,
                conversationID: String? = nil,
                role: Role? = nil) {
        self.scope = scope
        self.workingDirectory = workingDirectory
        self.conversationID = conversationID
        self.role = role
    }
}

public struct ToolOutput: Sendable, Equatable {
    /// What goes back into the model's context.
    public let text: String
    /// Pointers to produced artifacts — paths or record ids, never raw content,
    /// so a transcript never balloons with file bodies (§2.3).
    public let artifacts: [String]

    public init(text: String, artifacts: [String] = []) {
        self.text = text
        self.artifacts = artifacts
    }
}

public enum ToolError: Error, CustomStringConvertible, Equatable {
    case invalidArguments(String)
    case executionFailed(String)
    case notPermitted(String)
    case cancelled

    public var description: String {
        switch self {
        case .invalidArguments(let m): return "invalid arguments: \(m)"
        case .executionFailed(let m): return "execution failed: \(m)"
        case .notPermitted(let m): return "not permitted: \(m)"
        case .cancelled: return "cancelled"
        }
    }
}

/// One uniform shape for built-in tools, MCP tools and Foundation Models
/// tools alike — CoreEngine never learns which is which.
public protocol AgentTool: Sendable {
    var name: String { get }
    var toolDescription: String { get }
    /// JSON Schema for the arguments object, as text.
    /// Text rather than `[String: Any]` because Swift 6 forbids the latter
    /// across concurrency boundaries (ARCHITECTURE App. C).
    var parametersJSON: String { get }
    /// Declared here, but the hook chain classifies independently: a tool
    /// cannot lower its own risk to dodge the gate (§5.3, §12.2).
    var riskLevel: RiskLevel { get }

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput
}

// MARK: - Channels

public struct ChannelID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct AgentMessage: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case reply, progress, error, summary }
    public let kind: Kind
    public let text: String
    public let conversationID: String?

    public init(kind: Kind = .reply, text: String, conversationID: String? = nil) {
        self.kind = kind
        self.text = text
        self.conversationID = conversationID
    }
}

public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public struct ID: Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String
        public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
        public var description: String { rawValue }
    }

    public let id: ID
    public let toolName: String
    public let risk: RiskLevel
    /// Shown verbatim to the human — the actual command/diff, not a summary.
    public let detail: String
    /// Populated when a policy chunk conflicts with the action, so the human
    /// sees the rule itself rather than just "risky" (§11.2).
    public let policyConflict: String?
    public let requestedAt: Date

    public init(id: ID = ID(),
                toolName: String,
                risk: RiskLevel,
                detail: String,
                policyConflict: String? = nil,
                requestedAt: Date = Date()) {
        self.id = id
        self.toolName = toolName
        self.risk = risk
        self.detail = detail
        self.policyConflict = policyConflict
        self.requestedAt = requestedAt
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case approved
    case rejected(reason: String?)
    /// The human edited the arguments before allowing it (§2.6 manual override).
    case approvedWithEdit(argumentsJSON: String)
}

/// GUI, Telegram, Discord, LINE and App Intents are all just this.
/// Approval is part of the contract, not something bolted on per channel —
/// that omission is what left v1's remote approval permanently unfinished.
public protocol Channel: Sendable {
    var id: ChannelID { get }
    func send(_ message: AgentMessage) async
    func present(_ request: ApprovalRequest) async
    /// Told when someone else answered first, so the channel can retract its
    /// own prompt (first-response-wins, §5.4).
    func approvalResolved(_ id: ApprovalRequest.ID, decision: ApprovalDecision) async
}

// MARK: - Team

public struct Criterion: Sendable, Equatable, Codable {
    public let text: String
    /// What the reviewer must actually see. Prose alone is how "done" gets
    /// claimed without being true (§2.5).
    public let evidenceRequired: String

    public init(text: String, evidenceRequired: String) {
        self.text = text
        self.evidenceRequired = evidenceRequired
    }
}

public struct Assignment: Sendable, Identifiable, Codable {
    public let id: String
    public let role: Role
    public let goal: String
    public let inputs: [String]
    /// Non-optional on purpose: an assignment without acceptance criteria
    /// cannot be reviewed, so the type system refuses to create one.
    public let acceptanceCriteria: [Criterion]
    public let deliverableType: String

    public init(id: String = UUID().uuidString,
                role: Role,
                goal: String,
                inputs: [String] = [],
                acceptanceCriteria: [Criterion],
                deliverableType: String) {
        self.id = id
        self.role = role
        self.goal = goal
        self.inputs = inputs
        self.acceptanceCriteria = acceptanceCriteria
        self.deliverableType = deliverableType
    }
}

public struct Evidence: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case commandExit      // build/test/lint exit code
        case statisticalCheck // assumption check result
        case citation         // source + tier
        case fileChange
    }
    public let kind: Kind
    public let summary: String
    public let passed: Bool

    public init(kind: Kind, summary: String, passed: Bool) {
        self.kind = kind
        self.summary = summary
        self.passed = passed
    }
}

/// What a specialist hands back — a summary plus pointers and evidence,
/// never the full transcript (§2.3).
public struct Deliverable: Sendable, Codable {
    public let assignmentID: String
    public let summary: String
    public let artifacts: [String]
    public let evidence: [Evidence]

    public init(assignmentID: String, summary: String,
                artifacts: [String] = [], evidence: [Evidence] = []) {
        self.assignmentID = assignmentID
        self.summary = summary
        self.artifacts = artifacts
        self.evidence = evidence
    }
}

/// Actor-bound so context isolation is a compiler guarantee rather than a
/// convention someone can quietly break.
public protocol Specialist: Actor {
    nonisolated var role: Role { get }
    nonisolated var definitionOfDone: [Criterion] { get }
    func execute(_ assignment: Assignment) async throws -> Deliverable
}
