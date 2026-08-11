import Testing
import Foundation
import AgentKit
@testable import LLMProviders

// ─────────────────────────────────────────────────────────────
// One contract, checked against every real executor.
//
// Stubs prove the router's logic; these prove the executors actually speak to
// the models. Each suite skips loudly when its backend is absent, because a
// silent skip reads exactly like a pass.
// ─────────────────────────────────────────────────────────────

private let lmStudio = URL(string: "http://127.0.0.1:1234/v1")!

/// Which model to test against is a property of the machine, not of the repo —
/// the same per-machine setting as `selfHostedEndpoint` in `bootstrap.plist`.
/// A pinned name meant every clone needed one specific multi-GB download, and
/// because the server answers for models it does not serve (ARCHITECTURE E.9,
/// case 8a) the mismatch showed up only in `isAvailable`. So ask the endpoint
/// what it has; `COAI_TEST_MODEL` picks one when a machine serves several.
private func servedModel() async -> String? {
    if let pinned = ProcessInfo.processInfo.environment["COAI_TEST_MODEL"], !pinned.isEmpty {
        return pinned
    }
    var request = URLRequest(url: lmStudio.appending(path: "models"))
    request.timeoutInterval = 2
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = obj["data"] as? [[String: Any]] else { return nil }
    // The catalogue does not say which entries are chat models, and an
    // embedding model would fail every test below for the wrong reason.
    return list.compactMap { $0["id"] as? String }
        .first { !$0.lowercased().contains("embed") }
}

private let routingSchema = #"""
{"type":"object",
 "properties":{"role":{"type":"string","enum":["researcher","analyst","engineer","writer"]},
               "needsClarification":{"type":"boolean"}},
 "required":["role","needsClarification"]}
