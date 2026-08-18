import Foundation
import AgentKit
import LLMProviders

// ─────────────────────────────────────────────────────────────
// One contract, run against every executor, wherever it can run.
//
// It lives in its own target rather than in a test file because Tier 0.5
// cannot be tested by `swift test` at all: MLX resolves its Metal kernels
// through the main bundle, and under SwiftPM's test helper that lookup finds
// nothing (the same wall `EmbeddingCheck` hit — ARCHITECTURE E.13). So the
// on-device and OpenAI-compatible executors run these cases from
// `Tests/LLMProvidersTests`, and the MLX executor runs the *same* cases from
// the `MLXCheck` executable. Two harnesses, one definition of what an
// executor must do — a second copy of the assertions would drift, and the
// weaker copy would be the one guarding the tier everything falls back to.
//
// What the contract deliberately does not do is compare answers between
// tiers. A 3B model on-device and a 27B model over the network are not
// expected to say the same thing; they are expected to obey the same
// interface.
// ─────────────────────────────────────────────────────────────

public struct ContractViolation: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct ContractCase: Sendable {
    public let name: String
    /// Cases that ask the model to generate need a working backend; the pure
    /// ones (capability declarations, early rejection) do not, and must run
    /// even on a machine with nothing installed.
    public let needsModel: Bool
    let applies: @Sendable (any LLMExecutor) -> Bool
    let run: @Sendable (any LLMExecutor) async throws -> String
}

public struct ContractOutcome: Sendable {
    public enum Status: Sendable, Equatable {
        case passed
        /// The case asks for something this executor has honestly declared it
        /// cannot do. Nothing went unverified — a tier without tool calling
        /// having no tool-call behaviour is the contract working.
        case notApplicable
        /// The case applies but could not run: the backend is not reachable,
        /// or the model refused. This is the one that has to be loud, because
        /// an unverified tier reads exactly like a passing one.
        case skipped
        case failed
    }
    public let name: String
    public let status: Status
    /// What happened, in one line: the measurement on a pass, the reason on a
    /// skip, the failure on a failure.
    public let detail: String
    public let duration: Duration

    public var isFailure: Bool { status == .failed }
}

/// Room for an answer on an endpoint that is also serving somebody else.
///
/// 2,048 was the figure for months and it failed three full rounds in a row
/// while passing every time the suite was run alone (F-11). Measured, with the
/// identical request at temperature 0: **sequentially it costs 294 tokens; six
/// at once it costs 172 to 2,048, and the one that reached the ceiling came
/// back with `finish_reason: length` and an empty body.** Output length on this
/// endpoint is a function of how busy it is, so a budget set from a quiet
/// machine is a budget that fails under load — which is exactly when the whole
/// suite runs (E.47).
///
/// A share of the executor's own window, not a constant. A flat 8,192 was
/// tried first and overflowed Tier 0, whose window is 4,096 — the same mistake
/// rule L1 exists to prevent, made inside the file that checks the rules.
func contractAnswerBudget(for executor: any LLMExecutor) -> Int {
    max(512, min(8_192, executor.capabilities.contextWindow / 4))
}

public enum ExecutorContract {

    /// Runs every applicable case against one executor.
    ///
    /// Skips are reported, never silent — a skipped contract reads exactly
    /// like a passing one otherwise, which is how a tier ends up unverified.
    public static func run(against executor: any LLMExecutor) async -> [ContractOutcome] {
        let reachable = await executor.isAvailable()
        var outcomes: [ContractOutcome] = []

        for testCase in cases {
            guard testCase.applies(executor) else {
                outcomes.append(.init(name: testCase.name, status: .notApplicable,
                                      detail: "\(executor.identifier) does not declare it",
                                      duration: .zero))
                continue
            }
            guard reachable || !testCase.needsModel else {
                outcomes.append(.init(name: testCase.name, status: .skipped,
                                      detail: "\(executor.identifier) is not reachable",
                                      duration: .zero))
                continue
            }

            let clock = ContinuousClock()
            let started = clock.now
            do {
                let detail = try await testCase.run(executor)
                outcomes.append(.init(name: testCase.name, status: .passed,
                                      detail: detail, duration: started.duration(to: clock.now)))
            } catch let error as LLMError where isAcceptableRefusal(error) {
                // A refusal is the behaviour the whole router is built around
                // (ARCHITECTURE E.7), not a broken executor.
                outcomes.append(.init(name: testCase.name, status: .skipped,
                                      detail: "model refused: \(error.description)",
                                      duration: started.duration(to: clock.now)))
            } catch {
                outcomes.append(.init(name: testCase.name, status: .failed,
                                      detail: "\(error)", duration: started.duration(to: clock.now)))
            }
        }
        return outcomes
    }

