import Testing
@testable import LLMProviders

// ─────────────────────────────────────────────────────────────
// "Answer this one with the big model" (§9.2, P15.1).
//
// Driving the app found that the routing chain is right and that there is no
// way to reach past it: a chat turn is disposable and carries tools, so Tier 0
// rules itself out and the local model wins every time — correct for cost, and
// nothing anywhere lets a person say *this* question deserves the 27B (E.36).
// The gap was a control, not a measurement, so this is the control.
//
// A preference is **an order, not a filter**, and the difference is the whole
// design:
//
//  • **It moves a tier to the front; it does not remove the others.** If the
//    chosen endpoint is down mid-question, the chain still escalates and the
//    answer still arrives. A preference that emptied the chain would turn one
//    unplugged cable into a dead app.
//  • **It cannot make an ineligible tier eligible.** Asking for a model that
//    cannot call tools, on a turn that needs tools, is a request that cannot be
//    honoured — so it is refused *by name*, in the same explanation line as
//    every other exclusion, rather than quietly ignored.
//  • **It does not unlock spending.** Choosing a metered endpoint still needs
//    the work to allow money. Otherwise a picker becomes a way to spend without
//    the decision to spend, which is exactly what §9.5's guard is for. The
//    exclusion says both halves, so the person can see what to change.
//  • **It is on the record.** The order reason names the person's choice, so
//    "why did this come from there" answers itself — a preference that did not
//    show up in the explanation would make the explanation wrong.
// ─────────────────────────────────────────────────────────────

private struct Stub: LLMExecutor {
    let identifier: String
    let tier: ModelTier
    let capabilities: LLMCapabilities

    init(_ identifier: String, tier: ModelTier, tools: Bool = true) {
        self.identifier = identifier
        self.tier = tier
        self.capabilities = LLMCapabilities(contextWindow: 32_000,
                                            supportsTools: tools,
                                            supportsStructuredOutput: true,
                                            supportsStreaming: true,
                                            supportsVision: false)
    }

    func isAvailable() async -> Bool { true }
    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private let onDevice = Stub("apple-fm", tier: .onDevice, tools: false)
private let local = Stub("mlx-qwen", tier: .localMLX)
private let hosted = Stub("gx10", tier: .selfHosted)
private let paid = Stub("paid-large", tier: .paid)

private func ask(tools: Bool = false) -> LLMRequest {
    var request = LLMRequest(messages: [LLMMessage(.user, "ถามสั้น ๆ")])
    if tools {
        request.tools = [LLMToolSpec(name: "read_file", description: "อ่านไฟล์",
                                     parametersJSON: "{}")]
    }
    return request
}

@Suite("Asking for a particular model")
struct PreferredExecutorTests {

    @Test("the chosen model goes first even when a cheaper one would have won")
    func preferenceLeadsTheOrder() {
        let (candidates, choice) = ModelRouter.choose(
            from: [onDevice, local, hosted],
            for: ask(),
            policy: RoutingPolicy(latencySensitive: true, preferred: "gx10"))

        #expect(candidates.first?.identifier == "gx10")
        #expect(choice.order.first == "gx10")
        #expect(choice.orderReason.contains("gx10"),
                "เหตุผลของลำดับต้องบอกว่าคนเลือกไว้ ไม่งั้นคำอธิบายจะผิด")
    }

    @Test("the rest of the chain is still there behind it")
    func preferenceDoesNotEmptyTheChain() {
        // A preference that filtered would make one unreachable endpoint a dead
        // app; the whole point of the chain is that it survives that.
        let (candidates, _) = ModelRouter.choose(
            from: [onDevice, local, hosted],
            for: ask(),
            policy: RoutingPolicy(latencySensitive: true, preferred: "gx10"))
        #expect(candidates.count == 3)
        #expect(candidates.dropFirst().map(\.identifier) == ["apple-fm", "mlx-qwen"])
    }

    @Test("choosing a model that cannot do the job is refused by name, not ignored")
    func ineligiblePreferenceIsSaidOutLoud() {
        let (candidates, choice) = ModelRouter.choose(
            from: [onDevice, local, hosted],
            for: ask(tools: true),
            policy: RoutingPolicy(latencySensitive: true, preferred: "apple-fm"))

        #expect(candidates.first?.identifier != "apple-fm")
        let excluded = choice.excluded.first { $0.executor == "apple-fm" }
        #expect(excluded != nil)
        #expect(excluded?.reason.contains("เครื่องมือ") == true)
    }

    @Test("choosing a metered endpoint does not by itself authorise spending")
    func preferenceDoesNotUnlockMoney() {
        let (candidates, choice) = ModelRouter.choose(
            from: [local, hosted, paid],
            for: ask(),
            policy: RoutingPolicy(latencySensitive: true, preferred: "paid-large"))

        #expect(candidates.first?.identifier != "paid-large")
        let excluded = choice.excluded.first { $0.executor == "paid-large" }
        // Both halves, because "not allowed" without "you picked it" reads as a
        // bug, and "you picked it" without "money" does not say what to change.
        #expect(excluded?.reason.contains("เลือกไว้") == true)
        #expect(excluded?.reason.contains("เงิน") == true)
    }

    @Test("a name that matches nothing changes nothing and is not an error")
    func unknownPreferenceIsHarmless() {
        // An endpoint can be removed while a conversation still remembers its
        // name. Falling back to the ordinary order is the only behaviour that
        // does not strand the conversation.
        let (candidates, choice) = ModelRouter.choose(
            from: [local, hosted],
            for: ask(),
            policy: RoutingPolicy(latencySensitive: true, preferred: "endpoint-ที่ลบไปแล้ว"))
        #expect(candidates.first?.identifier == "mlx-qwen")
        #expect(!choice.orderReason.contains("endpoint-ที่ลบไปแล้ว"))
    }
}
