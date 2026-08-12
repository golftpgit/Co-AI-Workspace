import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Budget Governor (ARCHITECTURE §9.5, P5.6).
//
// Only Tier 1b passes through here. A self-hosted endpoint is free and has no
// ceiling; a metered one is the fastest way for this system to become
// expensive, because a team that loops a QA round on a paid model spends
// ~15× what a chat does (§1.2).
//
// Three properties matter more than the arithmetic:
//
//  1. **Estimated before the request, not counted after.** A ceiling checked
//     afterwards is a receipt, not a limit.
//  2. **Over the ceiling is not an error.** It is a routing signal: the work
//     falls to Tier 1a or 0.5 and carries on (§9.2 rule 4). The user finds out
//     from the span, not from a failure.
//  3. **Unless nothing else can do it.** When a paid tier is the only one with
//     the capability, blocking silently would be worse than asking — that case
//     goes to the approval broker with the estimate attached (§5.4).
// ─────────────────────────────────────────────────────────────

/// What a paid endpoint charges. Missing prices mean the governor cannot
/// estimate, and it refuses rather than guessing at somebody's money.
public struct TokenPrice: Sendable, Equatable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double

    public init(inputPerMillion: Double, outputPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    public func cost(promptTokens: Int, completionTokens: Int) -> Double {
        Double(promptTokens) / 1_000_000 * inputPerMillion
            + Double(completionTokens) / 1_000_000 * outputPerMillion
    }
}

public struct BudgetDecision: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case allowed(estimateUSD: Double)
        /// Over a ceiling. Names which one, because "over budget" without the
        /// number is the message that makes people turn budgets off.
        case blocked(ceiling: String, estimateUSD: Double, remainingUSD: Double)
        /// The endpoint charges but nobody said how much.
        case unpriced
    }

    public let outcome: Outcome
    public var isAllowed: Bool { if case .allowed = outcome { return true }; return false }

    public var reason: String {
        switch outcome {
        case .allowed(let estimate): String(format: "ประเมิน $%.4f", estimate)
        case .blocked(let ceiling, let estimate, let remaining):
            String(format: "เกินเพดาน%@: ประเมิน $%.4f เหลือ $%.4f", ceiling, estimate, remaining)
        case .unpriced: "ยังไม่ได้ตั้งราคาต่อโทเคนของ endpoint นี้ จึงประเมินค่าใช้จ่ายไม่ได้"
        }
    }
}

public actor BudgetGovernor {
    private var limits: BudgetLimits
    private let ledger: any SpendLedger
    private let sink: (any SpanSink)?
    private let clock: @Sendable () -> Date

    public init(limits: BudgetLimits = .conservative,
                ledger: any SpendLedger,
                spanSink: (any SpanSink)? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.limits = limits
        self.ledger = ledger
        self.sink = spanSink
        self.clock = clock
    }

    public func setLimits(_ limits: BudgetLimits) { self.limits = limits }
    public func currentLimits() -> BudgetLimits { limits }

    /// Asked before the request is sent. `maxTokens` stands in for the answer's
    /// length: the estimate has to be pessimistic, because being wrong low is
    /// how a ceiling gets passed without ever being hit.
    public func mayspend(promptTokens: Int, maxTokens: Int,
                         price: TokenPrice?) async -> BudgetDecision {
        guard let price else { return BudgetDecision(outcome: .unpriced) }
        let estimate = price.cost(promptTokens: promptTokens, completionTokens: maxTokens)
        let spent = await ledger.spend(now: clock())

        if let ceiling = limits.perRequestUSD, estimate > ceiling {
            return BudgetDecision(outcome: .blocked(ceiling: "ต่อครั้ง", estimateUSD: estimate,
                                                    remainingUSD: ceiling))
        }
        for (name, ceiling, used) in [("ต่อ session", limits.perSessionUSD, spent.session),
                                      ("ต่อวัน", limits.perDayUSD, spent.today),
                                      ("ต่อเดือน", limits.perMonthUSD, spent.month)] {
            guard let ceiling else { continue }
            let remaining = ceiling - used
            if estimate > remaining {
                return BudgetDecision(outcome: .blocked(ceiling: name, estimateUSD: estimate,
                                                        remainingUSD: max(0, remaining)))
            }
        }
        return BudgetDecision(outcome: .allowed(estimateUSD: estimate))
    }

    /// The real figure, after the endpoint has reported usage (§9.5, "บัญชีจริง
    /// หลังใช้"). Estimates are for deciding; this is what the ceilings are
    /// actually measured against next time.
    public func account(promptTokens: Int, completionTokens: Int, price: TokenPrice?,
                        endpoint: String, model: String, role: String? = nil) async {
        guard let price else { return }
        let cost = price.cost(promptTokens: promptTokens, completionTokens: completionTokens)
        await ledger.record(cost: cost, promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            endpoint: endpoint, model: model, role: role, at: clock())

        guard let sink else { return }
        var span = Span(name: "budget:spend", status: .succeeded)
        span.endedAt = Date()
        span.promptTokens = promptTokens
        span.completionTokens = completionTokens
        span.detail = String(format: "%@ · %@ · $%.4f", endpoint, model, cost)
        await sink.record(span)
    }

    public func remaining() async -> (session: Double?, today: Double?, month: Double?) {
        let spent = await ledger.spend(now: clock())
        return (limits.perSessionUSD.map { $0 - spent.session },
                limits.perDayUSD.map { $0 - spent.today },
                limits.perMonthUSD.map { $0 - spent.month })
    }
}

/// Keeps the session's spending in memory and nothing else — enough for tests
/// and for a machine with no database yet.
public actor InMemorySpendLedger: SpendLedger {
    private var entries: [(cost: Double, at: Date)] = []

    public init() {}

    public func spend(now: Date) async -> SpendWindow {
        let calendar = Calendar.current
        return SpendWindow(
            session: entries.reduce(0) { $0 + $1.cost },
            today: entries.filter { calendar.isDate($0.at, inSameDayAs: now) }
                .reduce(0) { $0 + $1.cost },
            month: entries.filter {
                calendar.isDate($0.at, equalTo: now, toGranularity: .month)
            }.reduce(0) { $0 + $1.cost })
    }

    public func record(cost: Double, promptTokens: Int, completionTokens: Int,
                       endpoint: String, model: String, role: String?, at: Date) async {
        entries.append((cost, at))
    }
}
