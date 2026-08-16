import Testing
import Foundation
import AgentKit
@testable import LLMProviders

// ─────────────────────────────────────────────────────────────
// P20.5 — "why is it using that model" has an answer, and the answer is the
// decision itself.
//
// The cheap version of this feature is a sentence written after the fact —
// by a model, or by a second function that re-implements the routing rules in
// prose. Both are stories that can be true today and wrong tomorrow. These
// tests hold the explanation to the only standard that means anything: it has
// to change when the routing changes, because it comes out of the same pass.
// ─────────────────────────────────────────────────────────────

private struct Stub: LLMExecutor {
    let identifier: String
    let tier: ModelTier
    let capabilities: LLMCapabilities

    init(_ identifier: String, tier: ModelTier,
         contextWindow: Int = 32_000, tools: Bool = true, structured: Bool = true) {
        self.identifier = identifier
        self.tier = tier
        self.capabilities = LLMCapabilities(contextWindow: contextWindow,
                                            supportsTools: tools,
                                            supportsStructuredOutput: structured,
                                            supportsStreaming: true,
                                            supportsVision: false)
    }

    func isAvailable() async -> Bool { true }

    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("ok"))
            continuation.yield(.finished(reason: "stop"))
            continuation.finish()
        }
    }
}

private let onDevice = Stub("apple-fm", tier: .onDevice)
private let local = Stub("mlx-qwen", tier: .localMLX)
private let endpoint = Stub("gx10-vllm", tier: .selfHosted)
private let paid = Stub("anthropic", tier: .paid)

private func ask() -> LLMRequest { LLMRequest(messages: [.init(.user, "วางแผนงานนี้ให้หน่อย")]) }

@Suite("The routing reason is the routing (P20.5)")
struct RoutingRationaleTests {

    /// The Done-when, stated as an equality rather than a resemblance: the
    /// order the explanation gives is the order the router will use, because
    /// it is the same array.
    @Test("the order shown is the order tried, not a description of it")
    func orderMatchesTheDecision() async {
        let router = ModelRouter(executors: [onDevice, local, endpoint, paid])
        let choice = await router.explain(ask(), policy: .consequential)
        // §9.2's heavy chain: self-hosted first, local behind it, on-device
        // never.
        #expect(choice.order == ["gx10-vllm", "mlx-qwen"])
        #expect(choice.orderReason.contains("§9.2"))
    }

    @Test("each tier that was ruled out says which rule ruled it out")
    func exclusionsNameTheirClause() async {
        let router = ModelRouter(executors: [onDevice, local, endpoint, paid])
        let choice = await router.explain(ask(), policy: .consequential)
        let reasons = Dictionary(uniqueKeysWithValues: choice.excluded.map { ($0.executor, $0.reason) })

        #expect(reasons["apple-fm"]?.contains("E.7") == true)
        #expect(reasons["anthropic"]?.contains("คิดเงิน") == true)
        // Nothing else was excluded — a list that quietly grows would be a
        // list nobody can check against what actually ran.
        #expect(choice.excluded.count == 2)
    }

    /// Changing the policy has to change the sentence. If it does not, the
    /// sentence is decoration.
    @Test("a different policy gives a different reason, from the same request")
    func policyChangesTheReason() async {
        let router = ModelRouter(executors: [onDevice, local, endpoint, paid])
        let hurried = await router.explain(ask(), policy: .disposable)
        let careful = await router.explain(ask(), policy: .consequential)

        #expect(hurried.orderReason != careful.orderReason)
        #expect(hurried.orderReason.contains("รออยู่"))
        // Latency-sensitive work is allowed on-device; careful work is not,
        // and both statements match what `candidates` will actually do.
        #expect(hurried.order.contains("apple-fm"))
        #expect(careful.order.contains("apple-fm") == false)
    }

    @Test("a request that needs tools says so about the model that cannot")
    func capabilityExclusionsAreSpecific() async {
        let toolless = Stub("small-local", tier: .localMLX, tools: false)
        let narrow = Stub("short-window", tier: .localMLX, contextWindow: 4_000)
        let router = ModelRouter(executors: [toolless, narrow, endpoint])

        var request = ask()
        request.tools = [LLMToolSpec(name: "kb_search", description: "ค้น",
                                     parametersJSON: #"{"type":"object"}"#)]
        request.maxTokens = 8_000
        let choice = await router.explain(request, policy: .disposable)
        let reasons = Dictionary(uniqueKeysWithValues: choice.excluded.map { ($0.executor, $0.reason) })

        #expect(reasons["small-local"]?.contains("เครื่องมือ") == true)
        // The number is in the sentence: "context too small" without saying
        // how small leaves the reader to guess whether it was close.
        #expect(reasons["short-window"]?.contains("4000") == true)
        #expect(choice.order == ["gx10-vllm"])
    }

    /// The part of the reason that cannot be known in advance: a tier that was
    /// eligible, was tried, and failed. Without it the explanation says the
    /// endpoint was first while the answer came from somewhere else.
    @Test("a tier that was tried and failed appears in the reason for the one that answered")
    func escalationJoinsTheReason() async throws {
        struct Broken: LLMExecutor {
            let identifier = "gx10-vllm"
            let tier = ModelTier.selfHosted
            let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: true,
                                               supportsStructuredOutput: true,
                                               supportsStreaming: true, supportsVision: false)
            func isAvailable() async -> Bool { true }
            func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: LLMError.timeout) }
            }
        }
        let router = ModelRouter(executors: [Broken(), local])
        let routed = try await router.stream(ask(), policy: .consequential)

        #expect(routed.executor == "mlx-qwen")
        #expect(routed.choice.escalatedPast.map(\.executor) == ["gx10-vllm"])
        #expect(routed.choice.lines.contains { $0.contains("ข้าม gx10-vllm") })
    }

    @Test("with nothing eligible the failure carries the same reasons, not a blank")
    func nothingEligibleStillExplains() async {
        let router = ModelRouter(executors: [onDevice])
        do {
            _ = try await router.stream(ask(), policy: .consequential)
            Issue.record("routed to a tier that was ruled out")
        } catch let error as RoutingError {
            #expect(error.attempts.first?.detail?.contains("E.7") == true)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
