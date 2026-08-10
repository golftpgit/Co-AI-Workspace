import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// VLLMExecutor — any OpenAI-compatible endpoint: vLLM on the GX10, LM Studio
// or llama.cpp on another machine, or a paid hosted API.
//
// Verified end to end before adoption: streaming, tool calls assembled from
// fragmented chunks, json_schema structured output, cancellation and
// concurrency (ARCHITECTURE E.9).
// ─────────────────────────────────────────────────────────────

public struct VLLMExecutor: LLMExecutor {
    let baseURL: URL
    let model: String
    let apiKey: String?
    public let identifier: String
    public let tier: ModelTier
    public let capabilities: LLMCapabilities

    public init(identifier: String? = nil,
                baseURL: URL,
                model: String,
                apiKey: String? = nil,
                tier: ModelTier = .selfHosted,
                capabilities: LLMCapabilities = .init(contextWindow: 32_768,
                                                      supportsTools: true,
                                                      supportsStructuredOutput: true,
                                                      supportsStreaming: true,
                                                      supportsVision: false)) {
        self.identifier = identifier ?? model
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.tier = tier
        self.capabilities = capabilities
    }

    /// Also validates the configured model name against the catalogue: an
    /// OpenAI-compatible server will happily answer for a model that does not
    /// exist, so an unchecked typo fails much later and confusingly
    /// (ARCHITECTURE E.9, case 8a).
    public func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.timeoutInterval = 3
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return false }
        return list.contains { ($0["id"] as? String) == model }
    }

    public func prewarm() async {
        var r = LLMRequest(messages: [.init(.user, "hi")])
        r.maxTokens = 1
        _ = try? await complete(r)
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
        if !req.tools.isEmpty { b["tools"] = req.tools.map(Self.wire) }
        if let rs = req.responseSchema {
            let schema = (try? JSONSerialization.jsonObject(with: Data(rs.schemaJSON.utf8))) ?? [:]
            b["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": rs.name, "strict": true, "schema": schema],
            ]
        }
        return b
    }

    /// OpenAI function-calling encoding. Kept here rather than on the shared
    /// tool type: it is this protocol's shape, not a universal one.
    private static func wire(_ tool: LLMToolSpec) -> [String: Any] {
        let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8)))
            ?? [String: Any]()
        return ["type": "function",
                "function": ["name": tool.name,
                             "description": tool.description,
                             "parameters": parameters]]
    }

    private func urlRequest(_ req: LLMRequest, stream: Bool) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        r.httpMethod = "POST"
        r.timeoutInterval = req.timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = apiKey { r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        // Foundation escapes "/" as "\/" by default, which mangles any path or
        // URL inside a prompt (see ARCHITECTURE App. C.0 for where this bit us).
        r.httpBody = try JSONSerialization.data(withJSONObject: body(req, stream: stream),
                                                options: [.withoutEscapingSlashes])
        return r
    }

    // MARK: streaming

    public func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try rejectIfUnsupported(request)
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

}
