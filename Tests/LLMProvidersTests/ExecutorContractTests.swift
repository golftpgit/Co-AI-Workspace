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

private func lmStudioAvailable() async -> Bool {
    var request = URLRequest(url: lmStudio.appending(path: "models"))
    request.timeoutInterval = 2
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
    return (response as? HTTPURLResponse)?.statusCode == 200
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
    private func executor() -> VLLMExecutor {
        VLLMExecutor(baseURL: lmStudio, model: "meta-llama-3.1-8b-instruct")
    }

    @Test("availability also validates the configured model name", .timeLimit(.minutes(1)))
    func availabilityChecksModel() async {
        guard await lmStudioAvailable() else {
            Issue.record("skipped: no OpenAI-compatible endpoint on :1234")
            return
        }
        #expect(await executor().isAvailable())

        // A server will answer for a model that does not exist, so the check
        // has to be ours (ARCHITECTURE E.9, case 8a).
        let typo = VLLMExecutor(baseURL: lmStudio, model: "no-such-model-xyz")
        #expect(await typo.isAvailable() == false)
    }

    @Test("streams deltas and reports usage", .timeLimit(.minutes(3)))
    func streamsAndAccounts() async throws {
        guard await lmStudioAvailable() else {
            Issue.record("skipped: no OpenAI-compatible endpoint on :1234")
            return
        }
        var request = LLMRequest(messages: [.init(.user, "Count from 1 to 10, comma separated.")])
        request.maxTokens = 80

        var deltas = 0
        var usage: LLMUsage?
        for try await event in executor().respond(to: request) {
            switch event {
            case .textDelta: deltas += 1
            case .usage(let u): usage = u
            default: break
            }
        }
        #expect(deltas > 1, "expected streaming, got \(deltas) delta(s)")
        #expect(usage?.promptTokens ?? 0 > 0)
    }

    @Test("assembles tool calls from fragmented chunks", .timeLimit(.minutes(3)))
    func assemblesToolCalls() async throws {
        guard await lmStudioAvailable() else {
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

        let completion = try await executor().complete(request)
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
        guard await lmStudioAvailable() else {
            Issue.record("skipped: no OpenAI-compatible endpoint on :1234")
            return
        }
        let router = ModelRouter(executors: [
            OnDeviceExecutor(),
            VLLMExecutor(baseURL: lmStudio, model: "meta-llama-3.1-8b-instruct"),
        ])

        var request = LLMRequest(messages: [
            .init(.system, "Route the request to a specialist in a research AI team."),
            .init(.user, "ช่วยหางานวิจัยเรื่องวัคซีน mRNA ในผู้สูงอายุ"),
        ])
        request.responseSchema = (name: "Routing", schemaJSON: routingSchema)
        request.maxTokens = 128

        let completion = try await router.complete(request)
        #expect(!completion.text.isEmpty)
        #expect((try? JSONSerialization.jsonObject(with: Data(completion.text.utf8))) != nil,
                "expected JSON from whichever tier answered: \(completion.text.prefix(120))")
    }
}
