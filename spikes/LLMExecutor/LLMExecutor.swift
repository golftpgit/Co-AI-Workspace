import Foundation

// ─────────────────────────────────────────────────────────────
// LLMExecutor — our own abstraction (ARCHITECTURE §9.1).
// Shape deliberately mirrors Apple's LanguageModelExecutor so the
// macOS 27 provider API can be dropped in behind it later.
// ─────────────────────────────────────────────────────────────

public struct LLMCapabilities: Sendable {
    public init(contextWindow: Int, supportsTools: Bool, supportsStructuredOutput: Bool,
                supportsStreaming: Bool, supportsVision: Bool) {
        self.contextWindow = contextWindow; self.supportsTools = supportsTools
        self.supportsStructuredOutput = supportsStructuredOutput
        self.supportsStreaming = supportsStreaming; self.supportsVision = supportsVision
    }
    public let contextWindow: Int
    public let supportsTools: Bool
    public let supportsStructuredOutput: Bool
    public let supportsStreaming: Bool
    public let supportsVision: Bool
}

public struct LLMToolSpec: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments object, as JSON text.
    /// (Swift 6 forbids [String: Any] across concurrency boundaries — see ARCHITECTURE App. C.)
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name; self.description = description; self.parametersJSON = parametersJSON
    }

    var wire: [String: Any] {
        let params = (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) ?? [:]
        return ["type": "function",
                "function": ["name": name, "description": description, "parameters": params]]
    }
}

public struct LLMMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    /// Set on `.tool` messages: which call this is the result of.
    public let toolCallID: String?
    /// Set on `.assistant` messages that requested tools. The OpenAI protocol
    /// REQUIRES echoing the original tool_calls back, not just the id —
    /// omitting it makes the model return an empty final answer.
    public let toolCalls: [LLMToolCall]

    public init(_ role: Role, _ content: String,
                toolCallID: String? = nil, toolCalls: [LLMToolCall] = []) {
        self.role = role; self.content = content
        self.toolCallID = toolCallID; self.toolCalls = toolCalls
    }
}

public struct LLMRequest: Sendable {
    public var messages: [LLMMessage]
    public var tools: [LLMToolSpec] = []
    public var maxTokens: Int = 512
    public var temperature: Double = 0.2
    /// JSON Schema as text — the Tier-1 analogue of @Generable.
    public var responseSchema: (name: String, schemaJSON: String)? = nil
    public var timeout: Double = 120

    public init(messages: [LLMMessage]) { self.messages = messages }
}

public struct LLMToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
}

public struct LLMUsage: Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public var total: Int { promptTokens + completionTokens }
}

public enum LLMEvent: Sendable {
    case textDelta(String)
    case toolCall(LLMToolCall)
    case usage(LLMUsage)
    case finished(reason: String)
}

public enum LLMError: Error, CustomStringConvertible {
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)
    case timeout
    case cancelled

    public var description: String {
        switch self {
        case .http(let s, let b): return "http(\(s)): \(b.prefix(80))"
        case .transport(let m): return "transport: \(m.prefix(80))"
        case .decoding(let m): return "decoding: \(m.prefix(80))"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        }
    }
}

public protocol LLMExecutor: Sendable {
    var capabilities: LLMCapabilities { get }
    func prewarm() async
    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

// ─────────────────────────────────────────────────────────────
// VLLMExecutor — OpenAI-compatible endpoint (vLLM on GX10,
// LM Studio, Ollama, llama.cpp — anything that speaks the API).
// ─────────────────────────────────────────────────────────────

public struct VLLMExecutor: LLMExecutor {
    let baseURL: URL
    let model: String
    let apiKey: String?
    public let capabilities: LLMCapabilities

    public init(baseURL: URL, model: String, apiKey: String? = nil,
                capabilities: LLMCapabilities = .init(contextWindow: 32768,
                                                      supportsTools: true,
                                                      supportsStructuredOutput: true,
                                                      supportsStreaming: true,
                                                      supportsVision: false)) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey
        self.capabilities = capabilities
    }

    public func prewarm() async {
        var r = LLMRequest(messages: [.init(.user, "hi")])
        r.maxTokens = 1
        _ = try? await collectText(r)
    }

    // MARK: request building

