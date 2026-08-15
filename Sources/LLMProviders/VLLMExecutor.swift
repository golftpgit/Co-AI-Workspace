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

/// The model name this endpoint is serving right now (§17.1, P15.1).
///
/// A box rather than a stored property because `VLLMExecutor` is a value and
/// the answer arrives from the network. Locked rather than an actor: it is read
/// on the path of every request, and an actor hop per request to read a string
/// is a cost with nothing on the other side of it.
final class ServedModelName: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?

    func current() -> String? { lock.withLock { name } }
    func remember(_ value: String) { lock.withLock { name = value } }
    /// Forgotten after the server refuses a request, so a checkpoint swapped
    /// while the app is running is re-read rather than retried forever against
    /// a name that is no longer there.
    func forget() { lock.withLock { name = nil } }
}

public struct VLLMExecutor: LLMExecutor {
    let baseURL: URL
    /// What the config asked for. **Empty means "whatever this server serves"**,
    /// which is the setting that survives a checkpoint swap — the name changes,
    /// and a config that pinned the old one would take the endpoint out of the
    /// chain with nothing on screen saying why.
    let model: String
    private let resolved = ServedModelName()
    let apiKey: String?
    public let identifier: String
    public let tier: ModelTier
    public let capabilities: LLMCapabilities
    public let price: TokenPrice?

    public init(identifier: String? = nil,
                baseURL: URL,
                model: String,
                apiKey: String? = nil,
                tier: ModelTier = .selfHosted,
                price: TokenPrice? = nil,
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
        self.price = price
        self.capabilities = capabilities
    }

    /// Also validates the configured model name against the catalogue: an
    /// OpenAI-compatible server will happily answer for a model that does not
    /// exist, so an unchecked typo fails much later and confusingly
    /// (ARCHITECTURE E.9, case 8a).
    ///
    /// With no name configured this is where the served one is learned, so an
    /// endpoint that was down at launch works as soon as it comes up — the
    /// router asks this before every escalation anyway.
    public func isAvailable() async -> Bool {
        (try? await resolveModel()) != nil
    }

    /// The name to put in the request body.
    ///
    /// Asked of the server when the config left it blank, then kept. `nil` from
    /// the server is not the same as a wrong name, so an unreachable endpoint
    /// throws `unavailable` here rather than sending a request naming nothing.
    func resolveModel() async throws -> String {
        if let cached = resolved.current() { return cached }

        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.timeoutInterval = 3
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            throw LLMError.unavailable("\(identifier) ตอบ /v1/models ไม่ได้")
        }
        let served = list.compactMap { $0["id"] as? String }
        let wanted = model.trimmingCharacters(in: .whitespaces)

        if wanted.isEmpty {
            // One model: it is the one. Several: refuse rather than pick —
            // guessing on a server with two hundred models is how a cheap
            // request lands on an expensive model.
            guard served.count == 1 else {
                throw LLMError.unavailable(served.isEmpty
                    ? "\(identifier) ไม่ได้เสิร์ฟโมเดลไหนเลย"
                    : "\(identifier) เสิร์ฟหลายโมเดล — ต้องระบุชื่อในหน้าตั้งค่า")
            }
            resolved.remember(served[0])
            return served[0]
        }
        guard served.contains(wanted) else {
            throw LLMError.unavailable("\(identifier) ไม่ได้เสิร์ฟโมเดลชื่อ \(wanted)")
        }
        resolved.remember(wanted)
        return wanted
    }

    public func prewarm() async {
        var r = LLMRequest(messages: [.init(.user, "hi")])
        r.maxTokens = 1
        _ = try? await complete(r)
    }

    // MARK: request building

    private func body(_ req: LLMRequest, stream: Bool, model: String) -> [String: Any] {
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

    private func urlRequest(_ req: LLMRequest, stream: Bool) async throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        r.httpMethod = "POST"
        r.timeoutInterval = req.timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = apiKey { r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        // Foundation escapes "/" as "\/" by default, which mangles any path or
        // URL inside a prompt (see ARCHITECTURE App. C.0 for where this bit us).
        let model = try await resolveModel()
        r.httpBody = try JSONSerialization.data(
            withJSONObject: body(req, stream: stream, model: model),
            options: [.withoutEscapingSlashes])
        return r
    }

    // MARK: streaming

    public func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try rejectIfUnsupported(request)
                    let urlReq = try await urlRequest(request, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlReq)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.transport("no HTTPURLResponse")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 400 { break } }
                        // The name we asked for is one of the things a 4xx can
                        // be about, and a checkpoint can be swapped while the
                        // app is running. Forgetting it costs one extra request
                        // on the next turn; keeping it costs every turn after
                        // the swap (§17.1, P15.1).
                        if (400..<500).contains(http.statusCode) { resolved.forget() }
                        throw LLMError.http(status: http.statusCode, body: body)
                    }

                    // tool_calls arrive fragmented across chunks — assemble by index
                    var toolAcc: [Int: (id: String, name: String, args: String)] = [:]
                    var finish = "unknown"
                    // The server splits thinking from the answer only if it was
                    // started with a reasoning parser. Without the flag the
                    // `<think>` tags come down inside `content` exactly as a
                    // local model's do — measured here twice (E.21) — so the
                    // same splitter runs over this stream too (P15.2b). It is a
                    // no-op on a server that does its own splitting: no tags,
                    // nothing to cut.
                    var splitter = ReasoningSplitter(startsInsideReasoning: false)

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
                            for segment in splitter.consume(text) {
                                switch segment {
                                case .answer(let answer): continuation.yield(.textDelta(answer))
                                case .reasoning(let thought):
                                    continuation.yield(.reasoningDelta(thought))
                                }
                            }
                        }
                        // Reasoning models spend their whole budget here before
                        // saying a word: dropping these chunks makes the app look
                        // frozen, and with a small max_tokens it answers nothing
                        // at all. `reasoning_content` is LM Studio/vLLM/Qwen;
                        // `reasoning` is the DeepSeek and OpenRouter spelling.
                        if let thought = (delta["reasoning_content"] ?? delta["reasoning"]) as? String,
                           !thought.isEmpty {
                            continuation.yield(.reasoningDelta(thought))
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

                    // Whatever the splitter was still holding back in case it
                    // turned out to be half a tag. A truncated tag is text the
                    // model really produced, and dropping it would lose the end
                    // of an answer without saying so.
                    for segment in splitter.flush() {
                        switch segment {
                        case .answer(let answer): continuation.yield(.textDelta(answer))
                        case .reasoning(let thought): continuation.yield(.reasoningDelta(thought))
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
                    guard ns.code != NSURLErrorTimedOut else {
                        continuation.finish(throwing: LLMError.timeout)
                        return
                    }
                    // A cable pulled mid-answer arrives here, and it used to
                    // arrive on screen as Foundation's English sentence inside a
                    // Thai one: "สตรีมคำตอบขาดกลางคัน: Error Domain=NSURL…
                    // Code=-1005". Classified here, where the `URLError` still
                    // exists — one hop later it is a string and nothing can be
                    // said about it (§P9.4, P15.1). Anything `ReadableFailure`
                    // cannot classify is passed through unchanged rather than
                    // flattened into "ไม่สำเร็จ".
                    continuation.finish(throwing: LLMError.transport(
                        ReadableFailure.message(for: error, doing: identifier)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}
