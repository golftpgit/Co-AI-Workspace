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

    public init(impact: RiskLevel = .low,
                latencySensitive: Bool = false,
                allowMetered: Bool = false) {
        self.impact = impact
        self.latencySensitive = latencySensitive
        self.allowMetered = allowMetered
    }

    /// Cheap, throwaway work: labels, groupings, short extractions.
    public static let disposable = RoutingPolicy(impact: .low, latencySensitive: true)
    /// Decisions that shape what the system does next: planning, delegation.
    public static let consequential = RoutingPolicy(impact: .high)
}

/// Why a candidate was skipped — kept so the UI can explain a slow or
/// surprising answer instead of leaving the user guessing.
public struct RoutingAttempt: Sendable {
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
    private let executors: [any LLMExecutor]
    private let sink: (any SpanSink)?
    /// Availability is probed rarely, not per call: a probe on the hot path
    /// would cost more than the request it is guarding.
    private var availability: [String: (ok: Bool, checkedAt: ContinuousClock.Instant)] = [:]
    private let availabilityTTL: Duration

    public init(executors: [any LLMExecutor],
                spanSink: (any SpanSink)? = nil,
                availabilityTTL: Duration = .seconds(30)) {
        // Cheapest first; escalation walks up the tiers.
        self.executors = executors.sorted { $0.tier < $1.tier }
        self.sink = spanSink
        self.availabilityTTL = availabilityTTL
    }

    /// Runs the request on the first tier that can serve it, escalating past
    /// refusals, overflows and outages. There is intentionally no variant of
    /// this call that gives up after one attempt.
    public func complete(_ request: LLMRequest,
                         policy: RoutingPolicy = .disposable) async throws -> LLMCompletion {
        var attempts: [RoutingAttempt] = []

        for executor in try candidates(for: request, policy: policy) {
            guard await isAvailable(executor) else {
                attempts.append(.init(executor: executor.identifier, tier: executor.tier,
                                      outcome: "unavailable"))
                continue
            }
            do {
                let completion = try await executor.complete(request)
                await record(executor: executor, request: request, outcome: "ok",
                             usage: completion.usage, escalatedFrom: attempts)
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
        -> (executor: String, tier: ModelTier, events: AsyncThrowingStream<LLMEvent, Error>) {
        var attempts: [RoutingAttempt] = []

        for executor in try candidates(for: request, policy: policy) {
            guard await isAvailable(executor) else {
                attempts.append(.init(executor: executor.identifier, tier: executor.tier,
                                      outcome: "unavailable"))
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
                return (executor.identifier, executor.tier, stream)
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
                            policy: RoutingPolicy) throws -> [any LLMExecutor] {
        let needed = request.estimatedPromptTokens + request.maxTokens

        var eligible = executors.filter { executor in
            if !request.tools.isEmpty && !executor.capabilities.supportsTools { return false }
            if request.responseSchema != nil && !executor.capabilities.supportsStructuredOutput { return false }
            if executor.capabilities.contextWindow < needed { return false }
            if executor.tier.isMetered && !policy.allowMetered { return false }
            // High-impact work skips the on-device model: its answers are not
            // stable enough to make decisions on (ARCHITECTURE E.7).
            if policy.impact == .high && executor.tier == .onDevice { return false }
            return true
        }

        if eligible.isEmpty {
            throw RoutingError(attempts: executors.map {
                .init(executor: $0.identifier, tier: $0.tier, outcome: "ineligible")
            })
        }

        // Latency-sensitive work still prefers cheap-and-close; everything else
        // uses the same order, so the chain is predictable either way.
        if !policy.latencySensitive {
            eligible.sort { lhs, rhs in
                // Prefer a locally hosted model over on-device when quality
                // matters more than speed, but never above self-hosted.
                (lhs.tier == .onDevice ? 1 : 0, lhs.tier.rawValue)
                    < (rhs.tier == .onDevice ? 1 : 0, rhs.tier.rawValue)
            }
        }
        return eligible
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
