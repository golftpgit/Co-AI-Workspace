import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Model Router (ARCHITECTURE §9.2).
//
// Three rules are structural, not advisory:
//
//  1. A refusal is a routing signal, not an error. Tier 0 refuses ~12.5% of
//     ordinary research prompts at random (E.7); the user must never see that.
//  2. No tier is ever the only path. There is no API here that runs work
//     without a fallback chain — the type system does not offer one.
//  3. Tier 0.5 is the floor. When everything remote is unreachable or out of
//     budget, local work still has somewhere to run (§9.2 rule 4).
// ─────────────────────────────────────────────────────────────

/// What the work needs, independent of which model ends up serving it.
public struct RoutingPolicy: Sendable {
    /// How bad it is to be wrong. High-impact work never touches Tier 0
    /// (measured: its routing choices are not stable run to run — E.7).
    public let impact: RiskLevel
    /// The user is watching a spinner; prefer the fastest adequate tier.
    public let latencySensitive: Bool
    /// Refuse to spend money for this piece of work even if a paid tier exists.
    public let allowMetered: Bool
    /// The endpoint a person asked for by name (§9.2, P15.1).
    ///
    /// **An order, not a filter.** It moves that executor to the front and
    /// leaves the rest of the chain behind it, so a chosen endpoint going down
    /// mid-question costs a slower answer rather than no answer. It cannot make
    /// an ineligible tier eligible and it does not authorise spending — both of
    /// those are refused by name in `excluded`, because a preference that is
    /// silently ignored is worse than one that is refused.
    ///
    /// It exists because the chain was right and unreachable: routing correctly
    /// sent every chat turn to the cheapest tier that could serve it, and
    /// nothing let a person say that *this* question deserves the large model —
    /// which is what somebody wants in exactly the minute the small one answers
    /// badly (measured, E.36).
    public let preferred: String?

    public init(impact: RiskLevel = .low,
                latencySensitive: Bool = false,
                allowMetered: Bool = false,
                preferred: String? = nil) {
        self.impact = impact
        self.latencySensitive = latencySensitive
        self.allowMetered = allowMetered
        self.preferred = preferred
    }

    /// The same policy with a different choice of endpoint, for the screen that
    /// offers one.
    public func asking(for identifier: String?) -> RoutingPolicy {
        RoutingPolicy(impact: impact, latencySensitive: latencySensitive,
                      allowMetered: allowMetered, preferred: identifier)
    }

    /// Cheap, throwaway work: labels, groupings, short extractions.
    public static let disposable = RoutingPolicy(impact: .low, latencySensitive: true)
    /// Decisions that shape what the system does next: planning, delegation.
    public static let consequential = RoutingPolicy(impact: .high)
}

/// Why a candidate was skipped — kept so the UI can explain a slow or
/// surprising answer instead of leaving the user guessing.
public struct RoutingAttempt: Sendable, Equatable {
    public let executor: String
    public let tier: ModelTier
    public let outcome: String
    /// What the tier actually said. `outcome` is a category for grouping;
    /// this is the sentence someone needs to fix the problem — collapsing an
    /// on-device failure to the single word "transport" told nobody anything.
    public let detail: String?

    public init(executor: String, tier: ModelTier, outcome: String, detail: String? = nil) {
        self.executor = executor
        self.tier = tier
        self.outcome = outcome
        self.detail = detail
    }
}

/// Why the router will try what it tries, in the order it tries it (§24.3,
/// P20.5).
///
/// **Produced by the pass that decides, not by a second pass that explains.**
/// The obvious way to answer "why this tier" is to ask a model to write a
/// sentence about it afterwards, and that sentence would be a plausible story
/// about a decision it did not make. Everything here is a by-product of
/// `choose(from:for:policy:)` — the same filter that removes a tier writes the
/// line saying why it is gone, so an explanation cannot drift from the
/// behaviour it describes without the filter changing too.
public struct RoutingChoice: Sendable, Equatable {
    public struct Excluded: Sendable, Equatable {
        public let executor: String
        public let tier: ModelTier
        public let reason: String
    }