    private static func isAcceptableRefusal(_ error: LLMError) -> Bool {
        if case .refused = error { return true }
        return false
    }

    // MARK: - the contract itself

    public static let cases: [ContractCase] = [
        capabilitiesAreCoherent,
        availabilityAnswers,
        unsupportedWorkIsRejectedEarly,
        oversizedRequestIsRejectedEarly,
        streamsTheAnswerInPieces,
        reasoningIsSeparateFromTheAnswer,
        structuredOutputIsDecodableJSON,
        toolCallsCarryValidArguments,
    ]

    /// An executor's declarations are what the router plans with, so an
    /// incoherent set is a routing bug waiting to happen rather than a
    /// cosmetic one.
    static let capabilitiesAreCoherent = ContractCase(
        name: "declares a coherent set of capabilities",
        needsModel: false,
        applies: { _ in true },
        run: { executor in
            guard !executor.identifier.isEmpty else {
                throw ContractViolation("empty identifier — spans and the UI have nothing to show")
            }
            guard executor.capabilities.contextWindow > 0 else {
                throw ContractViolation("context window of \(executor.capabilities.contextWindow)")
            }
            // Every executor here streams; the router's `stream` path probes
            // the first event to decide whether to escalate, and an executor
            // that cannot stream would make that decision impossible.
            guard executor.capabilities.supportsStreaming else {
                throw ContractViolation("does not stream")
            }
            return "\(executor.tier), \(executor.capabilities.contextWindow) tokens"
        })

    /// Called on the router's hot path on a machine that may have no model, no
    /// network and no Apple Intelligence. It must answer, not trap.
    static let availabilityAnswers = ContractCase(
        name: "answers whether it is available without trapping",
        needsModel: false,
        applies: { _ in true },
        run: { executor in
            let available = await executor.isAvailable()
            return available ? "available" : "not available"
        })

