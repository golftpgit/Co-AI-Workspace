import Foundation

// ─────────────────────────────────────────────────────────────
// The vocabulary of spending (ARCHITECTURE §9.5).
//
// Here rather than in `LLMProviders` because three modules need it and none of
// them should have to depend on the others: `Config` writes the ceilings,
// `Persistence` stores what was spent, and `LLMProviders` is where the two
// meet and a request is allowed or sent somewhere cheaper. Same shape as
// `Embedder`, which `Knowledge` declares and `EmbeddingRuntime` implements.
// ─────────────────────────────────────────────────────────────

public struct BudgetLimits: Sendable, Equatable, Codable {
    /// Four ceilings; whichever is reached first blocks (§9.5).
    public var perRequestUSD: Double?
    public var perSessionUSD: Double?
    public var perDayUSD: Double?
    public var perMonthUSD: Double?

    public init(perRequestUSD: Double? = nil, perSessionUSD: Double? = nil,
                perDayUSD: Double? = nil, perMonthUSD: Double? = nil) {
        self.perRequestUSD = perRequestUSD
        self.perSessionUSD = perSessionUSD
        self.perDayUSD = perDayUSD
        self.perMonthUSD = perMonthUSD
    }

    /// What a machine with no configured budget gets. Deliberately small: the
    /// failure mode of a too-low default is work quietly staying local, and of
    /// a too-high one is a bill.
    public static let conservative = BudgetLimits(perRequestUSD: 0.50,
                                                  perSessionUSD: 2,
                                                  perDayUSD: 5,
                                                  perMonthUSD: 50)
}

public struct SpendWindow: Sendable, Equatable {
    public var session: Double
    public var today: Double
    public var month: Double

    public init(session: Double = 0, today: Double = 0, month: Double = 0) {
        self.session = session
        self.today = today
        self.month = month
    }
}

/// Where spending is remembered across launches. A protocol so `LLMProviders`
/// stays free of the database: `Persistence` implements it, tests hold it in
/// memory (§3's dependency direction).
public protocol SpendLedger: Sendable {
    func spend(now: Date) async -> SpendWindow
    func record(cost: Double, promptTokens: Int, completionTokens: Int,
                endpoint: String, model: String, role: String?, at: Date) async
}

