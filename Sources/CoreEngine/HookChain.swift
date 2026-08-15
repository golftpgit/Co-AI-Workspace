import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Hook Chain Gate (ARCHITECTURE §5.3, §19.4) — Critic → Stage Gate → Risk
// Scorer → Policy Gate → HITL, around *every* tool call rather than once at
// planning time.
//
// The chain is a value, not a service the caller may or may not consult:
// `ToolGateway` owns one and there is no other way to reach a tool, so
// "which agents run through the gate?" is not a question the code can answer
// with "some of them".
// ─────────────────────────────────────────────────────────────

/// A tool call that has been requested but not yet run.
public struct PendingToolCall: Sendable {
    public let toolName: String
    public let toolDescription: String
    /// What the tool says about itself. A floor for the scorer, never a ceiling.
    public let declaredRisk: RiskLevel
    public let parametersJSON: String
    /// Mutable across the chain: the Critic may repair arguments and a human
    /// may edit them before approving (§2.6).
    public var argumentsJSON: String
    public let context: ToolContext

    public init(toolName: String,
                toolDescription: String,
                declaredRisk: RiskLevel,
                parametersJSON: String,
                argumentsJSON: String,
                context: ToolContext) {
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.declaredRisk = declaredRisk
        self.parametersJSON = parametersJSON
        self.argumentsJSON = argumentsJSON
        self.context = context
    }
}

// MARK: - Critic

public enum CriticVerdict: Sendable, Equatable {
    case pass
    /// Sent back to the model with a reason, which is cheaper and more useful
    /// than letting the call fail inside the tool.
    case sendBack(reason: String)
    /// Arguments repaired in place (a missing default, a path normalised).
    case repaired(argumentsJSON: String, note: String)
}

public protocol ToolCritic: Sendable {
    var criticName: String { get }
    func review(_ call: PendingToolCall) async -> CriticVerdict
}

/// Schema-level validation only: the arguments must be a JSON object and must
/// carry every property the tool declares as required. Golden-task pattern
/// matching (the LLM-backed half of §5.3) arrives with the roster in P4.
public struct SchemaCritic: ToolCritic {
    public let criticName = "schema"
    public init() {}

    public func review(_ call: PendingToolCall) async -> CriticVerdict {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .sendBack(reason: "arguments ของ '\(call.toolName)' ไม่ใช่ JSON object ที่อ่านได้")
        }
        guard let schema = try? JSONSerialization.jsonObject(
                with: Data(call.parametersJSON.utf8)) as? [String: Any] else {
            return .pass    // no usable schema to check against
        }
        let required = (schema["required"] as? [String]) ?? []
        let missing = required.filter { object[$0] == nil }
        guard missing.isEmpty else {
            return .sendBack(reason: "'\(call.toolName)' ขาดอาร์กิวเมนต์ที่จำเป็น: \(missing.joined(separator: ", "))")
        }
        return .pass
    }
}

// MARK: - Policy Gate

/// Hard constraints from the `policy` scope of the knowledge base. Returning a
/// chunk stops the call outright — the point of §11.2 is that the human sees
/// the rule verbatim, not a summary that says "risky".
public protocol PolicyGate: Sendable {
    func conflict(with call: PendingToolCall, risk: RiskAssessment) async -> String?
}

/// P1 placeholder. Named for what it is so nobody reads an empty policy set as
/// "policy checked and clean"; the KB-backed gate is P2.6.
public struct NoPolicyGate: PolicyGate {
    public init() {}
    public func conflict(with call: PendingToolCall, risk: RiskAssessment) async -> String? { nil }
}

// MARK: - Post-tool hooks

/// Runs on the result (§5.3 PostToolUse): a non-zero exit code, a failed
/// assumption check. Returns a warning that goes back into the turn, never an
/// exception — the tool already ran.
public protocol PostToolHook: Sendable {
    var hookName: String { get }
    func inspect(_ call: PendingToolCall, output: ToolOutput) async -> String?
}

// MARK: - The chain

/// What the chain decided, before anything ran.
public enum GateVerdict: Sendable, Equatable {
    /// Cleared to run, with whatever arguments survived the chain.
    case allow(argumentsJSON: String, risk: RiskAssessment, notes: [String])
    /// The Critic sent it back; the model gets the reason and may retry.
    case sendBack(reason: String)
    /// A policy hard constraint. Not "approve to continue" — stop.
    case hardStop(policy: String, risk: RiskAssessment)
    /// The project's current stage does not allow this kind of work (§19.4).
    /// Like a hard stop and unlike a denial: there is nobody to ask, because
    /// the answer is "not yet", not "not you".
    case blockedByStage(reason: String)
    /// A human said no.
    case denied(reason: String?, risk: RiskAssessment)
    /// Plan-only mode is on; nothing executes this session.
    case planOnly
}

