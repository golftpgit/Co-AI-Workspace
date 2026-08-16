import Foundation
import LLMProviders

// ─────────────────────────────────────────────────────────────
// How much a single run may spend (ARCHITECTURE §5.5, P4.8's remainder).
//
// `continuationCap` already bounds how many times run-until-done picks the
// ledger back up, and `BudgetGovernor` (P5.6) bounds money per endpoint.
// Neither answers the question somebody actually asks when they turn
// run-until-done on and walk away: **how much has this run used?** Three
// assignments with three retries each is nine model conversations, and until
// now nothing counted them.
//
// Three rules, and each one is a way a token ceiling goes wrong:
//
//  • **Failed attempts count.** They spent the tokens. A ceiling that only
//    counts successful work would be loosest exactly when a run is going badly,
//    which is when it is spending the most.
//  • **It stops between calls, never inside one.** A request cut off halfway
//    has spent its prompt and bought nothing. The natural boundaries are
//    between tool rounds and between assignments, so those are where this is
//    asked.
//  • **Running out is reported, not silent.** A run that quietly returns fewer
//    deliverables looks like a run that found less to do. The remaining work
//    is left in the ledger needing a person, and the event says the ceiling is
//    what stopped it.
// ─────────────────────────────────────────────────────────────

public actor RunBudget {
    public struct Spend: Sendable, Equatable {
        public var promptTokens = 0
        public var completionTokens = 0
        public var total: Int { promptTokens + completionTokens }
    }

    /// `nil` means no ceiling — the honest default. A number invented here
    /// would be a limit nobody chose, and the first time it stopped a real run
    /// it would look like a bug.
    private(set) var ceiling: Int?
    private(set) var spend = Spend()

    public init(ceiling: Int? = nil) {
        self.ceiling = ceiling
    }

    /// Starts a run. Resets the count, because a ceiling is per run — carrying
    /// yesterday's tokens into today's would stop the second run instantly.
    public func begin(ceiling: Int?) {
        self.ceiling = ceiling
        spend = Spend()
    }

    public func record(_ usage: LLMUsage?) {
        guard let usage else { return }
        spend.promptTokens += usage.promptTokens
        spend.completionTokens += usage.completionTokens
    }

    public var isExhausted: Bool {
        guard let ceiling else { return false }
        return spend.total >= ceiling
    }

    public var used: Spend { spend }

    public var remaining: Int? {
        ceiling.map { max(0, $0 - spend.total) }
    }

    /// The sentence a person reads when a run stopped early. It names the
    /// number they set, because "budget exceeded" without it is a mystery for
    /// anybody who did not set it themselves.
    public var summary: String {
        guard let ceiling else { return "ใช้ไป \(spend.total) โทเคน (ไม่ได้ตั้งเพดานไว้)" }
        return "ใช้ไป \(spend.total) จากเพดาน \(ceiling) โทเคนของการรันนี้"
    }
}
