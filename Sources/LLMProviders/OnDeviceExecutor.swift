import Foundation
import FoundationModels
import AgentKit

// ─────────────────────────────────────────────────────────────
// Tier 0 — Apple's on-device model (~3B), behind the same LLMExecutor
// interface as everything else.
//
// Two measured facts shape this implementation (ARCHITECTURE E.6/E.7):
//
//  • It does not follow prose instructions reliably — asked to "reply with
//    exactly one word" it answers with a sentence. Structured output is the
//    dependable mode, so the schema path is first class here.
//  • It refuses roughly 12.5% of ordinary medical-research prompts, at
//    random, and relaxing guardrails does not help. Refusals surface as
//    `LLMError.refused` so the router escalates instead of failing the user.
// ─────────────────────────────────────────────────────────────

public struct OnDeviceExecutor: LLMExecutor {
    public let identifier = "apple-on-device"
    public let tier: ModelTier = .onDevice
    public let capabilities: LLMCapabilities

    private let guardrails: SystemLanguageModel.Guardrails

    public init(contextWindow: Int = 4_096,
                guardrails: SystemLanguageModel.Guardrails = .default) {
        self.guardrails = guardrails
        self.capabilities = LLMCapabilities(
            contextWindow: contextWindow,
            // Apple's `Tool` protocol wants compile-time `@Generable` types;
            // bridging our runtime tool registry onto it is P8.3 work. Saying
            // so honestly means the router sends tool work upward instead of
            // discovering the gap halfway through a turn.
            supportsTools: false,
            supportsStructuredOutput: true,
            supportsStreaming: true,
            supportsVision: false)
    }

    public func isAvailable() async -> Bool {
        SystemLanguageModel(guardrails: guardrails).isAvailable
    }

    public func prewarm() async {
        guard await isAvailable() else { return }
        makeSession(instructions: nil).prewarm()
    }

    public func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try rejectIfUnsupported(request)
                    guard await isAvailable() else {
                        throw LLMError.unavailable("Apple Intelligence is not available on this Mac")
                    }

                    let session = makeSession(instructions: Self.instructions(from: request))
                    let prompt = Self.prompt(from: request)
                    var options = GenerationOptions()
                    options = GenerationOptions(temperature: request.temperature,
                                                maximumResponseTokens: request.maxTokens)

                    if let schema = request.responseSchema {
                        let generation = try JSONSchemaBridge.generationSchema(
                            name: schema.name, json: schema.schemaJSON)
                        let response = try await session.respond(
                            to: prompt, schema: generation, options: options)
                        // Hand back JSON so callers decode the same way for
                        // every tier — on-device and remote look identical.
                        continuation.yield(.textDelta(response.content.jsonString))
                    } else {
                        var emitted = ""
                        for try await snapshot in session.streamResponse(to: prompt, options: options) {
                            let text = snapshot.content
                            // Snapshots are cumulative; callers want deltas.
                            guard text.count > emitted.count else { continue }
                            let delta = String(text.dropFirst(emitted.count))
                            emitted = text
                            continuation.yield(.textDelta(delta))
                        }
                    }

                    continuation.yield(.finished(reason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - plumbing

    private func makeSession(instructions: String?) -> LanguageModelSession {
        let model = SystemLanguageModel(guardrails: guardrails)
        if let instructions {
            return LanguageModelSession(model: model, instructions: instructions)
        }
        return LanguageModelSession(model: model)
    }

    /// System messages become instructions; there is no separate system role.
    private static func instructions(from request: LLMRequest) -> String? {
        let system = request.messages.filter { $0.role == .system }.map(\.content)
        return system.isEmpty ? nil : system.joined(separator: "\n\n")
    }

    /// The session has no transcript of its own here, so prior turns are
    /// folded into the prompt. History stays authoritative in the database
    /// (ARCHITECTURE §7) rather than inside a session object.
    private static func prompt(from request: LLMRequest) -> String {
        let turns = request.messages.filter { $0.role != .system }
        guard turns.count > 1 else { return turns.last?.content ?? "" }

        var lines: [String] = []
        for message in turns.dropLast() {
            let speaker = switch message.role {
            case .user: "User"
            case .assistant: "Assistant"
            case .tool: "Tool result"
            case .system: "System"
            }
            lines.append("\(speaker): \(message.content)")
        }
        lines.append("User: \(turns.last?.content ?? "")")
        return lines.joined(separator: "\n")
    }

    /// Translates Apple's errors into ours, keeping refusal distinct from
    /// failure — the whole escalation strategy depends on that difference.
    private static func map(_ error: Error) -> LLMError {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .refusal(_, let context):
                return .refused(context.debugDescription)
            case .exceededContextWindowSize(let context):
                return .contextOverflow(needed: -1, available: -1)
                    .annotated(context.debugDescription)
            case .guardrailViolation(let context):
                return .refused(context.debugDescription)
            default:
                return .transport("\(generation)")
            }
        }
        // Some refusals arrive as plain errors; the description is the only
        // reliable marker, so match on it rather than assume a type.
        let text = String(describing: error)
        if text.contains("Refusal") || text.contains("sensitive") || text.contains("guardrail") {
            return .refused(String(text.prefix(160)))
        }
        return .transport(String(text.prefix(160)))
    }
}

extension LLMError {
    /// Keeps the original message when the concrete numbers are unavailable.
    func annotated(_ detail: String) -> LLMError {
        if case .contextOverflow = self { return .unsupported("context window exceeded: \(detail.prefix(120))") }
        return self
    }
}
