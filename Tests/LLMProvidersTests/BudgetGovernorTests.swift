import Testing
import Foundation
import AgentKit
@testable import LLMProviders

// ─────────────────────────────────────────────────────────────
// The Budget Governor (ARCHITECTURE §9.5, P5.6).
//
// The promise being tested is not "it adds up correctly" — it is that a
// ceiling changes where work runs rather than whether it runs at all.
// ─────────────────────────────────────────────────────────────

private actor StubLedger: SpendLedger {
    private var window: SpendWindow
    private(set) var recorded: [(cost: Double, endpoint: String)] = []

    init(_ window: SpendWindow = SpendWindow()) { self.window = window }

    func spend(now: Date) async -> SpendWindow { window }

    func record(cost: Double, promptTokens: Int, completionTokens: Int,
                endpoint: String, model: String, role: String?, at: Date) async {
        recorded.append((cost, endpoint))
        window.session += cost
        window.today += cost
        window.month += cost
    }
}

private let price = TokenPrice(inputPerMillion: 3, outputPerMillion: 15)

@Suite("Budget governor")
struct BudgetGovernorTests {

    @Test("a request inside every ceiling is allowed, with the estimate said out loud")
    func allowsWhatFits() async {
        let governor = BudgetGovernor(limits: .conservative, ledger: StubLedger())
        let decision = await governor.mayspend(promptTokens: 1_000, maxTokens: 500, price: price)
        #expect(decision.isAllowed)
        // 1,000 in at $3/M plus 500 out at $15/M = $0.0105.
        if case .allowed(let estimate) = decision.outcome {
            #expect(abs(estimate - 0.0105) < 0.0001)
        } else {
            Issue.record("expected an allowance, got \(decision.outcome)")
        }
    }

    /// §9.5: whichever ceiling is reached first blocks, and the message names
    /// it. "Over budget" with no number is the message that makes people turn
    /// budgets off.
    @Test("the ceiling that blocks is the one that gets named")
    func namesTheCeilingThatBlocked() async {
        let governor = BudgetGovernor(limits: BudgetLimits(perRequestUSD: 10, perDayUSD: 0.01),
                                      ledger: StubLedger())
        let decision = await governor.mayspend(promptTokens: 100_000, maxTokens: 1_000,
                                               price: price)
        guard case .blocked(let ceiling, let estimate, _) = decision.outcome else {
            Issue.record("expected a block, got \(decision.outcome)")
            return
        }
        #expect(ceiling == "ต่อวัน")
        #expect(estimate > 0.01)
        #expect(decision.reason.contains("ต่อวัน"))
    }

    @Test("money already spent counts against the ceiling")
    func spendingAccumulates() async {
        let ledger = StubLedger(SpendWindow(session: 1.9, today: 1.9, month: 1.9))
        let governor = BudgetGovernor(limits: BudgetLimits(perSessionUSD: 2), ledger: ledger)

        let decision = await governor.mayspend(promptTokens: 50_000, maxTokens: 5_000,
                                               price: price)
        #expect(!decision.isAllowed)
    }

    /// An endpoint that charges but has no price is one the governor cannot
    /// reason about. Refusing beats guessing with someone else's money.
    @Test("a metered endpoint with no price is refused, not estimated")
    func refusesUnpricedEndpoints() async {
        let governor = BudgetGovernor(ledger: StubLedger())
        let decision = await governor.mayspend(promptTokens: 10, maxTokens: 10, price: nil)
        #expect(!decision.isAllowed)
        #expect(decision.outcome == .unpriced)
    }

    /// The estimate decides; the endpoint's own usage report is what the next
    /// decision is measured against (§9.5, "บัญชีจริงหลังใช้").
    @Test("actual usage is what gets recorded, not the estimate")
    func accountsRealUsage() async {
        let ledger = StubLedger()
        let governor = BudgetGovernor(limits: BudgetLimits(perSessionUSD: 1), ledger: ledger)

        await governor.account(promptTokens: 1_000, completionTokens: 100, price: price,
                               endpoint: "hosted", model: "big")
        let recorded = await ledger.recorded
        #expect(recorded.count == 1)
        #expect(abs(recorded[0].cost - 0.0045) < 0.0001)

        let remaining = await governor.remaining()
        #expect((remaining.session ?? 0) < 1)
    }
}

@Suite("The router under a budget")
struct BudgetRoutingTests {
    private struct Stub: LLMExecutor {
        let identifier: String
        let tier: ModelTier
        let price: TokenPrice?
        let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: true,
                                           supportsStructuredOutput: true,
                                           supportsStreaming: true, supportsVision: false)
        func isAvailable() async -> Bool { true }
        func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.textDelta(identifier))
                continuation.yield(.usage(.init(promptTokens: 1_000, completionTokens: 100)))
                continuation.yield(.finished(reason: "stop"))
                continuation.finish()
            }
        }
    }

    /// The Done-when for P5.6: set a low ceiling and the work does not go to
    /// the paid endpoint — it goes somewhere else and still gets done.
    @Test("over the ceiling, the work falls to a free tier instead of failing")
    func fallsBackRatherThanFailing() async throws {
        let governor = BudgetGovernor(limits: BudgetLimits(perRequestUSD: 0.000_1),
                                      ledger: InMemorySpendLedger())
        let router = ModelRouter(executors: [
            Stub(identifier: "local", tier: .localMLX, price: nil),
            Stub(identifier: "hosted", tier: .paid, price: price),
        ], governor: governor)

        var request = LLMRequest(messages: [.init(.user, "งานหนัก")])
        request.maxTokens = 1_000
        let completion = try await router.complete(
            request, policy: RoutingPolicy(impact: .high, allowMetered: true))

        #expect(completion.producedBy == "local")
        #expect(completion.tier == .localMLX)
    }

    @Test("within the ceiling, the paid tier is used and the spend is recorded")
    func spendsWhenItMay() async throws {
        let ledger = InMemorySpendLedger()
        let governor = BudgetGovernor(limits: BudgetLimits(perRequestUSD: 5, perDayUSD: 5),
                                      ledger: ledger)
        let router = ModelRouter(executors: [
            Stub(identifier: "hosted", tier: .paid, price: price),
        ], governor: governor)

        var request = LLMRequest(messages: [.init(.user, "งานหนัก")])
        request.maxTokens = 1_000
        let completion = try await router.complete(
            request, policy: RoutingPolicy(impact: .high, allowMetered: true))

        #expect(completion.producedBy == "hosted")
        let spent = await ledger.spend(now: Date())
        // Recorded from the usage the executor reported, not from the estimate
        // the decision was made on.
        #expect(spent.session > 0)
    }

    /// Without `allowMetered` a paid tier is not even a candidate — the
    /// governor is the second line, not the first.
    @Test("work that refuses to spend never reaches the governor")
    func meteredTiersNeedPermissionFirst() async throws {
        let router = ModelRouter(executors: [
            Stub(identifier: "local", tier: .localMLX, price: nil),
            Stub(identifier: "hosted", tier: .paid, price: price),
        ], governor: BudgetGovernor(ledger: InMemorySpendLedger()))

        let completion = try await router.complete(LLMRequest(messages: [.init(.user, "hi")]))
        #expect(completion.producedBy == "local")
    }
}