    /// The order the tiers will be tried in.
    public let order: [String]
    /// The policy clause that produced that order — which rule, not a general
    /// statement about routing.
    public let orderReason: String
    /// Ruled out before anything ran, each with the clause that ruled it out.
    public let excluded: [Excluded]
    /// Tried and stepped past while the request was in flight. Filled in by the
    /// call, because "it was slow because the endpoint was down" is only known
    /// once the endpoint has been asked.
    public var escalatedPast: [RoutingAttempt] = []

    /// The whole reason, in the order a person reads it: what was chosen, why
    /// that order, what was skipped and why.
    public var lines: [String] {
        var lines = [orderReason]
        lines += escalatedPast.map { "ข้าม \($0.executor) — \($0.detail ?? $0.outcome)" }
        lines += excluded.map { "ไม่พิจารณา \($0.executor) — \($0.reason)" }
        return lines
    }
}

public struct RoutingError: Error, CustomStringConvertible {
    public let attempts: [RoutingAttempt]

    public var description: String {
        "every tier declined or failed: "
            + attempts.map { attempt in
                attempt.detail.map { "\(attempt.executor)(\(attempt.outcome): \($0))" }
                    ?? "\(attempt.executor)(\(attempt.outcome))"
            }.joined(separator: ", ")
    }
}

