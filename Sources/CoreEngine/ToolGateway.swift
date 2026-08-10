import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// ToolGateway (ARCHITECTURE §5.3) — the only place in the system that calls
// `AgentTool.call`.
//
// The invariant "no tool runs without the hook chain" is enforced structurally,
// not by discipline: registered tools are private to this actor and are never
// vended. Callers that need to advertise tools to a model get `ToolAdvert`
// values — name, description and schema, with no way to invoke anything.
// `scripts/check.sh` fails the build if `.call(argumentsJSON:` appears in any
// other file.
// ─────────────────────────────────────────────────────────────

/// What a model is told a tool is. Deliberately not callable.
public struct ToolAdvert: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String
    /// The tool's own claim, shown in the UI. The scorer re-derives the real
    /// level at call time (§5.3).
    public let declaredRisk: RiskLevel
}

public enum GateOutcome: Sendable {
    case executed(ToolOutput, risk: RiskAssessment, warnings: [String])
    case sentBack(reason: String)
    case blockedByPolicy(String)
    case denied(reason: String?)
    case planOnly
    case unknownTool(String)

    /// What goes back into the model's context. Every branch says something:
    /// a blocked call that returns nothing is how a model ends up retrying
    /// the same forbidden thing forever.
    public var transcriptText: String {
        switch self {
        case .executed(let output, _, let warnings):
            return warnings.isEmpty ? output.text
                 : output.text + "\n\n[คำเตือนหลังรัน]\n" + warnings.joined(separator: "\n")
        case .sentBack(let reason):
            return "เครื่องมือยังไม่ถูกเรียก — ตรวจแล้วไม่ผ่าน: \(reason)"
        case .blockedByPolicy(let policy):
            return "หยุดโดยนโยบาย (hard constraint) — ข้อที่ขัด:\n\(policy)"
        case .denied(let reason):
            return "ผู้ใช้ไม่อนุมัติ\(reason.map { ": \($0)" } ?? "")"
        case .planOnly:
            return "อยู่ในโหมด Plan-only — เสนอแผนได้ แต่ยังไม่รันเครื่องมือ"
        case .unknownTool(let name):
            return "ไม่มีเครื่องมือชื่อ '\(name)' ลงทะเบียนอยู่"
        }
    }

    public var didExecute: Bool {
        if case .executed = self { return true }
        return false
    }
}

public actor ToolGateway {
    /// Private and never returned. This is the whole enforcement mechanism.
    private var tools: [String: any AgentTool] = [:]
    private let chain: HookChain
    private let approver: (any ApprovalRequesting)?
    private let sink: (any SpanSink)?
    private var modes: OperatingModes
    private let log = AppLog.logger("gate")

    public init(chain: HookChain = HookChain(),
                approver: (any ApprovalRequesting)? = nil,
                spanSink: (any SpanSink)? = nil,
                modes: OperatingModes = .default) {
        self.chain = chain
        self.approver = approver
        self.sink = spanSink
        self.modes = modes
    }

    // MARK: - registration

    public func register(_ tool: any AgentTool) {
        tools[tool.name] = tool
    }

    public func register(_ newTools: [any AgentTool]) {
        for tool in newTools { register(tool) }
    }

    public func unregister(_ name: String) {
        tools.removeValue(forKey: name)
    }

    /// Everything a model or the UI needs to know about the tool belt, and
    /// nothing it could use to bypass the gate.
    public var adverts: [ToolAdvert] {
        tools.values
            .map { ToolAdvert(name: $0.name,
                              description: $0.toolDescription,
                              parametersJSON: $0.parametersJSON,
                              declaredRisk: $0.riskLevel) }
            .sorted { $0.name < $1.name }
    }

    public var registeredNames: [String] { tools.keys.sorted() }

    // MARK: - modes

    public func setModes(_ modes: OperatingModes) { self.modes = modes }
    public var currentModes: OperatingModes { modes }

    // MARK: - the one entry point

    /// Runs the hook chain and, only if it allows, the tool. Tool errors are
    /// thrown; gate decisions are returned — a refusal to run is a normal
    /// outcome of a turn, not an exception.
    public func call(_ name: String,
                     argumentsJSON: String,
                     context: ToolContext,
                     parentSpan: SpanID? = nil) async throws -> GateOutcome {
        guard let tool = tools[name] else {
            log.warning("unknown tool '\(name, privacy: .public)'")
            return .unknownTool(name)
        }

        var pending = PendingToolCall(toolName: tool.name,
                                      toolDescription: tool.toolDescription,
                                      declaredRisk: tool.riskLevel,
                                      parametersJSON: tool.parametersJSON,
                                      argumentsJSON: argumentsJSON,
                                      context: context)

        let verdict = await chain.evaluate(pending, modes: modes, approver: approver)
        switch verdict {
        case .sendBack(let reason):
            await record(name: name, context: context, parent: parentSpan,
                         status: .failed, detail: "critic: \(reason)")
            return .sentBack(reason: reason)

        case .hardStop(let policy, let risk):
            await record(name: name, context: context, parent: parentSpan,
                         status: .failed, detail: "policy hard stop [\(risk.level)]: \(policy)")
            return .blockedByPolicy(policy)

        case .denied(let reason, let risk):
            await record(name: name, context: context, parent: parentSpan,
                         status: .cancelled, detail: "denied [\(risk.level)]\(reason.map { ": \($0)" } ?? "")")
            return .denied(reason: reason)

        case .planOnly:
            await record(name: name, context: context, parent: parentSpan,
                         status: .cancelled, detail: "plan-only mode")
            return .planOnly

        case .allow(let arguments, let risk, let notes):
            pending.argumentsJSON = arguments

            var span = Span(parent: parentSpan, name: "tool:\(name)",
                            role: context.role, scope: context.scope)
            await sink?.record(span)
            do {
                let output = try await tool.call(argumentsJSON: arguments, context: context)
                let warnings = await chain.inspectResult(pending, output: output)
                span.status = .succeeded
                span.endedAt = Date()
                span.detail = ([risk.level.description] + notes + warnings).joined(separator: " · ")
                await sink?.record(span)
                return .executed(output, risk: risk, warnings: warnings)
            } catch {
                span.status = error is CancellationError ? .cancelled : .failed
                span.endedAt = Date()
                span.detail = "\(error)"
                await sink?.record(span)
                throw error
            }
        }
    }

    private func record(name: String, context: ToolContext, parent: SpanID?,
                        status: SpanStatus, detail: String) async {
        guard let sink else { return }
        var span = Span(parent: parent, name: "tool:\(name)",
                        role: context.role, scope: context.scope, status: status)
        span.endedAt = Date()
        span.detail = detail
        await sink.record(span)
    }
}
