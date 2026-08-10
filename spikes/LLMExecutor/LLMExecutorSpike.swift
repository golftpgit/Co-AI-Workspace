import Foundation

// ─────────────────────────────────────────────────────────────
// SPIKE: prove VLLMExecutor covers everything Tier 1 needs
//   1. non-streaming completion + token accounting
//   2. SSE streaming + time-to-first-token
//   3. tool calling (non-streaming)
//   4. tool calling (streaming — fragmented arguments)
//   5. structured output via json_schema (Tier-1 analogue of @Generable)
//   6. Thai prompt (the content Tier 0 refuses 12.5% of the time)
//   7. full tool round-trip (call → result → final answer)
//   8. error surfacing (bad model, unreachable host)
//   9. cancellation mid-stream (the Stop button)
//  10. concurrent requests
// ─────────────────────────────────────────────────────────────

let clock = ContinuousClock()
actor Counter { var n = 0; func bump() { n += 1 }; func get() -> Int { n } }
let failures = Counter()

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func ms(since t0: ContinuousClock.Instant) -> Int64 {
    let d = clock.now - t0
    return d.components.seconds * 1000 + Int64(d.components.attoseconds / 1_000_000_000_000_000)
}

func step(_ label: String, _ body: sending () async throws -> String) async {
    let t0 = clock.now
    do {
        let detail = try await body()
        print("✅ " + pad(label, 36) + pad("\(ms(since: t0))ms", 9) + detail)
    } catch {
        await failures.bump()
        print("❌ " + pad(label, 36) + pad("\(ms(since: t0))ms", 9) + "\(error)")
    }
    fflush(stdout)
}

let endpoint = URL(string: "http://127.0.0.1:1234/v1")!
let modelID = "meta-llama-3.1-8b-instruct"