"""#

@Suite("On-device executor (Tier 0)", .serialized)
struct OnDeviceExecutorTests {
    @Test("reports availability without throwing", .timeLimit(.minutes(1)))
    func availability() async {
        let executor = OnDeviceExecutor()
        _ = await executor.isAvailable()   // must not trap on machines without Apple Intelligence
        #expect(executor.tier == .onDevice)
        #expect(executor.capabilities.supportsStructuredOutput)
        // Declared honestly so the router escalates tool work rather than
        // discovering the gap mid-turn.
        #expect(executor.capabilities.supportsTools == false)
    }

    @Test("structured output comes back as decodable JSON", .timeLimit(.minutes(3)))
    func structuredOutput() async throws {
        let executor = OnDeviceExecutor()
        guard await executor.isAvailable() else {
            Issue.record("skipped: Apple Intelligence unavailable on this machine")
            return
        }

        var request = LLMRequest(messages: [
            .init(.system, "Route the request to a specialist in a research AI team."),
            .init(.user, "Fix a crash in main.swift on launch"),
        ])
        request.responseSchema = (name: "Routing", schemaJSON: routingSchema)
        request.maxTokens = 128

        do {
            let completion = try await executor.complete(request)
            let object = try #require(
                try? JSONSerialization.jsonObject(with: Data(completion.text.utf8)) as? [String: Any])
            let role = try #require(object["role"] as? String)
            #expect(["researcher", "analyst", "engineer", "writer"].contains(role))
            #expect(object["needsClarification"] is Bool)
        } catch let error as LLMError {
            // A refusal here is expected behaviour, not a test failure — it is
            // precisely why the router escalates (ARCHITECTURE E.7).
            guard case .refused = error else { throw error }
        }
    }

    @Test("tool requests are rejected up front, not part-way through", .timeLimit(.minutes(1)))
    func rejectsToolsEarly() async {
        let executor = OnDeviceExecutor()
        var request = LLMRequest(messages: [.init(.user, "hi")])
        request.tools = [LLMToolSpec(name: "t", description: "d",
                                     parametersJSON: #"{"type":"object","properties":{}}"#)]

        await #expect(throws: LLMError.self) { _ = try await executor.complete(request) }
    }
}

@Suite("OpenAI-compatible executor (Tier 1)", .serialized)
struct VLLMExecutorTests {
    private func executor(_ model: String) -> VLLMExecutor {
        VLLMExecutor(baseURL: lmStudio, model: model)
    }

    @Test("availability also validates the configured model name", .timeLimit(.minutes(1)))
    func availabilityChecksModel() async {
        guard let model = await servedModel() else {
            Issue.record("skipped: no OpenAI-compatible endpoint on :1234")
            return
        }
        #expect(await executor(model).isAvailable())

        // A server will answer for a model that does not exist, so the check
        // has to be ours (ARCHITECTURE E.9, case 8a).
        let typo = VLLMExecutor(baseURL: lmStudio, model: "no-such-model-xyz")
        #expect(await typo.isAvailable() == false)
    }

    @Test("streams deltas and reports usage", .timeLimit(.minutes(3)))
    func streamsAndAccounts() async throws {
        guard let model = await servedModel() else {
            Issue.record("skipped: no OpenAI-compatible endpoint on :1234")
            return
        }
        var request = LLMRequest(messages: [.init(.user, "Count from 1 to 10, comma separated.")])
        // Enough room for a reasoning model to think *and* answer. 80 produced
        // nothing at all; 512 was still not always enough for qwen3.5 to finish
        // thinking about counting to ten, which is a fact about reasoning
        // models rather than about the executor.
        request.maxTokens = 2_048

        var deltas = 0
        var thoughts = 0
        var usage: LLMUsage?
        for try await event in executor(model).respond(to: request) {
            switch event {
            case .textDelta: deltas += 1
            case .reasoningDelta: thoughts += 1
            case .usage(let u): usage = u
            default: break
            }
        }
        // Either kind proves the stream is arriving in pieces; a reasoning
        // model legitimately sends thoughts first.
        #expect(deltas + thoughts > 1, "expected streaming, got \(deltas) delta(s)")
        #expect(deltas > 0, "the answer itself never arrived")
        #expect(usage?.promptTokens ?? 0 > 0)
    }

    /// The chunks a reasoning model streams before it answers are not the
    /// answer. Merging them would store thinking as the reply and break any
    /// request with a response schema.
    @Test("reasoning is reported apart from the answer", .timeLimit(.minutes(3)))
    func reasoningIsSeparate() async throws {
        guard let model = await servedModel() else {
            Issue.record("skipped: no OpenAI-compatible endpoint on :1234")
            return
        }
        var request = LLMRequest(messages: [
            .init(.user, "What is 17 times 3? Reply with the number only."),
        ])
        request.maxTokens = 512

        let completion = try await executor(model).complete(request)

        // Holds either way, and it is the property that actually broke: with
        // reasoning folded into `content` the answer came back empty.
        #expect(completion.text.contains("51"),
                "answer was: \(completion.text.prefix(200))")
        // Only a model that reasons out loud can demonstrate the separation.
        // Not every machine serves one, so this is a conditional check rather
        // than a skip — the assertion above still runs everywhere.
        if !completion.reasoning.isEmpty {
            #expect(!completion.text.contains(completion.reasoning),
                    "reasoning leaked into the answer: \(completion.text.prefix(200))")
        }
    }

    @Test("assembles tool calls from fragmented chunks", .timeLimit(.minutes(3)))
    func assemblesToolCalls() async throws {
        guard let model = await servedModel() else {
            Issue.record("skipped: no OpenAI-compatible endpoint on :1234")
            return
        }
        var request = LLMRequest(messages: [
            .init(.system, "Use tools when asked about cohort sizes."),
            .init(.user, "How many patients are in the diabetes cohort?"),
        ])
        request.tools = [LLMToolSpec(
            name: "lookup_patient_count",
            description: "Look up how many patients are in a named cohort",
            parametersJSON: #"{"type":"object","properties":{"cohort":{"type":"string"}},"required":["cohort"]}"#)]

        let completion = try await executor(model).complete(request)
        let call = try #require(completion.toolCalls.first)
        #expect(call.name == "lookup_patient_count")
        // Fragments must reassemble into valid JSON, not a truncated string.
        #expect((try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) != nil,
                "arguments did not reassemble: \(call.argumentsJSON)")
    }

    @Test("a dead endpoint fails fast with a legible error", .timeLimit(.minutes(1)))
    func deadEndpoint() async {
        var request = LLMRequest(messages: [.init(.user, "hi")])
        request.timeout = 3
        let dead = VLLMExecutor(baseURL: URL(string: "http://127.0.0.1:9/v1")!, model: "x")
        await #expect(throws: LLMError.self) { _ = try await dead.complete(request) }
    }
}

@Suite("Router over real backends", .serialized)
struct LiveRoutingTests {
    /// The end-to-end shape of §9.2: cheap work locally, escalation upward
    /// when the local tier cannot or will not serve it.
    @Test("a live chain answers even when Tier 0 refuses", .timeLimit(.minutes(4)))
    func liveChain() async throws {
        guard let model = await servedModel() else {
            Issue.record("skipped: no OpenAI-compatible endpoint on :1234")
            return
        }
        let router = ModelRouter(executors: [
            OnDeviceExecutor(),
            VLLMExecutor(baseURL: lmStudio, model: model),
        ])

        var request = LLMRequest(messages: [
            .init(.system, "Route the request to a specialist in a research AI team."),
            .init(.user, "ช่วยหางานวิจัยเรื่องวัคซีน mRNA ในผู้สูงอายุ"),
        ])
        request.responseSchema = (name: "Routing", schemaJSON: routingSchema)
        // Room for a reasoning model on Tier 1 to think before the JSON.
        request.maxTokens = 512

        let completion = try await router.complete(request)
        #expect(!completion.text.isEmpty)
        #expect((try? JSONSerialization.jsonObject(with: Data(completion.text.utf8))) != nil,
                "expected JSON from whichever tier answered: \(completion.text.prefix(120))")
    }
}
