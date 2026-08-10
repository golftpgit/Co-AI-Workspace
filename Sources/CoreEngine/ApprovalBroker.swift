import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// Approval Broker (ARCHITECTURE §5.4) — the fix for v1's largest piece of
// debt, where approving from Telegram would have meant writing the whole
// approval flow a second time (task K1, never finished).
//
// Here one request is broadcast to every subscribed channel at once and is
// not bound to the channel that triggered it. First response wins, and that
// is a property of this actor rather than something each channel has to get
// right: the resolution path runs on the broker's own serial executor, so a
// second answer arriving in the same instant finds the request already gone.
// ─────────────────────────────────────────────────────────────

public enum ApprovalOutcome: Sendable, Equatable {
    case decided(ApprovalDecision, by: ChannelID?)
    /// Nobody was listening. Not the same as "approved".
    case noChannels
    /// The turn was cancelled or the app is shutting down.
    case cancelled
    case timedOut

    /// How the gate reads it. Everything that is not an explicit approval
    /// denies — silence never means yes.
    public var decision: ApprovalDecision {
        switch self {
        case .decided(let decision, _): return decision
        case .noChannels: return .rejected(reason: "ไม่มีช่องทางที่รับคำขออนุมัติอยู่")
        case .cancelled: return .rejected(reason: "ยกเลิกก่อนมีคำตอบ")
        case .timedOut: return .rejected(reason: "หมดเวลารออนุมัติ")
        }
    }
}