    private func body(_ req: LLMRequest, stream: Bool) -> [String: Any] {
        var msgs: [[String: Any]] = []
        for m in req.messages {
            var d: [String: Any] = ["role": m.role.rawValue, "content": m.content]
            if let id = m.toolCallID { d["tool_call_id"] = id }
            if !m.toolCalls.isEmpty {
                d["tool_calls"] = m.toolCalls.map {
                    ["id": $0.id, "type": "function",
                     "function": ["name": $0.name, "arguments": $0.argumentsJSON]]
                }
            }
            msgs.append(d)
        }
        var b: [String: Any] = [
            "model": model,
            "messages": msgs,
            "max_tokens": req.maxTokens,
            "temperature": req.temperature,
            "stream": stream,
        ]
        if stream { b["stream_options"] = ["include_usage": true] }
        if !req.tools.isEmpty { b["tools"] = req.tools.map(\.wire) }
        if let rs = req.responseSchema {
            let schema = (try? JSONSerialization.jsonObject(with: Data(rs.schemaJSON.utf8))) ?? [:]
            b["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": rs.name, "strict": true, "schema": schema],
            ]
        }
        return b
    }

    private func urlRequest(_ req: LLMRequest, stream: Bool) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        r.httpMethod = "POST"
        r.timeoutInterval = req.timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = apiKey { r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        r.httpBody = try JSONSerialization.data(withJSONObject: body(req, stream: stream))
        return r
    }

    // MARK: streaming

    public func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlReq = try urlRequest(request, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlReq)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.transport("no HTTPURLResponse")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 400 { break } }
                        throw LLMError.http(status: http.statusCode, body: body)
                    }

                    // tool_calls arrive fragmented across chunks — assemble by index
                    var toolAcc: [Int: (id: String, name: String, args: String)] = [:]
                    var finish = "unknown"

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }   // malformed chunk: skip, never crash

                        if let u = obj["usage"] as? [String: Any] {
                            continuation.yield(.usage(.init(
                                promptTokens: u["prompt_tokens"] as? Int ?? 0,
                                completionTokens: u["completion_tokens"] as? Int ?? 0)))
                        }
                        guard let choices = obj["choices"] as? [[String: Any]], let c = choices.first
                        else { continue }
                        if let fr = c["finish_reason"] as? String { finish = fr }
                        guard let delta = c["delta"] as? [String: Any] else { continue }

                        if let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                        if let tcs = delta["tool_calls"] as? [[String: Any]] {
                            for tc in tcs {
                                let idx = tc["index"] as? Int ?? 0
                                var acc = toolAcc[idx] ?? (id: "", name: "", args: "")
                                if let id = tc["id"] as? String, !id.isEmpty { acc.id = id }
                                if let fn = tc["function"] as? [String: Any] {
                                    if let n = fn["name"] as? String, !n.isEmpty { acc.name = n }
                                    if let a = fn["arguments"] as? String { acc.args += a }
                                }
                                toolAcc[idx] = acc
                            }
                        }
                    }

                    for (_, acc) in toolAcc.sorted(by: { $0.key < $1.key }) where !acc.name.isEmpty {
                        continuation.yield(.toolCall(.init(id: acc.id, name: acc.name, argumentsJSON: acc.args)))
                    }
                    continuation.yield(.finished(reason: finish))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch let e as LLMError {
                    continuation.finish(throwing: e)
                } catch {
                    let ns = error as NSError
                    continuation.finish(throwing: ns.code == NSURLErrorTimedOut
                                        ? LLMError.timeout : LLMError.transport("\(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: non-streaming convenience

    public struct Completion: Sendable {
        public let text: String
        public let toolCalls: [LLMToolCall]
        public let usage: LLMUsage?
        public let finishReason: String
    }

    public func complete(_ request: LLMRequest) async throws -> Completion {
        let urlReq = try urlRequest(request, stream: false)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: urlReq) }
        catch {
            let ns = error as NSError
            throw ns.code == NSURLErrorTimedOut ? LLMError.timeout : LLMError.transport("\(error)")
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.transport("no HTTPURLResponse") }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]], let c = choices.first,
              let msg = c["message"] as? [String: Any]
        else { throw LLMError.decoding(String(data: data, encoding: .utf8) ?? "?") }

        var calls: [LLMToolCall] = []
        if let tcs = msg["tool_calls"] as? [[String: Any]] {
            for tc in tcs {
                guard let fn = tc["function"] as? [String: Any], let n = fn["name"] as? String else { continue }
                calls.append(.init(id: tc["id"] as? String ?? "",
                                   name: n,
                                   argumentsJSON: fn["arguments"] as? String ?? "{}"))
            }
        }
        var usage: LLMUsage? = nil
        if let u = obj["usage"] as? [String: Any] {
            usage = .init(promptTokens: u["prompt_tokens"] as? Int ?? 0,
                          completionTokens: u["completion_tokens"] as? Int ?? 0)
        }
        return .init(text: msg["content"] as? String ?? "",
                     toolCalls: calls,
                     usage: usage,
                     finishReason: c["finish_reason"] as? String ?? "unknown")
    }

    func collectText(_ request: LLMRequest) async throws -> String {
        var out = ""
        for try await ev in respond(to: request) {
            if case .textDelta(let t) = ev { out += t }
        }
        return out
    }
}