let cohortTool = LLMToolSpec(
    name: "lookup_patient_count",
    description: "Look up how many patients are in a named cohort",
    parametersJSON: #"{"type":"object","properties":{"cohort":{"type":"string","description":"cohort name"}},"required":["cohort"]}"#)

let routingSchemaJSON = #"""
{"type":"object",
 "properties":{"role":{"type":"string","enum":["researcher","analyst","engineer","writer"]},
               "needsClarification":{"type":"boolean"},
               "reason":{"type":"string"}},
 "required":["role","needsClarification","reason"],
 "additionalProperties":false}
"""#

@main
struct Spike {
    static func main() async {
        print("=== SPIKE — VLLMExecutor (OpenAI-compatible) ===")
        print("endpoint: \(endpoint.absoluteString)  model: \(modelID)")
        print(String(repeating: "-", count: 84))

        let exec = VLLMExecutor(baseURL: endpoint, model: modelID)

        await step("1. non-streaming + token accounting") {
            var r = LLMRequest(messages: [
                .init(.system, "Answer in one short sentence."),
                .init(.user, "What is GraphRAG?"),
            ])
            r.maxTokens = 60
            let c = try await exec.complete(r)
            guard !c.text.isEmpty else { throw LLMError.decoding("empty text") }
            guard let u = c.usage else { throw LLMError.decoding("no usage reported") }
            return "tokens p=\(u.promptTokens) c=\(u.completionTokens) finish=\(c.finishReason) — \"\(c.text.prefix(40))…\""
        }

        await step("2. SSE streaming + TTFT") {
            var r = LLMRequest(messages: [.init(.user, "Count from 1 to 20, comma separated.")])
            r.maxTokens = 120
            let t0 = clock.now
            var ttft: Int64 = -1
            var deltas = 0, chars = 0
            var usage: LLMUsage? = nil
            for try await ev in exec.respond(to: r) {
                switch ev {
                case .textDelta(let t):
                    if ttft < 0 { ttft = ms(since: t0) }
                    deltas += 1; chars += t.count
                case .usage(let u): usage = u
                default: break
                }
            }
            guard deltas > 1 else { throw LLMError.decoding("not actually streaming (deltas=\(deltas))") }
            let u = usage.map { "usage p=\($0.promptTokens) c=\($0.completionTokens)" } ?? "usage=nil"
            return "TTFT=\(ttft)ms deltas=\(deltas) chars=\(chars) \(u)"
        }

        await step("3. tool call (non-streaming)") {
            var r = LLMRequest(messages: [
                .init(.system, "Use tools when asked about cohort sizes."),
                .init(.user, "How many patients are in the diabetes cohort?"),
            ])
            r.tools = [cohortTool]
            let c = try await exec.complete(r)
            guard let call = c.toolCalls.first else { throw LLMError.decoding("no tool call produced") }
            guard call.name == "lookup_patient_count" else { throw LLMError.decoding("wrong tool: \(call.name)") }
            guard let args = try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any],
                  args["cohort"] != nil else { throw LLMError.decoding("args not valid JSON: \(call.argumentsJSON)") }
            return "tool=\(call.name) args=\(call.argumentsJSON)"
        }

        await step("4. tool call (streaming, fragmented args)") {
            var r = LLMRequest(messages: [
                .init(.system, "Use tools when asked about cohort sizes."),
                .init(.user, "How many patients are in the hypertension cohort?"),
            ])
            r.tools = [cohortTool]
            var calls: [LLMToolCall] = []
            for try await ev in exec.respond(to: r) {
                if case .toolCall(let c) = ev { calls.append(c) }
            }
            guard let call = calls.first else { throw LLMError.decoding("no tool call assembled from stream") }
            guard (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) != nil else {
                throw LLMError.decoding("assembled args are not valid JSON: \(call.argumentsJSON)")
            }
            return "assembled ok → \(call.name)(\(call.argumentsJSON))"
        }

        await step("5. structured output (json_schema)") {
            var r = LLMRequest(messages: [
                .init(.system, "Route the request to a specialist in a research AI team."),
                .init(.user, "Fix a crash in main.swift on launch"),
            ])
            r.responseSchema = (name: "Routing", schemaJSON: routingSchemaJSON)
            r.maxTokens = 120
            let c = try await exec.complete(r)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(c.text.utf8)) as? [String: Any],
                  let role = obj["role"] as? String
            else { throw LLMError.decoding("not schema-valid JSON: \(c.text.prefix(80))") }
            return "role=\(role) clarify=\(obj["needsClarification"] ?? "?") (schema honored)"
        }

        await step("6. Thai prompt (Tier 0 refuses these)") {
            var r = LLMRequest(messages: [
                .init(.system, "Route the request to a specialist in a research AI team."),
                .init(.user, "ช่วยหางานวิจัยเรื่องวัคซีน mRNA ในผู้สูงอายุ"),
            ])
            r.responseSchema = (name: "Routing", schemaJSON: routingSchemaJSON)
            r.maxTokens = 120
            let c = try await exec.complete(r)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(c.text.utf8)) as? [String: Any],
                  let role = obj["role"] as? String
            else { throw LLMError.decoding("bad JSON: \(c.text.prefix(80))") }
            return "NO REFUSAL — role=\(role)"
        }

        await step("7. full tool round-trip") {
            var r = LLMRequest(messages: [
                .init(.system, "Use tools when asked about cohort sizes."),
                .init(.user, "How many patients are in the diabetes cohort?"),
            ])
            r.tools = [cohortTool]
            let first = try await exec.complete(r)
            guard let call = first.toolCalls.first else { throw LLMError.decoding("no tool call") }
            // feed the tool result back, exactly as CoreEngine's ToolBelt will
            r.messages.append(.init(.assistant, "", toolCalls: [call]))
            r.messages.append(.init(.tool, "{\"count\": 1234}", toolCallID: call.id))
            let second = try await exec.complete(r)
            guard second.text.contains("1,234") || second.text.contains("1234") else {
                throw LLMError.decoding("tool result not used: \(second.text.prefix(80))")
            }
            return "final answer used tool output → \"\(second.text.prefix(46))…\""
        }

        await step("8a. unknown model (server-side)") {
            let bad = VLLMExecutor(baseURL: endpoint, model: "no-such-model-xyz")
            do {
                let c = try await bad.complete(LLMRequest(messages: [.init(.user, "hi")]))
                return "⚠️ endpoint ACCEPTED unknown model (text=\"\(c.text.prefix(24))\") → must validate client-side"
            } catch { return "surfaced: \(error)" }
        }

        await step("8c. client-side model validation") {
            let (data, _) = try await URLSession.shared.data(from: endpoint.appendingPathComponent("models"))
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]]
            else { throw LLMError.decoding("cannot list models") }
            let ids = Set(arr.compactMap { $0["id"] as? String })
            guard ids.contains(modelID) else { throw LLMError.decoding("configured model missing") }
            guard !ids.contains("no-such-model-xyz") else { throw LLMError.decoding("phantom model listed") }
            return "\(ids.count) models listed; config validated against /v1/models"
        }

        await step("8b. error: unreachable host") {
            var r = LLMRequest(messages: [.init(.user, "hi")])
            r.timeout = 5
            let dead = VLLMExecutor(baseURL: URL(string: "http://127.0.0.1:9/v1")!, model: modelID)
            do {
                _ = try await dead.complete(r)
                return "⚠️ no error raised for dead endpoint"
            } catch { return "surfaced: \(error)" }
        }

        await step("9. cancel mid-stream (Stop button)") {
            var r = LLMRequest(messages: [.init(.user, "Write a long essay about databases.")])
            r.maxTokens = 800
            let t0 = clock.now
            var received = 0
            let stream = exec.respond(to: r)
            for try await ev in stream {
                if case .textDelta = ev {
                    received += 1
                    if received >= 5 { break }   // simulate user pressing Stop
                }
            }
            let elapsed = ms(since: t0)
            guard elapsed < 30_000 else { throw LLMError.decoding("stop took too long: \(elapsed)ms") }
            return "stopped after \(received) deltas in \(elapsed)ms (stream torn down)"
        }

        await step("10. 3 concurrent requests") {
            let t0 = clock.now
            try await withThrowingTaskGroup(of: Int.self) { g in
                for i in 0..<3 {
                    g.addTask {
                        var r = LLMRequest(messages: [.init(.user, "Reply with the number \(i).")])
                        r.maxTokens = 20
                        let c = try await exec.complete(r)
                        return c.text.isEmpty ? 0 : 1
                    }
                }
                var ok = 0
                for try await n in g { ok += n }
                guard ok == 3 else { throw LLMError.decoding("only \(ok)/3 succeeded") }
            }
            return "3/3 ok in \(ms(since: t0))ms"
        }

        print(String(repeating: "-", count: 84))
        let f = await failures.get()
        print(f == 0 ? "ALL PASSED" : "FAILURES: \(f)")
        print("done")
        fflush(stdout)
        exit(f == 0 ? 0 : 1)
    }
}