    /// Discovering a missing capability mid-turn wastes the round trip and
    /// leaves the caller with half a stream.
    static let unsupportedWorkIsRejectedEarly = ContractCase(
        name: "work it cannot do is refused before the model runs",
        needsModel: false,
        applies: { !$0.capabilities.supportsTools },
        run: { executor in
            var request = LLMRequest(messages: [.init(.user, "hi")])
            request.tools = [LLMToolSpec(name: "t", description: "d",
                                         parametersJSON: #"{"type":"object","properties":{}}"#)]
            do {
                _ = try await executor.complete(request)
                throw ContractViolation("accepted tools it does not support")
            } catch let error as LLMError {
                guard case .unsupported = error else {
                    throw ContractViolation("expected .unsupported, got \(error)")
                }
                return "rejected: \(error.description)"
            }
        })

    /// Overflow must be a routing signal, not a failure: §9.2 rule 3 sends the
    /// work to a tier with room instead of returning an error.
    static let oversizedRequestIsRejectedEarly = ContractCase(
        name: "a prompt past the context window is refused, not attempted",
        needsModel: false,
        applies: { _ in true },
        run: { executor in
            let window = executor.capabilities.contextWindow
            var request = LLMRequest(messages: [
                .init(.user, String(repeating: "ก ", count: window * 3)),
            ])
            request.maxTokens = 16
            do {
                _ = try await executor.complete(request)
                throw ContractViolation("accepted a prompt larger than its \(window)-token window")
            } catch let error as LLMError {
                guard case .contextOverflow = error else {
                    throw ContractViolation("expected .contextOverflow, got \(error)")
                }
                return "rejected: \(error.description)"
            }
        })

    /// Streaming is what keeps the UI honest about a slow local model. An
    /// executor that buffers the whole answer and yields it once satisfies the
    /// type but not the requirement.
    static let streamsTheAnswerInPieces = ContractCase(
        name: "streams the answer in more than one piece",
        needsModel: true,
        applies: { $0.capabilities.supportsStreaming },
        run: { executor in
            var request = LLMRequest(messages: [
                .init(.user, "Count from 1 to 10, comma separated."),
            ])
            // Room for a reasoning model to think *and* answer: 80 produced
            // nothing at all on qwen3.5, which is a fact about reasoning
            // models rather than about any executor.
            request.maxTokens = contractAnswerBudget(for: executor)

            var textDeltas = 0
            var reasoningDeltas = 0
            var text = ""
            for try await event in executor.respond(to: request) {
                switch event {
                case .textDelta(let chunk): textDeltas += 1; text += chunk
                case .reasoningDelta: reasoningDeltas += 1
                default: break
                }
            }
            guard textDeltas + reasoningDeltas > 1 else {
                throw ContractViolation("arrived in one piece (\(textDeltas) text deltas)")
            }
            guard !text.isEmpty else { throw ContractViolation("the answer itself never arrived") }
            return "\(textDeltas) text + \(reasoningDeltas) reasoning deltas"
        })

    /// The chunks a reasoning model produces before it answers are not the
    /// answer. Whether they arrive in their own protocol field (E.9 case 8c) or
    /// wrapped in `<think>` tags inside one text stream is the executor's
    /// problem, not the caller's.
    static let reasoningIsSeparateFromTheAnswer = ContractCase(
        name: "reasoning is reported apart from the answer",
        needsModel: true,
        applies: { _ in true },
        run: { executor in
            var request = LLMRequest(messages: [
                .init(.user, "What is 17 times 3? Reply with the number only."),
            ])
            request.maxTokens = contractAnswerBudget(for: executor)

            let completion = try await executor.complete(request)
            guard completion.text.contains("51") else {
                throw ContractViolation("answer was: \(completion.text.prefix(200))")
            }
            // Only a model that reasons out loud can demonstrate the
            // separation; the assertion above still runs everywhere.
            if !completion.reasoning.isEmpty {
                guard !completion.text.contains(completion.reasoning) else {
                    throw ContractViolation("reasoning leaked into the answer")
                }
                return "\(completion.reasoning.count) chars of reasoning kept apart"
            }
            return "no reasoning reported"
        })

    /// Structured output is the dependable mode for small models (E.6) and the
    /// only mode conflict detection and relation extraction use. Whatever the
    /// tier does underneath — guided generation, `response_format`, or a
    /// schema in the prompt — the caller decodes the same JSON.
    static let structuredOutputIsDecodableJSON = ContractCase(
        name: "structured output comes back as decodable JSON",
        needsModel: true,
        applies: { $0.capabilities.supportsStructuredOutput },
        run: { executor in
            var request = LLMRequest(messages: [
                .init(.system, "Route the request to a specialist in a research AI team."),
                .init(.user, "Fix a crash in main.swift on launch"),
            ])
            request.responseSchema = (name: "Routing", schemaJSON: routingSchema)
            request.maxTokens = contractAnswerBudget(for: executor)

            let completion = try await executor.complete(request)
            // `structuredText`, not `text`: a reasoning model can put the whole
            // object in the reasoning field and leave content empty, and
            // reading only `text` there is how every document came back with
            // no conflicts and no explanation.
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(completion.structuredText.utf8)) as? [String: Any] else {
                throw ContractViolation("not JSON: \(completion.structuredText.prefix(200))")
            }
            guard let role = object["role"] as? String,
                  ["researcher", "analyst", "engineer", "writer"].contains(role) else {
                throw ContractViolation("role missing or out of the enum: \(object)")
            }
            guard object["needsClarification"] is Bool else {
                throw ContractViolation("needsClarification missing or not a boolean: \(object)")
            }
            return "role=\(role)"
        })

    /// Tool calls arrive fragmented on every backend — across SSE chunks
    /// remotely, across generated tokens locally. Reassembling them into valid
    /// JSON is the executor's job; a truncated argument string reaches the
    /// gateway as a tool call that cannot be run.
    static let toolCallsCarryValidArguments = ContractCase(
        name: "tool calls reassemble into valid JSON arguments",
        needsModel: true,
        applies: { $0.capabilities.supportsTools },
        run: { executor in
            var request = LLMRequest(messages: [
                .init(.system, "Use tools when asked about cohort sizes."),
                .init(.user, "How many patients are in the diabetes cohort?"),
            ])
            request.maxTokens = contractAnswerBudget(for: executor)
            request.tools = [LLMToolSpec(
                name: "lookup_patient_count",
                description: "Look up how many patients are in a named cohort",
                parametersJSON: #"{"type":"object","properties":{"cohort":{"type":"string"}},"required":["cohort"]}"#)]

            let completion = try await executor.complete(request)
            guard let call = completion.toolCalls.first else {
                throw ContractViolation("no tool call: \(completion.text.prefix(200))")
            }
            guard call.name == "lookup_patient_count" else {
                throw ContractViolation("called \(call.name)")
            }
            guard !call.id.isEmpty else {
                throw ContractViolation("tool call has no id — its result cannot be attached to it")
            }
            guard (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) != nil else {
                throw ContractViolation("arguments did not reassemble: \(call.argumentsJSON)")
            }
            return "\(call.name)\(call.argumentsJSON)"
        })

    /// Shared so the live routing test asks for the same shape the contract
    /// does; two spellings of one schema is two things to keep in step.
    public static let routingSchema = #"""
    {"type":"object",
     "properties":{"role":{"type":"string","enum":["researcher","analyst","engineer","writer"]},
                   "needsClarification":{"type":"boolean"}},
     "required":["role","needsClarification"]}
    """#
}
