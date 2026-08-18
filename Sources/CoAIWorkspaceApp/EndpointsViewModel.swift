import Foundation
import Observation
import Config
import LLMProviders
import Persistence
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Endpoints and what they are allowed to spend (§9.3/§9.5, P5.5–P5.7).
//
// One screen for both because they are one decision: an endpoint that charges
// is only usable to the extent a ceiling allows it, and a ceiling means
// nothing without an endpoint that charges. Splitting them would put the
// switch in one room and the fuse in another.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class EndpointsViewModel {
    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    public private(set) var registry = EndpointRegistry()
    /// Probe results by endpoint id — the permanent status dot §9.3 asks for.
    public private(set) var checks: [String: EndpointCheck] = [:]
    public private(set) var checking: Set<String> = []
    public private(set) var status: Status?

    public private(set) var limits = BudgetLimits.conservative
    public private(set) var spend = SpendWindow()
    /// Where the money went, newest first — "how much" is never the whole
    /// question (§9.5's last row).
    public private(set) var breakdown: [(key: String, costUSD: Double, tokens: Int)] = []

    /// A draft, so a half-typed endpoint is never something the router might
    /// pick up. Saving is what validates it.
    public var draft = InferenceEndpoint(name: "", baseURL: "", model: "")
    public var editing = false

    private var governor: BudgetGovernor?
    private var ledger: SurrealSpendLedger?
    private var persist: ((EndpointRegistry, BudgetLimits) -> Void)?
    private let probe = EndpointProbe()
    private let log = AppLog.logger("endpoints-ui")

    public init() {}

    public func attach(registry: EndpointRegistry,
                       checks: [String: EndpointCheck],
                       limits: BudgetLimits,
                       governor: BudgetGovernor,
                       ledger: SurrealSpendLedger,
                       persist: @escaping (EndpointRegistry, BudgetLimits) -> Void) async {
        self.registry = registry
        self.checks = checks
        self.limits = limits
        self.governor = governor
        self.ledger = ledger
        self.persist = persist
        await refreshSpending()
    }

    // MARK: - endpoints

    public func beginAdding() {
        // The GX10, because that is Tier 1 on this machine (§17.1). The field
        // was pre-filled with a loopback port for a local model manager that is
        // no longer part of any path (C7), which meant the one suggestion the
        // screen made pointed at nothing.
        draft = InferenceEndpoint(name: "", baseURL: "http://192.168.1.205:8000/v1", model: "")
        editing = true
    }

    public func beginEditing(_ endpoint: InferenceEndpoint) {
        draft = endpoint
        editing = true
    }

    /// Saves only after asking the endpoint what it serves.
    ///
    /// §9.3 is explicit about this and E.9 case 8a says why: the server will
    /// happily accept a request for a model it does not have, so a typo saved
    /// now surfaces as an unexplained failure much later. The check is the
    /// difference between "wrong name" and "the AI is broken".
    public func save() async {
        let endpoint = draft
        guard !endpoint.name.isEmpty, endpoint.url != nil else {
            status = Status(message: t("A name and a usable URL are both required",
                                       "Status message when the endpoint form is incomplete."),
                            isError: true)
            return
        }
        checking.insert(endpoint.id)
        let check = await probe.check(endpoint)
        checking.remove(endpoint.id)
        checks[endpoint.id] = check

        guard check.isUsable else {
            // Not saved. A registry full of endpoints that were never reachable
            // is a list of things to check by hand later.
            status = Status(message: t("Not saved — \(check.message)",
                                       "Status message when the endpoint probe failed. Placeholder is why."),
                            isError: true)
            return
        }
        registry.upsert(endpoint)
        editing = false
        status = Status(message: t("Saved \(endpoint.name) · \(check.message)",
                                   "Status message after saving an endpoint. Placeholders: its name and the probe result."),
                        isError: false)
        save(registry)
    }

    public func remove(_ endpoint: InferenceEndpoint) {
        registry.remove(id: endpoint.id)
        checks[endpoint.id] = nil
        save(registry)
    }

    public func makeDefault(_ endpoint: InferenceEndpoint) {
        registry.defaultEndpointID = endpoint.id
        save(registry)
    }

    /// §9.3's "Recheck all" — cheap, and the only way a stale dot gets fixed.
    public func recheckAll() async {
        for endpoint in registry.endpoints {
            checking.insert(endpoint.id)
            checks[endpoint.id] = await probe.check(endpoint)
            checking.remove(endpoint.id)
        }
        status = Status(message: t("Every endpoint has been checked",
                                   "Status message after re-probing all endpoints."),
                        isError: false)
    }

    public func check(for endpoint: InferenceEndpoint) -> EndpointCheck? { checks[endpoint.id] }
    public func isChecking(_ endpoint: InferenceEndpoint) -> Bool { checking.contains(endpoint.id) }
    public func isDefault(_ endpoint: InferenceEndpoint) -> Bool {
        registry.defaultEndpointID == endpoint.id
    }

    // MARK: - money

    public func setLimits(_ new: BudgetLimits) async {
        limits = new
        await governor?.setLimits(new)
        persist?(registry, new)
        await refreshSpending()
    }

    public func refreshSpending() async {
        guard let ledger else { return }
        spend = await ledger.spend(now: Date())
        let monthStart = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
        breakdown = (try? await ledger.totals(since: monthStart)) ?? []
    }

    /// What is left of each ceiling, for the bar §9.5 asks to be visible at all
    /// times.
    public var remaining: (session: Double?, today: Double?, month: Double?) {
        (limits.perSessionUSD.map { $0 - spend.session },
         limits.perDayUSD.map { $0 - spend.today },
         limits.perMonthUSD.map { $0 - spend.month })
    }

    /// Whether anything here can cost money at all. With no paid endpoint the
    /// budget section is noise, and saying so is better than showing four
    /// ceilings on zero spending.
    public var hasMeteredEndpoint: Bool {
        registry.endpoints.contains { $0.kind == .paid }
    }

    private func save(_ registry: EndpointRegistry) {
        persist?(registry, limits)
    }
}
