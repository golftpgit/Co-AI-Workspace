import Testing
import Foundation
import AgentKit
import Observability
@testable import LLMProviders

// ─────────────────────────────────────────────────────────────
// The router's job is to make three promises hold under failure:
// a refusal never reaches the user, no tier is ever the only path, and
// something local always remains as a floor. These tests are those promises.
// ─────────────────────────────────────────────────────────────

/// A scriptable executor. Real models are exercised elsewhere; here the point
/// is deterministic control over *how* a tier fails.
private struct StubExecutor: LLMExecutor {
    enum Behaviour: Sendable {
        case succeed(String)
        case fail(LLMError)
        case offline
    }

    let identifier: String
    let tier: ModelTier
    let capabilities: LLMCapabilities
    let behaviour: Behaviour
    let calls: CallLog

    init(_ identifier: String,
         tier: ModelTier,
         behaviour: Behaviour,
         calls: CallLog,
         contextWindow: Int = 32_000,
         tools: Bool = true,
         structured: Bool = true) {
        self.identifier = identifier
        self.tier = tier
        self.behaviour = behaviour
        self.calls = calls
        self.capabilities = LLMCapabilities(contextWindow: contextWindow,
                                            supportsTools: tools,
                                            supportsStructuredOutput: structured,
                                            supportsStreaming: true,
                                            supportsVision: false)
    }

    func isAvailable() async -> Bool {
        if case .offline = behaviour { return false }
        return true
    }

    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.record(identifier)
                switch behaviour {
                case .succeed(let text):
                    continuation.yield(.textDelta(text))
                    continuation.yield(.usage(.init(promptTokens: 10, completionTokens: 5)))
                    continuation.yield(.finished(reason: "stop"))
                    continuation.finish()
                case .fail(let error):
                    continuation.finish(throwing: error)
                case .offline:
                    continuation.finish(throwing: LLMError.unavailable(identifier))
                }
            }
        }
    }
}

private actor CallLog {
    private(set) var order: [String] = []
    func record(_ id: String) { order.append(id) }
}

private func ask(_ text: String = "สรุปงานวิจัยนี้") -> LLMRequest {
    LLMRequest(messages: [.init(.user, text)])
}

@Suite("Refusals escalate rather than surface")
struct RefusalEscalationTests {
    /// The measured on-device refusal rate is ~12.5% on ordinary research
    /// prompts. If that ever reached the user, the product would look broken
    /// one time in eight.
    @Test("a refused tier hands off to the next one")
    func refusalEscalates() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("on-device", tier: .onDevice,
                         behaviour: .fail(.refused("May contain sensitive content")), calls: calls),
            StubExecutor("gx10", tier: .selfHosted, behaviour: .succeed("ผลวิเคราะห์"), calls: calls),
        ])

        let completion = try await router.complete(ask())
        #expect(completion.text == "ผลวิเคราะห์")
        #expect(completion.producedBy == "gx10")
        #expect(await calls.order == ["on-device", "gx10"])
    }

    @Test("context overflow escalates to a bigger window")
    func overflowEscalates() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("small", tier: .onDevice, behaviour: .succeed("nope"),
                         calls: calls, contextWindow: 100),
            StubExecutor("large", tier: .selfHosted, behaviour: .succeed("ok"), calls: calls),
        ])

        var request = ask(String(repeating: "ก", count: 6_000))
        request.maxTokens = 512
        let completion = try await router.complete(request)
        #expect(completion.producedBy == "large")
        // The small tier is filtered out before it is ever called.
        #expect(await calls.order == ["large"])
    }

    @Test("an unavailable tier is skipped without being called")
    func offlineSkipped() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("offline-local", tier: .localMLX, behaviour: .offline, calls: calls),
            StubExecutor("gx10", tier: .selfHosted, behaviour: .succeed("ok"), calls: calls),
        ])

        _ = try await router.complete(ask())
        #expect(await calls.order == ["gx10"])
    }

    /// Not everything should escalate: a decoding fault means our own parsing
    /// is wrong, and retrying elsewhere would just hide it.
    @Test("non-escalatable failures surface immediately")
    func decodingFailsFast() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("first", tier: .onDevice, behaviour: .fail(.decoding("bad json")), calls: calls),
            StubExecutor("second", tier: .selfHosted, behaviour: .succeed("unused"), calls: calls),
        ])

        await #expect(throws: LLMError.self) { _ = try await router.complete(ask()) }
        #expect(await calls.order == ["first"])
    }

    @Test("when every tier declines, the error explains the whole chain")
    func exhaustedChainIsLegible() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("on-device", tier: .onDevice, behaviour: .fail(.refused("no")), calls: calls),
            StubExecutor("gx10", tier: .selfHosted, behaviour: .fail(.timeout), calls: calls),
        ])

        do {
            _ = try await router.complete(ask())
            Issue.record("expected the chain to be exhausted")
        } catch let error as RoutingError {
            #expect(error.attempts.count == 2)
            #expect(error.description.contains("refused"))
            #expect(error.description.contains("timeout"))
        }
    }
}

