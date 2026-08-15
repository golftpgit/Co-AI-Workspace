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
    /// Which leaf of the plan this work is against (§19.6). Carried on the
    /// context rather than passed separately, so every span the gateway
    /// records inherits it without any caller remembering to.
    public let workPackage: String?

    public init(scope: Scope,
                workingDirectory: URL? = nil,
                conversationID: String? = nil,
                role: Role? = nil,
                workPackage: String? = nil) {
        self.scope = scope
        self.workingDirectory = workingDirectory
        self.conversationID = conversationID
        self.role = role
        self.workPackage = workPackage
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

    /// Cheap local validation the gate runs *before* it spends a human's
    /// attention. A call that cannot possibly succeed — no working directory
    /// chosen, a path that does not exist — belongs back with the model, not
    /// in front of the user as an approval they are about to waste a click on.
    ///
    /// A tool may only *refuse* here. It cannot approve, cannot lower its own
    /// risk and cannot skip the chain: throwing sends the call back, and
    /// returning normally still leaves every decision to the gate (§5.3).
    func precheck(argumentsJSON: String, context: ToolContext) throws

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput
}

extension AgentTool {
    public func precheck(argumentsJSON: String, context: ToolContext) throws {}
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

/// The answering side of the approval broker (§5.4), as a channel sees it.
///
/// Declared here rather than in CoreEngine so a channel can hand back a
/// decision without importing the engine — M4 must not be able to reach the
/// tool gateway, and one import is all it would take (v1 bug B2).
public protocol ApprovalAnswering: Sendable {
    /// Returns false when someone else answered first, so the losing channel
    /// can retract its own prompt instead of silently doing nothing.
    @discardableResult
    func submit(_ id: ApprovalRequest.ID,
                decision: ApprovalDecision,
                from channel: ChannelID?) async -> Bool
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

public struct Assignment: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public let role: Role
    public let goal: String
    public let inputs: [String]
    /// Non-optional on purpose: an assignment without acceptance criteria
    /// cannot be reviewed, so the type system refuses to create one.
    public let acceptanceCriteria: [Criterion]
    public let deliverableType: String

    /// `OpaqueID`, not a raw UUID: SurrealDB v3 re-types a bound UUID-shaped
    /// string into a UUID value, so an assignment id used in a comparison
    /// stopped matching the string that was stored (ARCHITECTURE App. C.0).
    /// The persistence layer pins every id comparison as well — this is the
    /// other half of the same rule, applied where the id is made.
    public init(id: String = OpaqueID.make(OpaqueID.assignment),
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

    /// The kind of thing this produces, in the form two assignments are
    /// compared by (§19.7, P10.15).
    ///
    /// `deliverableType` is free text a model or a person wrote, so "รายงานสรุป"
    /// and " รายงานสรุป " are the same promise typed twice. Trimming and case
    /// are all this does deliberately: merging "รายงานสรุป" with
    /// "รายงานสรุปผลการวิเคราะห์" would build one forecast population out of two
    /// different jobs, and a band is only worth reading if everything in it is
    /// the same kind of work. Two small populations that each say "ยังน้อยเกินไป"
    /// beat one large one that is wrong.
    public var deliverableKind: String { Self.deliverableKind(deliverableType) }

    public static func deliverableKind(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
    /// For a citation: how credible the source is (§14.1). `nil` for every other
    /// kind, and also for a citation whose tier could not be established — which
    /// QA treats as a source that cannot carry a claim rather than as a good one.
    public let tier: CredibilityTier?

    public init(kind: Kind, summary: String, passed: Bool,
                tier: CredibilityTier? = nil) {
        self.kind = kind
        self.summary = summary
        self.passed = passed
        self.tier = tier
    }
}

/// What a specialist hands back — a summary plus pointers and evidence,
/// never the full transcript (§2.3).
public struct Deliverable: Sendable, Codable, Equatable {
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

/// How a tool tells the evidence builder how credible a source was (§14.1,
/// P13.2).
///
/// A marker in the text rather than a field on `ToolOutput`, because a tool's
/// output is what a model reads and this has to be visible to it too — and
/// because widening the tool protocol for one kind of tool is how a protocol
/// stops meaning anything. Written and read in one place, with a test on the
/// round trip, so the two halves cannot drift.
public enum CitationTier {
    static let prefix = "tier:"

    /// The line a tool puts *first* in its output, so it survives any truncation
    /// of the text into an evidence summary.
    public static func marker(_ tier: CredibilityTier?) -> String {
        "\(prefix) \(tier?.label.lowercased() ?? "unknown")"
    }

    /// The tier a piece of tool output declared, or `nil` when it declared none.
    /// `nil` is not "probably fine": QA treats an untiered citation as one that
    /// cannot carry a claim.
    public static func tier(in text: String) -> CredibilityTier? {
        guard let line = text.split(separator: "\n").first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }) else { return nil }
        let value = line.replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        return CredibilityTier.allCases.first { $0.label.lowercased() == value }
    }
}