public actor ApprovalBroker: ApprovalRequesting {
    private struct Pending {
        let request: ApprovalRequest
        var continuation: CheckedContinuation<ApprovalOutcome, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private var channels: [ChannelID: any Channel] = [:]
    private var pending: [ApprovalRequest.ID: Pending] = [:]
    private let sink: (any SpanSink)?
    private let log = AppLog.logger("approval")

    public init(spanSink: (any SpanSink)? = nil) {
        self.sink = spanSink
    }

    // MARK: - channels

    public func subscribe(_ channel: any Channel) {
        if channels[channel.id] != nil {
            // Legitimate on reopen, and a bug when it happens mid-session: the
            // replaced channel silently stops receiving. A GUI rebuilt on every
            // body pass did exactly this, and approvals went to an instance
            // nobody was rendering — the turn hung with no banner and no error.
            log.warning("channel '\(channel.id.rawValue, privacy: .public)' re-subscribed; the previous one will stop receiving")
        }
        channels[channel.id] = channel
        // A channel that connects mid-flight still sees what is waiting —
        // otherwise reopening the app hides a request that is still blocking
        // a turn.
        for request in pending.values.map(\.request) {
            Task { await channel.present(request) }
        }
    }

    public func unsubscribe(_ id: ChannelID) {
        channels.removeValue(forKey: id)
    }

    public var subscribedChannels: [ChannelID] { Array(channels.keys) }

    /// What a newly-opened Approvals page renders.
    public var outstandingRequests: [ApprovalRequest] {
        pending.values.map(\.request).sorted { $0.requestedAt < $1.requestedAt }
    }

    // MARK: - requesting

    /// Broadcasts and suspends until the first channel answers.
    public func request(_ request: ApprovalRequest,
                        timeout: Duration? = nil) async -> ApprovalOutcome {
        guard !channels.isEmpty else {
            await record(request, outcome: "no-channels")
            return .noChannels
        }

        let targets = Array(channels.values)
        await withSpan(request)

        return await withCheckedContinuation { continuation in
            var entry = Pending(request: request, continuation: continuation, timeoutTask: nil)
            if let timeout {
                entry.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolve(request.id, outcome: .timedOut)
                }
            }
            pending[request.id] = entry

            // Fan out after the request is recorded, so a channel that answers
            // instantly cannot arrive before there is anything to resolve.
            // One task per channel: a channel whose `present` is slow (a
            // Telegram round trip) must not delay the one the user is watching.
            for channel in targets {
                Task { await channel.present(request) }
            }
        }
    }

    /// `ApprovalRequesting` — what the hook chain calls. Collapses the outcome
    /// into a decision so the gate never has to guess what silence meant.
    public func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await self.request(request).decision
    }

    // MARK: - responding

    /// Called by whichever channel the human answered on.
    /// Returns false when someone else already answered — the losing channel
    /// gets a clear "already resolved" rather than a silent no-op.
    @discardableResult
    public func submit(_ id: ApprovalRequest.ID,
                       decision: ApprovalDecision,
                       from channel: ChannelID? = nil) async -> Bool {
        guard pending[id] != nil else {
            log.debug("late approval for \(id.rawValue, privacy: .public) ignored")
            return false
        }
        await resolve(id, outcome: .decided(decision, by: channel))
        return true
    }

    /// Used when the user stops the turn, or on shutdown.
    public func cancel(_ id: ApprovalRequest.ID) async {
        await resolve(id, outcome: .cancelled)
    }

    public func cancelAll() async {
        for id in pending.keys { await resolve(id, outcome: .cancelled) }
    }

    // MARK: - the single resolution path

    /// Every outcome — answer, timeout, cancellation — funnels through here,
    /// so "resolved exactly once" is one `removeValue` rather than a rule each
    /// call site has to remember.
    private func resolve(_ id: ApprovalRequest.ID, outcome: ApprovalOutcome) async {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel()
        entry.continuation?.resume(returning: outcome)

        let decision = outcome.decision
        let targets = Array(channels.values)
        // Tell everyone, including the channel that answered: a channel that
        // renders its own optimistic state still needs the authoritative one.
        for channel in targets {
            Task { await channel.approvalResolved(id, decision: decision) }
        }
        await record(entry.request, outcome: describe(outcome))
    }

    // MARK: - observability

    private func describe(_ outcome: ApprovalOutcome) -> String {
        switch outcome {
        case .decided(.approved, let by): return "approved by \(by?.rawValue ?? "unknown")"
        case .decided(.approvedWithEdit, let by): return "approved with edit by \(by?.rawValue ?? "unknown")"
        case .decided(.rejected(let reason), let by):
            return "rejected by \(by?.rawValue ?? "unknown")\(reason.map { ": \($0)" } ?? "")"
        case .noChannels: return "no-channels"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed out"
        }
    }

    private func withSpan(_ request: ApprovalRequest) async {
        guard let sink else { return }
        await sink.record(Span(id: SpanID(request.id.rawValue),
                               name: "approval:\(request.toolName)",
                               status: .awaitingApproval,
                               startedAt: request.requestedAt,
                               detail: request.detail))
    }

    private func record(_ request: ApprovalRequest, outcome: String) async {
        guard let sink else { return }
        var span = Span(id: SpanID(request.id.rawValue),
                        name: "approval:\(request.toolName)",
                        status: outcome.hasPrefix("approved") ? .succeeded : .failed,
                        startedAt: request.requestedAt)
        span.endedAt = Date()
        span.detail = outcome
        await sink.record(span)
    }
}

// MARK: - adapters

/// A `Channel` built from closures. The GUI, and later the notification
/// centre, need a channel without needing a class of their own.
public struct CallbackChannel: Channel {
    public let id: ChannelID
    private let onMessage: @Sendable (AgentMessage) async -> Void
    private let onPresent: @Sendable (ApprovalRequest) async -> Void
    private let onResolved: @Sendable (ApprovalRequest.ID, ApprovalDecision) async -> Void

    public init(id: ChannelID,
                onMessage: @escaping @Sendable (AgentMessage) async -> Void = { _ in },
                onPresent: @escaping @Sendable (ApprovalRequest) async -> Void,
                onResolved: @escaping @Sendable (ApprovalRequest.ID, ApprovalDecision) async -> Void = { _, _ in }) {
        self.id = id
        self.onMessage = onMessage
        self.onPresent = onPresent
        self.onResolved = onResolved
    }

    public func send(_ message: AgentMessage) async { await onMessage(message) }
    public func present(_ request: ApprovalRequest) async { await onPresent(request) }
    public func approvalResolved(_ id: ApprovalRequest.ID, decision: ApprovalDecision) async {
        await onResolved(id, decision)
    }
}