@Suite("Capability and policy filtering")
struct RoutingPolicyTests {
    @Test("tool calls never go to a tier without tool support")
    func toolsRouteUpward() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("on-device", tier: .onDevice, behaviour: .succeed("wrong"),
                         calls: calls, tools: false),
            StubExecutor("gx10", tier: .selfHosted, behaviour: .succeed("right"), calls: calls),
        ])

        var request = ask()
        request.tools = [LLMToolSpec(name: "run_shell", description: "run",
                                     parametersJSON: #"{"type":"object","properties":{}}"#)]
        let completion = try await router.complete(request)
        #expect(completion.producedBy == "gx10")
        #expect(await calls.order == ["gx10"])
    }

    /// Routing and planning decisions are consequential, and the on-device
    /// model gave different answers to identical prompts when measured.
    @Test("high-impact work skips the on-device tier entirely")
    func highImpactSkipsTier0() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("on-device", tier: .onDevice, behaviour: .succeed("cheap"), calls: calls),
            StubExecutor("gx10", tier: .selfHosted, behaviour: .succeed("considered"), calls: calls),
        ])

        let completion = try await router.complete(ask(), policy: .consequential)
        #expect(completion.producedBy == "gx10")
        #expect(await calls.order == ["gx10"])
    }

    /// §9.2's heavy chain is Tier 1a → 0.5 → 1b, not cheapest-first. The
    /// difference stopped being theoretical when Tier 0.5 became something a
    /// user installs: with a 0.6B model on disk, planning would have gone to it
    /// in preference to a 27B on the endpoint.
    @Test("high-impact work prefers the self-hosted model over the local one")
    func highImpactPrefersSelfHosted() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("local-mlx", tier: .localMLX, behaviour: .succeed("small"), calls: calls),
            StubExecutor("gx10", tier: .selfHosted, behaviour: .succeed("considered"), calls: calls),
        ])

        let completion = try await router.complete(ask(), policy: .consequential)
        #expect(completion.producedBy == "gx10")
        #expect(await calls.order == ["gx10"])
    }

    /// …and it is still the floor: when the endpoint is gone, the same work
    /// lands on the local model rather than failing (§9.2 rule 4).
    @Test("high-impact work falls to the local model when the endpoint is down")
    func highImpactFallsToLocalTier() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("local-mlx", tier: .localMLX, behaviour: .succeed("still answered"),
                         calls: calls),
            StubExecutor("gx10", tier: .selfHosted, behaviour: .offline, calls: calls),
        ])

        let completion = try await router.complete(ask(), policy: .consequential)
        #expect(completion.producedBy == "local-mlx")
    }

    @Test("cheap work prefers the cheapest capable tier")
    func disposableWorkStaysCheap() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("gx10", tier: .selfHosted, behaviour: .succeed("expensive"), calls: calls),
            StubExecutor("on-device", tier: .onDevice, behaviour: .succeed("cheap"), calls: calls),
        ])

        let completion = try await router.complete(ask(), policy: .disposable)
        #expect(completion.producedBy == "on-device")
    }

    /// Money is never spent implicitly — a paid tier has to be asked for.
    @Test("metered tiers are excluded unless explicitly allowed")
    func meteredRequiresOptIn() async throws {
        let calls = CallLog()
        let paidOnly = ModelRouter(executors: [
            StubExecutor("paid-api", tier: .paid, behaviour: .succeed("billed"), calls: calls),
        ])

        await #expect(throws: RoutingError.self) { _ = try await paidOnly.complete(ask()) }
        #expect(await calls.order.isEmpty)

        let allowed = try await paidOnly.complete(
            ask(), policy: RoutingPolicy(impact: .low, latencySensitive: false, allowMetered: true))
        #expect(allowed.producedBy == "paid-api")
    }

    @Test("a request nothing can serve fails loudly as a configuration error")
    func impossibleRequestFails() async {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("text-only", tier: .onDevice, behaviour: .succeed("x"),
                         calls: calls, tools: false, structured: false),
        ])

        var request = ask()
        request.responseSchema = (name: "R", schemaJSON: #"{"type":"object"}"#)
        await #expect(throws: RoutingError.self) { _ = try await router.complete(request) }
    }
}

@Suite("Streaming routing")
struct StreamingRoutingTests {
    /// Escalation must happen before any text ships, or the user would see two
    /// models' answers spliced together.
    @Test("a refusal on the first event escalates before anything is emitted")
    func streamEscalatesBeforeFirstToken() async throws {
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("on-device", tier: .onDevice, behaviour: .fail(.refused("no")), calls: calls),
            StubExecutor("gx10", tier: .selfHosted, behaviour: .succeed("คำตอบ"), calls: calls),
        ])

        let (executor, tier, events) = try await router.stream(ask())
        #expect(executor == "gx10")
        #expect(tier == .selfHosted)

        var text = ""
        for try await event in events {
            if case .textDelta(let chunk) = event { text += chunk }
        }
        #expect(text == "คำตอบ")
    }
}

@Suite("Observability of routing")
struct RoutingSpanTests {
    @Test("the escalation trail is recorded, so a slow answer is explainable")
    func recordsEscalation() async throws {
        let sink = InMemorySpanSink()
        let calls = CallLog()
        let router = ModelRouter(executors: [
            StubExecutor("on-device", tier: .onDevice, behaviour: .fail(.refused("no")), calls: calls),
            StubExecutor("gx10", tier: .selfHosted, behaviour: .succeed("ok"), calls: calls),
        ], spanSink: sink)

        _ = try await router.complete(ask())

        let spans = await sink.spans
        let winner = spans.first { $0.name == "llm:gx10" }
        #expect(winner?.status == .succeeded)
        #expect(winner?.detail?.contains("on-device:refused") == true)
        #expect(winner?.promptTokens == 10)
    }
}