/// Asked for a human decision when the chain needs one. The gateway does not
/// know about channels; the broker does (§5.4).
public protocol ApprovalRequesting: Sendable {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision
}

public struct HookChain: Sendable {
    public let critics: [any ToolCritic]
    public let stageGate: StageGate
    public let scorer: any RiskScoring
    public let policyGate: any PolicyGate
    public let postHooks: [any PostToolHook]

    public init(critics: [any ToolCritic] = [SchemaCritic()],
                stageGate: StageGate = .disabled,
                scorer: any RiskScoring = DefaultRiskScorer(),
                policyGate: any PolicyGate = NoPolicyGate(),
                postHooks: [any PostToolHook] = []) {
        self.critics = critics
        self.stageGate = stageGate
        self.scorer = scorer
        self.policyGate = policyGate
        self.postHooks = postHooks
    }

    /// The whole pre-execution gate, in the order §5.3 specifies. Nothing here
    /// executes the tool; the caller only ever gets a verdict back.
    public func evaluate(_ call: PendingToolCall,
                         modes: OperatingModes,
                         approver: (any ApprovalRequesting)?) async -> GateVerdict {
        var call = call
        var notes: [String] = []

        // 1 — Critic. Cheapest check first: a malformed call should never cost
        //     a risk assessment, a policy query or a human's attention.
        for critic in critics {
            switch await critic.review(call) {
            case .pass:
                continue
            case .sendBack(let reason):
                return .sendBack(reason: reason)
            case .repaired(let repaired, let note):
                call.argumentsJSON = repaired
                notes.append("\(critic.criticName): \(note)")
            }
        }

        // 2 — Stage Gate (§19.4). Before the scorer and before a human: how
        //     dangerous the arguments are does not matter in a stage where the
        //     work itself is not allowed yet. No-ops outside a project scope,
        //     which is what General is.
        if let refusal = await stageGate.refusal(for: call) {
            return .blockedByStage(reason: refusal)
        }

        // 3 — Risk Scorer. Runs before plan-only so the refusal can still say
        //     what it was about to refuse.
        let risk = scorer.score(toolName: call.toolName,
                                declared: call.declaredRisk,
                                argumentsJSON: call.argumentsJSON,
                                context: call.context)

        // 4 — Policy Gate. A hard constraint outranks every autonomy setting,
        //     including full autonomous.
        if let policy = await policyGate.conflict(with: call, risk: risk) {
            return .hardStop(policy: policy, risk: risk)
        }

        // 5 — Plan-only. Checked after policy so the more specific reason wins.
        if modes.planOnly {
            return .planOnly
        }

        // 6 — HITL.
        //
        // A few tools ask a person whatever the slider says (§5.5, P14.4). Full
        // autonomy is a considered decision to accept bad odds while nobody is
        // watching, and that trade needs the damage to be visible afterwards.
        // For `install_package` it is not: an sdist runs its own code during
        // installation, and nothing it did appears in the tool's output or in
        // anything the package is later used for. See `AlwaysAsk`.
        let mustAsk = AlwaysAsk.requiresHuman(call.toolName)
        guard mustAsk || modes.autonomy.requiresApproval(for: risk.level) else {
            return .allow(argumentsJSON: call.argumentsJSON, risk: risk, notes: notes)
        }
        guard let approver else {
            // No way to ask is not the same as permission. v1 defaulted to
            // running in this case; here the absence of a channel is a denial.
            return .denied(reason: "ไม่มีช่องทางสำหรับขออนุมัติ", risk: risk)
        }

        let request = ApprovalRequest(
            toolName: call.toolName,
            risk: risk.level,
            detail: Self.detail(for: call, risk: risk))
        switch await approver.requestApproval(request) {
        case .approved:
            return .allow(argumentsJSON: call.argumentsJSON, risk: risk, notes: notes)
        case .approvedWithEdit(let edited):
            notes.append("ผู้ใช้แก้อาร์กิวเมนต์ก่อนอนุมัติ")
            return .allow(argumentsJSON: edited, risk: risk, notes: notes)
        case .rejected(let reason):
            return .denied(reason: reason, risk: risk)
        }
    }

    /// PostToolUse. Warnings, never failures — the side effect already happened.
    public func inspectResult(_ call: PendingToolCall, output: ToolOutput) async -> [String] {
        var warnings: [String] = []
        for hook in postHooks {
            if let warning = await hook.inspect(call, output: output) {
                warnings.append("\(hook.hookName): \(warning)")
            }
        }
        return warnings
    }

    /// The human sees the actual arguments, not a paraphrase (§5.4).
    private static func detail(for call: PendingToolCall, risk: RiskAssessment) -> String {
        """
        \(call.toolName)(\(call.argumentsJSON))

        เหตุผลที่ต้องอนุมัติ:
        \(risk.reasons.map { "• \($0)" }.joined(separator: "\n"))
        """
    }
}
