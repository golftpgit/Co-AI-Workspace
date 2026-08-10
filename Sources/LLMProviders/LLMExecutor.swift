import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// LLMExecutor — our own abstraction (ARCHITECTURE §9.1).
//
// Its shape deliberately mirrors Apple's LanguageModelExecutor, which ships
// with macOS 27. Until then this layer is what lets on-device and remote
// models sit behind one interface; afterwards Apple's provider API becomes
// a fourth implementation and nothing above here changes.
// ─────────────────────────────────────────────────────────────

/// Where a model runs. Drives routing policy and cost governance (§9.2).
public enum ModelTier: Int, Sendable, Comparable, CaseIterable {
    case onDevice = 0      // Foundation Models — free, private, limited
    case localMLX = 1      // our own MLX runtime — free, the guaranteed floor
    case selfHosted = 2    // vLLM/LM Studio elsewhere — free, unmetered
    case paid = 3          // hosted API — metered, needs the budget governor

    public static func < (a: ModelTier, b: ModelTier) -> Bool { a.rawValue < b.rawValue }

    public var isMetered: Bool { self == .paid }
}

public struct LLMCapabilities: Sendable {
    public let contextWindow: Int
    public let supportsTools: Bool
    public let supportsStructuredOutput: Bool
    public let supportsStreaming: Bool
    public let supportsVision: Bool

    public init(contextWindow: Int,
                supportsTools: Bool,
                supportsStructuredOutput: Bool,
                supportsStreaming: Bool,
                supportsVision: Bool) {
        self.contextWindow = contextWindow
        self.supportsTools = supportsTools
        self.supportsStructuredOutput = supportsStructuredOutput
        self.supportsStreaming = supportsStreaming
        self.supportsVision = supportsVision
    }
}

public struct LLMToolSpec: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments, as text — Swift 6 forbids `[String: Any]`
    /// across concurrency boundaries (ARCHITECTURE App. C).
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct LLMToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct LLMMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    public let toolCallID: String?
    /// Required on assistant turns that requested tools: the OpenAI protocol
    /// wants the original tool_calls echoed back, and omitting them makes the
    /// model reply with empty text and no error (ARCHITECTURE E.9).
    public let toolCalls: [LLMToolCall]

    public init(_ role: Role, _ content: String,
                toolCallID: String? = nil, toolCalls: [LLMToolCall] = []) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}

public struct LLMRequest: Sendable {
    public var messages: [LLMMessage]
    public var tools: [LLMToolSpec] = []
    public var maxTokens: Int = 512
    public var temperature: Double = 0.2
    /// JSON Schema as text — the portable form of `@Generable`.
    public var responseSchema: (name: String, schemaJSON: String)?
    public var timeout: Double = 120

    public init(messages: [LLMMessage]) { self.messages = messages }

    /// Rough token estimate for admission control. Deliberately crude and
    /// slightly pessimistic: it decides whether to *try* a tier, and the
    /// executor still reports real usage afterwards.
    public var estimatedPromptTokens: Int {
        let characters = messages.reduce(0) { $0 + $1.content.count }
        return characters / 3 + messages.count * 4
    }
}

public struct LLMUsage: Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public var total: Int { promptTokens + completionTokens }

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public enum LLMEvent: Sendable {
    case textDelta(String)
    /// Chain-of-thought from a reasoning model, kept apart from the answer.
    /// Merging the two would corrupt structured output and store thinking as
    /// if the user had been told it (ARCHITECTURE E.9, case 8c).
    case reasoningDelta(String)
    case toolCall(LLMToolCall)
    case usage(LLMUsage)
    case finished(reason: String)
}

public enum LLMError: Error, CustomStringConvertible, Equatable {
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)
    case timeout
    case cancelled
    /// The model declined on safety grounds. Measured at ~12.5% of ordinary
    /// medical-research prompts on-device (ARCHITECTURE E.7), so the router
    /// treats it as a signal to escalate, never as a user-visible failure.
    case refused(String)
    /// Input does not fit this model's context window.
    case contextOverflow(needed: Int, available: Int)
    /// Declared capability does not cover what the request needs.
    case unsupported(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case .http(let s, let b): return "http(\(s)): \(b.prefix(120))"
        case .transport(let m): return "transport: \(m.prefix(120))"
        case .decoding(let m): return "decoding: \(m.prefix(120))"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .refused(let m): return "refused: \(m.prefix(120))"
        case .contextOverflow(let n, let a): return "context overflow: needs ~\(n), has \(a)"
        case .unsupported(let m): return "unsupported: \(m)"
        case .unavailable(let m): return "unavailable: \(m)"
        }
    }

    /// Whether the router should try the next tier rather than surface this.
    public var isEscalatable: Bool {
        switch self {
        case .refused, .contextOverflow, .unsupported, .unavailable, .timeout, .transport, .http:
            return true
        case .decoding, .cancelled:
            return false
        }
    }
}

/// A completed, non-streaming response.
public struct LLMCompletion: Sendable {
    public let text: String
    /// What the model thought before answering, if it reports it separately.
    /// Empty for models that do not reason out loud.
    public let reasoning: String
    public let toolCalls: [LLMToolCall]
    public let usage: LLMUsage?
    public let finishReason: String
    /// Which executor actually produced this — recorded on spans and shown in
    /// the UI so the user is never guessing which model answered.
    public let producedBy: String
    public let tier: ModelTier

    public init(text: String, reasoning: String = "", toolCalls: [LLMToolCall] = [],
                usage: LLMUsage? = nil,
                finishReason: String = "stop", producedBy: String, tier: ModelTier) {
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
        self.producedBy = producedBy
        self.tier = tier
    }
}

public protocol LLMExecutor: Sendable {
    /// Stable name for logs, spans and the UI.
    var identifier: String { get }
    var tier: ModelTier { get }
    var capabilities: LLMCapabilities { get }

    /// Cheap readiness check — endpoint reachable, model loaded, assets present.
    func isAvailable() async -> Bool
    func prewarm() async
    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

extension LLMExecutor {
    public func prewarm() async {}

    /// Collects a stream into one completion. Shared so every executor behaves
    /// identically here rather than each inventing its own aggregation.
    public func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        var text = ""
        var reasoning = ""
        var calls: [LLMToolCall] = []
        var usage: LLMUsage?
        var reason = "stop"

        for try await event in respond(to: request) {
            switch event {
            case .textDelta(let chunk): text += chunk
            case .reasoningDelta(let chunk): reasoning += chunk
            case .toolCall(let call): calls.append(call)
            case .usage(let u): usage = u
            case .finished(let r): reason = r
            }
        }
        return LLMCompletion(text: text, reasoning: reasoning, toolCalls: calls, usage: usage,
                             finishReason: reason, producedBy: identifier, tier: tier)
    }

    /// Rejects work the executor has already declared it cannot do, so the
    /// router can move on instead of burning a round trip to find out.
    func rejectIfUnsupported(_ request: LLMRequest) throws {
        if !request.tools.isEmpty && !capabilities.supportsTools {
            throw LLMError.unsupported("\(identifier) has no tool calling")
        }
        if request.responseSchema != nil && !capabilities.supportsStructuredOutput {
            throw LLMError.unsupported("\(identifier) has no structured output")
        }
        let needed = request.estimatedPromptTokens + request.maxTokens
        if needed > capabilities.contextWindow {
            throw LLMError.contextOverflow(needed: needed, available: capabilities.contextWindow)
        }
    }
}
