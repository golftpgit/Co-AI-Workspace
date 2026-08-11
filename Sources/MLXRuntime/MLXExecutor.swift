import Foundation
import AgentKit
import LLMProviders
import MLX
import MLXLLM
import MLXLMCommon

// ─────────────────────────────────────────────────────────────
// Tier 0.5 — a model we load and run ourselves (ARCHITECTURE §9.4).
//
// This tier is not an optional extra. §9.2 rule 4 makes it the floor the whole
// system stands on: when the network is gone, the endpoint is down or the
// budget is spent, work has to land somewhere and keep going. So the
// priorities here are different from the remote executors':
//
//  • `isAvailable()` reads the filesystem and nothing else. It is on the
//    router's hot path, and a probe that could trigger a multi-gigabyte
//    download is not a probe.
//  • The weights stay resident between requests — a 6 GB load is not
//    something to repeat per turn — but they are released after an idle
//    period, because the same 16 GB is what analysis and the embedding model
//    need (§9.4, "โหลด/ปลดจากหน่วยความจำ").
//  • Everything the hosted protocol gives us for free has to be done by hand:
//    separating reasoning from the answer, honouring a response schema, and
//    enforcing a timeout on a call that never touches the network.
// ─────────────────────────────────────────────────────────────

public actor MLXExecutor: LLMExecutor {
    public nonisolated let identifier: String
    public nonisolated let tier: ModelTier = .localMLX
    public nonisolated let capabilities: LLMCapabilities

    private let model: LocalModel
    /// How long the weights may sit unused before they are given back.
    private let idleTimeout: Duration

    private var container: ModelContainer?
    private var inFlight = 0
    private var lastUsed = ContinuousClock.now
    private var idleWatcher: Task<Void, Never>?

    public init(model: LocalModel, idleTimeout: Duration = .seconds(600)) {
        self.model = model
        self.identifier = "mlx:\(model.name)"
        self.idleTimeout = idleTimeout
        self.capabilities = LLMCapabilities(
            contextWindow: model.contextWindow,
            // Read off the model's own chat template rather than assumed: a
            // template with no tool markup cannot emit a tool call, and saying
            // so lets the router send that work up a tier instead of
            // discovering the gap halfway through a turn.
            supportsTools: model.supportsTools,
            // No grammar or logit-constraint API exists in mlx-swift-lm, so
            // this is prompt-and-extract rather than guided generation. It is
            // still a promise: a request with a schema either comes back as
            // JSON or comes back as an error (see `StructuredOutput`).
            supportsStructuredOutput: true,
            supportsStreaming: true,
            supportsVision: false)
    }

    /// The weights are on disk. Deliberately does not check that they load:
    /// that costs minutes and gigabytes, and a load failure escalates through
    /// the router like any other error.
    public func isAvailable() async -> Bool {
        FileManager.default.fileExists(
            atPath: model.directory.appending(path: "config.json").path(percentEncoded: false))
    }

    public func prewarm() async {
        _ = try? await load()
    }

    /// Whether the weights are in memory right now — the UI's answer to "why
    /// was the first message slow and the rest fast".
    public var isResident: Bool { container != nil }

    public func unload() {
        let wasResident = container != nil
        container = nil
        idleWatcher?.cancel()
        idleWatcher = nil
        // Only when there was something to free. Touching MLX's allocator at
        // all is what turns "no model was ever loaded" into a hard crash under
        // `swift test`, where the Metal kernels cannot be found (E.13) — and
        // an executor that was never used is exactly the case a test hits.
        if wasResident { MLX.Memory.clearCache() }
    }

    // MARK: - generating

    public nonisolated func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try rejectIfUnsupported(request)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await self.generate(request, into: continuation) }
                        // Generation never touches the network, so nothing else
                        // will ever time it out. Prefill on a long prompt can
                        // sit for minutes before the first token, which is
                        // exactly when a caller needs the deadline honoured.
                        group.addTask {
                            try await Task.sleep(for: .seconds(request.timeout))
                            throw LLMError.timeout
                        }
                        try await group.next()
                        group.cancelAll()
                    }
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

    private func generate(_ request: LLMRequest,
                          into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        let container = try await load()
        inFlight += 1
        defer { finishedRequest() }

        // A schema request cannot stream: the JSON has to be found in the
        // finished text, so the answer is collected and emitted at the end.
        // Reasoning still streams — it is what shows the app is alive.
        let wantsJSON = request.responseSchema != nil
        let context = Self.templateContext(wantsJSON: wantsJSON)
        let session = ChatSession(
            container,
            instructions: Self.instructions(for: request),
            generateParameters: GenerateParameters(maxTokens: request.maxTokens,
                                                   temperature: Float(request.temperature)),
            additionalContext: context,
            tools: try Self.toolSpecs(for: request))

        // Asked of the template with the exact context this request uses:
        // turning thinking off changes whether the prompt leaves a `<think>`
        // block open, and a splitter told the wrong thing labels the whole
        // answer as reasoning or the whole thought as the answer.
        let opensReasoningBlock = await container.perform { model in
            ChatTemplate.opensReasoningBlock(model.tokenizer, additionalContext: context)
        }
        var splitter = ReasoningSplitter(startsInsideReasoning: opensReasoningBlock)
        var answer = ""
        var thoughts = ""
        var toolCalls = 0
        var finishReason = "stop"

        for try await generation in session.streamDetails(to: try Self.chat(from: request)) {
            try Task.checkCancellation()
            switch generation {
            case .chunk(let text):
                for segment in splitter.consume(text) {
                    switch segment {
                    case .answer(let value):
                        answer += value
                        if !wantsJSON { continuation.yield(.textDelta(value)) }
                    case .reasoning(let value):
                        thoughts += value
                        continuation.yield(.reasoningDelta(value))
                    }
                }
            case .toolCall(let call):
                toolCalls += 1
                continuation.yield(.toolCall(Self.toolCall(call, index: toolCalls)))
            case .info(let info):
                continuation.yield(.usage(.init(promptTokens: info.promptTokenCount,
                                                completionTokens: info.generationTokenCount)))
                finishReason = "\(info.stopReason)"
            }
        }
        for segment in splitter.flush() {
            switch segment {
            case .answer(let value):
                answer += value
                if !wantsJSON { continuation.yield(.textDelta(value)) }
            case .reasoning(let value):
                thoughts += value
                continuation.yield(.reasoningDelta(value))
            }
        }

        if let schema = request.responseSchema {
            // The answer first, then the thinking: a model that reasons its way
            // to the object and then runs out of budget before repeating it has
            // still produced it, and that is the same accommodation
            // `LLMCompletion.structuredText` makes for the hosted tiers.
            let json = StructuredOutput.firstJSONObject(in: answer)
                ?? StructuredOutput.firstJSONObject(in: thoughts)
            guard let json else {
                // Escalatable on purpose: a larger model on another tier can
                // very well produce the JSON this one failed to. Returning the
                // prose instead would hand the caller an empty decode, which
                // is how "no conflicts found" gets written for every document.
                let reason = finishReason == "length"
                    ? "ran out of tokens after \(request.maxTokens) — "
                        + "\(thoughts.count) chars of it spent thinking"
                    : String(answer.prefix(120))
                throw LLMError.unsupported(
                    "\(identifier) produced no JSON for schema \(schema.name): \(reason)")
            }
            continuation.yield(.textDelta(json))
        }
        continuation.yield(.finished(reason: toolCalls > 0 ? "tool_calls" : finishReason))
    }

    // MARK: - residency

    private func load() async throws -> ModelContainer {
        if let container { return container }
        do {
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: model.directory, using: ChatTokenizerLoader())
            container = loaded
            return loaded
        } catch {
            throw LLMError.unavailable("loading \(model.name): \(error)")
        }
    }

    private func finishedRequest() {
        inFlight -= 1
        lastUsed = .now
        scheduleIdleUnload()
    }

    /// Gives the RAM back when nothing has used the model for a while. On a
    /// 16 GB machine the alternative is that a 6 GB chat model and a 1 GB
    /// embedding model sit resident while an analysis run needs the space.
    private func scheduleIdleUnload() {
        idleWatcher?.cancel()
        idleWatcher = Task { [idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            self.unloadIfIdle()
        }
    }

    func unloadIfIdle() {
        guard inFlight == 0, lastUsed.duration(to: .now) >= idleTimeout else { return }
        unload()
    }

    // MARK: - translating our request into the model's own shape

    /// Turns thinking off for schema-constrained requests, on the templates
    /// that understand the switch.
    ///
    /// Measured on qwen3.5-9B: asked for a small routing object with 2,048
    /// tokens to work with, the model spent all of them deliberating and
    /// emitted no answer at all — 103 seconds for an empty string. There is
    /// nothing to think about in "fill in these two fields", and a tier that
    /// only works when the caller happens to allow a huge budget is not the
    /// floor §9.2 rule 4 needs. Templates that do not define the variable
    /// ignore it.
    private static func templateContext(wantsJSON: Bool) -> [String: any Sendable]? {
        wantsJSON ? ["enable_thinking": false] : nil
    }

    /// System turns become the session's instructions; the schema, when there
    /// is one, is another instruction, because nothing here can constrain
    /// decoding.
    private static func instructions(for request: LLMRequest) -> String? {
        var parts = request.messages.filter { $0.role == .system }.map(\.content)
        if let schema = request.responseSchema {
            parts.append(StructuredOutput.instruction(name: schema.name,
                                                      schemaJSON: schema.schemaJSON))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Everything that is not a system turn, in the library's own message type
    /// so the model's chat template renders it the way it was trained on —
    /// including the tool-call markup, which is what makes a local tool call
    /// possible at all.
    private static func chat(from request: LLMRequest) throws -> [Chat.Message] {
        try request.messages.compactMap { message in
            switch message.role {
            case .system:
                return nil
            case .user:
                return .user(message.content)
            case .assistant:
                return .assistant(message.content,
                                  toolCalls: message.toolCalls.isEmpty
                                      ? nil : try message.toolCalls.map(modelToolCall))
            case .tool:
                return .tool(message.content, id: message.toolCallID)
            }
        }
    }

    private static func modelToolCall(_ call: LLMToolCall) throws -> MLXLMCommon.ToolCall {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)))
            as? [String: Any] ?? [:]
        return MLXLMCommon.ToolCall(
            function: .init(name: call.name,
                            arguments: arguments.mapValues { JSONValue.from($0) }),
            id: call.id.isEmpty ? nil : call.id)
    }

    private static func toolCall(_ call: MLXLMCommon.ToolCall, index: Int) -> LLMToolCall {
        let arguments = (try? JSONEncoder().encode(call.function.arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // The id correlates the result message with the call. Local templates
        // often omit it, and a tool result with no id is one the next turn
        // cannot attach to anything.
        return LLMToolCall(id: call.id ?? "call_\(index)",
                           name: call.function.name,
                           argumentsJSON: arguments)
    }

    private static func toolSpecs(for request: LLMRequest) throws -> [ToolSpec]? {
        guard !request.tools.isEmpty else { return nil }
        return try request.tools.map { tool in
            let parsed = try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))
            guard let parameters = parsed as? [String: Any] else {
                throw LLMError.decoding("tool \(tool.name) has invalid parameter schema")
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": sendable(parameters),
                ] as [String: any Sendable],
            ]
        }
    }

    /// JSONSerialization hands back `Any`; the library wants `Sendable`. The
    /// values are all JSON scalars, so this is a re-typing, not a conversion.
    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(sendable)
        case let array as [Any]: return array.map(sendable)
        case let string as String: return string
        case let number as NSNumber:
            // `true` parses as an NSNumber too, and a schema whose
            // `"additionalProperties": false` renders as `0` is a different
            // schema. The type id is the only way to tell the two apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return number == NSNumber(value: number.intValue) ? number.intValue : number.doubleValue
        default: return String(describing: value)
        }
    }

    private static func map(_ error: Error) -> LLMError {
        .transport(String(describing: error).prefix(160).description)
    }
}