public actor ModelRouter {
    /// The chain, in the order it is tried.
    ///
    /// A `var` because the person can change it: endpoints are added, edited
    /// and deleted on the settings screen, and this used to be a `let` built
    /// once during boot — so an endpoint somebody had just saved was written to
    /// `bootstrap.plist` and then ignored until the app was restarted, with
    /// nothing on screen saying so (AUDIT F-1). The chat composer offers what
    /// `offered` returns, so the GX10 they had just added simply was not there.
    private var executors: [any LLMExecutor]
    private let sink: (any SpanSink)?
    /// Availability is probed rarely, not per call: a probe on the hot path
    /// would cost more than the request it is guarding.
    private var availability: [String: (ok: Bool, checkedAt: ContinuousClock.Instant)] = [:]
    private let availabilityTTL: Duration

    /// Guards the metered tier. Absent means there is nothing metered to
    /// guard — a machine with only free endpoints never builds one.
    private let governor: BudgetGovernor?

    public init(executors: [any LLMExecutor],
                spanSink: (any SpanSink)? = nil,
                governor: BudgetGovernor? = nil,
                availabilityTTL: Duration = .seconds(30)) {
        self.governor = governor
        self.executors = Self.ordered(executors)
        self.sink = spanSink
        self.availabilityTTL = availabilityTTL
    }

    /// Cheapest first; escalation walks up the tiers (§9.2). One function so the
    /// order cannot come out differently depending on which door the chain
    /// arrived through.
    private static func ordered(_ executors: [any LLMExecutor]) -> [any LLMExecutor] {
        executors.sorted { $0.tier < $1.tier }
    }

    /// Swaps the whole chain — what the settings screen calls after saving.
    ///
    /// **The availability cache is cleared, always.** It is keyed by identifier,
    /// and an identifier can now point at a different server than it did thirty
    /// seconds ago: keeping the old verdict means the endpoint somebody has just
    /// corrected goes on being skipped, for no reason anybody can see on screen.
    /// Clearing it costs one probe.
    public func replaceExecutors(_ new: [any LLMExecutor]) {
        executors = Self.ordered(new)
        availability.removeAll()
    }

    /// What a person may choose between, in the order the chain would try them
    /// anyway. Names only — the screen offering the choice has no business
    /// holding executors, and a list built from anything but the router's own
    /// would offer an endpoint that is not there.
    public var offered: [(identifier: String, tier: ModelTier)] {
        executors.map { ($0.identifier, $0.tier) }
    }

    /// Runs the request on the first tier that can serve it, escalating past
    /// refusals, overflows and outages. There is intentionally no variant of
    /// this call that gives up after one attempt.
    public func complete(_ request: LLMRequest,
                         policy: RoutingPolicy = .disposable) async throws -> LLMCompletion {
        var attempts: [RoutingAttempt] = []
        let (candidates, _) = try candidates(for: request, policy: policy)

        for executor in candidates {
            guard await isAvailable(executor) else {
                attempts.append(.init(executor: executor.identifier, tier: executor.tier,
                                      outcome: "unavailable"))
                continue
            }
            if let refusal = await budgetRefusal(for: executor, request: request) {
                // Over the ceiling is a routing signal, not an error (§9.5):
                // the work goes down a tier and carries on, and the reason is
                // on the span rather than in the user's face.
                attempts.append(.init(executor: executor.identifier, tier: executor.tier,
                                      outcome: "over budget", detail: refusal))
                continue
            }
            do {
                let completion = try await executor.complete(request)
                await record(executor: executor, request: request, outcome: "ok",
                             usage: completion.usage, escalatedFrom: attempts)
                await accountIfMetered(executor: executor, usage: completion.usage)
                return completion
            } catch let error as LLMError where error.isEscalatable {
                attempts.append(.init(executor: executor.identifier, tier: executor.tier,
                                      outcome: shortOutcome(error), detail: error.description))
                if case .unavailable = error { markUnavailable(executor) }
                if case .transport = error { markUnavailable(executor) }
                continue
            } catch let error as LLMError {
                // Not escalatable (a decoding fault, or the user cancelled):
                // trying another model would repeat the same mistake.
                await record(executor: executor, request: request,
                             outcome: shortOutcome(error), usage: nil, escalatedFrom: attempts)
                throw error
            }
        }

        await recordExhausted(attempts)
        throw RoutingError(attempts: attempts)
    }

    /// Streaming variant. Escalation happens *before* the first token is
    /// emitted; once text has reached the caller, switching models mid-answer
    /// would produce a spliced, incoherent reply, so a late failure is surfaced.
    public func stream(_ request: LLMRequest,
                       policy: RoutingPolicy = .disposable) async throws
        -> (executor: String, tier: ModelTier, events: AsyncThrowingStream<LLMEvent, Error>,
            choice: RoutingChoice) {
        var attempts: [RoutingAttempt] = []
        var (candidates, choice) = try candidates(for: request, policy: policy)

        for executor in candidates {
            guard await isAvailable(executor) else {
                attempts.append(.init(executor: executor.identifier, tier: executor.tier,
                                      outcome: "unavailable"))
                continue
            }

            if let refusal = await budgetRefusal(for: executor, request: request) {
                attempts.append(.init(executor: executor.identifier, tier: executor.tier,
                                      outcome: "over budget", detail: refusal))
                continue
            }

            let upstream = executor.respond(to: request)
            do {
                // Probe the first event here so a refusal still escalates;
                // after this point the caller owns the stream.
                let probe = ProbedStream(upstream)
                let first = try await probe.first()
                let stream = probe.rest(startingWith: first)
                await record(executor: executor, request: request, outcome: "ok",
                             usage: nil, escalatedFrom: attempts)
                // The tiers walked past on the way here are part of the answer
                // to "why this one", and only knowable now.
                choice.escalatedPast = attempts
                return (executor.identifier, executor.tier, stream, choice)
            } catch let error as LLMError where error.isEscalatable {
                attempts.append(.init(executor: executor.identifier, tier: executor.tier,
                                      outcome: shortOutcome(error), detail: error.description))
                continue
            }
        }

        await recordExhausted(attempts)
        throw RoutingError(attempts: attempts)
    }

    // MARK: - candidate selection

    /// Filters by declared capability and policy, then orders by cost.
    /// Throws only when nothing could ever serve the request — a configuration
    /// problem, not a runtime one, and worth failing loudly.
    private func candidates(for request: LLMRequest,
                            policy: RoutingPolicy) throws -> ([any LLMExecutor], RoutingChoice) {
        let (candidates, choice) = Self.choose(from: executors, for: request, policy: policy)
        if candidates.isEmpty {
            throw RoutingError(attempts: choice.excluded.map {
                .init(executor: $0.executor, tier: $0.tier, outcome: "ineligible",
                      detail: $0.reason)
            })
        }
        return (candidates, choice)
    }

    /// What the router would do with this request, without doing it — for the
    /// screen that has to say why (P20.5). Deliberately the same call the
    /// routing itself makes.
    public func explain(_ request: LLMRequest,
                        policy: RoutingPolicy = .disposable) -> RoutingChoice {
        Self.choose(from: executors, for: request, policy: policy).choice
    }

    /// The one selection pass. Every rule that removes or orders a tier writes
    /// its own reason here; there is no second implementation to disagree with.
    static func choose(from executors: [any LLMExecutor],
                       for request: LLMRequest,
                       policy: RoutingPolicy) -> (candidates: [any LLMExecutor],
                                                  choice: RoutingChoice) {
        let needed = request.estimatedPromptTokens + request.maxTokens
        var eligible: [any LLMExecutor] = []
        var excluded: [RoutingChoice.Excluded] = []

        for executor in executors {
            let reason: String?
            if !request.tools.isEmpty && !executor.capabilities.supportsTools {
                reason = "รอบนี้ต้องเรียกเครื่องมือ แต่โมเดลนี้เรียกไม่ได้"
            } else if request.responseSchema != nil
                        && !executor.capabilities.supportsStructuredOutput {
                reason = "งานนี้ต้องได้คำตอบตามสคีมา แต่โมเดลนี้ไม่รองรับ"
            } else if executor.capabilities.contextWindow < needed {
                reason = "ต้องใช้ราว \(needed) โทเคน เกิน context window "
                    + "\(executor.capabilities.contextWindow) ของโมเดลนี้"
            } else if executor.tier.isMetered && !policy.allowMetered {
                // Both halves. "Not allowed" alone reads as a bug to somebody
                // who just picked this endpoint; "you picked it" alone does not
                // say what to change.
                reason = policy.preferred == executor.identifier
                    ? "คุณเลือกไว้ แต่เป็น tier ที่คิดเงิน และงานชิ้นนี้ไม่ได้อนุญาตให้ใช้เงิน"
                    : "เป็น tier ที่คิดเงิน และงานชิ้นนี้ไม่ได้อนุญาตให้ใช้เงิน"
            } else if policy.impact == .high && executor.tier == .onDevice {
                // High-impact work skips the on-device model: its answers are
                // not stable enough to make decisions on (ARCHITECTURE E.7).
                reason = "งานนี้ผิดแล้วเสียหาย — on-device เลือกไม่เหมือนเดิมในแต่ละรอบ (E.7)"
            } else {
                reason = nil
            }
            if let reason {
                excluded.append(.init(executor: executor.identifier,
                                      tier: executor.tier, reason: reason))
            } else {
                eligible.append(executor)
            }
        }

        let orderReason: String
        if policy.latencySensitive {
            // Latency-sensitive work prefers cheap-and-close, which is the
            // order the list is already in.
            orderReason = "มีคนนั่งรออยู่ — เรียงจาก tier ที่ใกล้และเร็วที่สุดขึ้นไป"
        } else if policy.impact == .high {
            // §9.2's heavy chain: Tier 1a → 0.5 → 1b. Cheapest-first is the
            // wrong order here, and stopped being harmless the moment Tier 0.5
            // became something a user installs: with a 0.6B model on disk,
            // planning and delegation would go to it in preference to a 27B on
            // the endpoint. Tier 0.5 stays in the chain as the floor — it is
            // where this work lands when the endpoint is gone — just not first.
            eligible.sort { Self.heavyWorkRank($0.tier) < Self.heavyWorkRank($1.tier) }
            orderReason = "งานที่ผิดแล้วเสียหาย (§9.2) — self-hosted ก่อน แล้วค่อยลงมาที่ local"
        } else {
            eligible.sort { lhs, rhs in
                // Prefer a locally hosted model over on-device when quality
                // matters more than speed, but never above self-hosted.
                (lhs.tier == .onDevice ? 1 : 0, lhs.tier.rawValue)
                    < (rhs.tier == .onDevice ? 1 : 0, rhs.tier.rawValue)
            }
            orderReason = "งานทั่วไปที่ไม่ได้รีบ — เอาคุณภาพก่อน on-device"
        }

        // The person's choice goes last, on top of whatever the policy ordered,
        // because a preference is about *this* question and the policy is about
        // the kind of work. Moved, never filtered: everything else stays behind
        // it, so a chosen endpoint that has gone down costs a slower answer
        // rather than none.
        //
        // A name that matches nothing changes nothing. An endpoint can be
        // deleted while a conversation still remembers it, and stranding that
        // conversation would be a worse answer than quietly routing normally.
        var reason = orderReason
        if let wanted = policy.preferred,
           let index = eligible.firstIndex(where: { $0.identifier == wanted }) {
            let chosen = eligible.remove(at: index)
            eligible.insert(chosen, at: 0)
            reason = "คุณเลือก \(wanted) ไว้สำหรับคำถามนี้ — ถ้าเรียกไม่ได้จะไล่ต่อตามลำดับเดิม"
        }

        return (eligible, RoutingChoice(order: eligible.map(\.identifier),
                                        orderReason: reason,
                                        excluded: excluded))
    }

    // MARK: - money

    /// Nil when this executor may run: free tiers always, metered ones only
    /// with the governor's agreement.
    private func budgetRefusal(for executor: any LLMExecutor,
                               request: LLMRequest) async -> String? {
        guard executor.tier.isMetered, let governor else { return nil }
        let decision = await governor.mayspend(promptTokens: request.estimatedPromptTokens,
                                               maxTokens: request.maxTokens,
                                               price: executor.price)
        return decision.isAllowed ? nil : decision.reason
    }

    /// The real cost, once the endpoint has said what it actually used.
    private func accountIfMetered(executor: any LLMExecutor, usage: LLMUsage?) async {
        guard executor.tier.isMetered, let governor, let usage else { return }
        await governor.account(promptTokens: usage.promptTokens,
                               completionTokens: usage.completionTokens,
                               price: executor.price,
                               endpoint: executor.identifier,
                               model: executor.identifier)
    }

    /// Order for work that must not be got wrong (§9.2): the self-hosted model
    /// first, the local one behind it, a metered one last, and on-device never
    /// (it is filtered out before this).
    private static func heavyWorkRank(_ tier: ModelTier) -> Int {
        switch tier {
        case .selfHosted: 0
        case .localMLX: 1
        case .paid: 2
        case .onDevice: 3
        }
    }

    // MARK: - availability cache

    private func isAvailable(_ executor: any LLMExecutor) async -> Bool {
        let now = ContinuousClock.now
        if let cached = availability[executor.identifier],
           cached.checkedAt.duration(to: now) < availabilityTTL {
            return cached.ok
        }
        let ok = await executor.isAvailable()
        availability[executor.identifier] = (ok, now)
        return ok
    }

    private func markUnavailable(_ executor: any LLMExecutor) {
        availability[executor.identifier] = (false, ContinuousClock.now)
    }

    /// Lets the UI force a recheck after the user fixes an endpoint.
    public func invalidateAvailability() {
        availability.removeAll()
    }

    // MARK: - observability

    private func shortOutcome(_ error: LLMError) -> String {
        switch error {
        case .refused: "refused"
        case .contextOverflow: "context overflow"
        case .unsupported: "unsupported"
        case .unavailable: "unavailable"
        case .timeout: "timeout"
        case .transport: "transport"
        case .http(let status, _): "http \(status)"
        case .decoding: "decoding"
        case .cancelled: "cancelled"
        }
    }

    private func record(executor: any LLMExecutor,
                        request: LLMRequest,
                        outcome: String,
                        usage: LLMUsage?,
                        escalatedFrom attempts: [RoutingAttempt]) async {
        guard let sink else { return }
        var span = Span(name: "llm:\(executor.identifier)", status: outcome == "ok" ? .succeeded : .failed)
        span.endedAt = Date()
        span.promptTokens = usage?.promptTokens
        span.completionTokens = usage?.completionTokens
        if !attempts.isEmpty {
            // The escalation trail is the answer to "why was that slow?".
            span.detail = "escalated past " + attempts.map { "\($0.executor):\($0.outcome)" }
                .joined(separator: ", ")
        }
        await sink.record(span)
    }

    private func recordExhausted(_ attempts: [RoutingAttempt]) async {
        guard let sink else { return }
        var span = Span(name: "llm:exhausted", status: .failed)
        span.endedAt = Date()
        span.detail = attempts.map { "\($0.executor):\($0.outcome)" }.joined(separator: ", ")
        await sink.record(span)
    }
}

/// Peeks the first event of a stream so routing can escalate on an immediate
/// refusal, then hands the remainder on untouched.
///
/// This exists because escalation is only honest *before* the caller has seen
/// any text: swapping models after tokens have shipped would splice two
/// different answers together.
private final class ProbedStream: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<LLMEvent, Error>.AsyncIterator

    init(_ stream: AsyncThrowingStream<LLMEvent, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func first() async throws -> LLMEvent? {
        try await iterator.next()
    }

    func rest(startingWith first: LLMEvent?) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    if let first { continuation.yield(first) }
                    while let event = try await iterator.next() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
