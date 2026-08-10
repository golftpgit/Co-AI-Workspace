import Testing
import Foundation
import AgentKit
import Observability
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// v1 bound each approval to the channel that raised it, so approving from
// Telegram meant reimplementing the flow there. The tests below are the
// contract that replaces it: one request, every channel, one resolution.
// ─────────────────────────────────────────────────────────────

private actor Inbox {
    private(set) var presented: [ApprovalRequest.ID] = []
    private(set) var resolved: [(ApprovalRequest.ID, ApprovalDecision)] = []
    func present(_ id: ApprovalRequest.ID) { presented.append(id) }
    func resolve(_ id: ApprovalRequest.ID, _ decision: ApprovalDecision) { resolved.append((id, decision)) }
    var presentedCount: Int { presented.count }
    var resolvedCount: Int { resolved.count }
    var lastDecision: ApprovalDecision? { resolved.last?.1 }
}

/// A channel that just records. `present` returning is not an answer — the
/// answer comes back through `broker.submit`, exactly as a real channel's
/// button handler would.
private func recorder(_ name: String, into inbox: Inbox) -> CallbackChannel {
    CallbackChannel(id: ChannelID(name),
                    onPresent: { await inbox.present($0.id) },
                    onResolved: { await inbox.resolve($0, $1) })
}

private func request(_ tool: String = "run_shell") -> ApprovalRequest {
    ApprovalRequest(toolName: tool, risk: .high, detail: "\(tool)(rm -rf build)")
}

@Suite("Approval broadcast and first-response-wins")
struct ApprovalBrokerTests {
    @Test("one request reaches every subscribed channel")
    func broadcastsToAll() async throws {
        let gui = Inbox(), telegram = Inbox()
        let broker = ApprovalBroker()
        await broker.subscribe(recorder("gui", into: gui))
        await broker.subscribe(recorder("telegram", into: telegram))

        let pending = request()
        let answering = Task { await broker.request(pending) }
        try await waitUntil { await gui.presentedCount == 1 }
        try await waitUntil { await telegram.presentedCount == 1 }

        await broker.submit(pending.id, decision: .approved, from: ChannelID("telegram"))
        let outcome = await answering.value
        #expect(outcome == .decided(.approved, by: ChannelID("telegram")))
    }

    /// The race the broker exists to own. Both channels answer; exactly one
    /// wins and the loser is told so rather than silently ignored.
    @Test("two channels answering at once resolve exactly once")
    func firstResponseWins() async throws {
        let gui = Inbox(), telegram = Inbox()
        let broker = ApprovalBroker()
        await broker.subscribe(recorder("gui", into: gui))
        await broker.subscribe(recorder("telegram", into: telegram))

        let pending = request()
        let answering = Task { await broker.request(pending) }
        try await waitUntil { await gui.presentedCount == 1 }
        try await waitUntil { await telegram.presentedCount == 1 }

        async let first = broker.submit(pending.id, decision: .approved, from: ChannelID("gui"))
        async let second = broker.submit(pending.id, decision: .rejected(reason: "ไม่เอา"),
                                         from: ChannelID("telegram"))
        let accepted = [await first, await second]

        #expect(accepted.filter { $0 }.count == 1, "exactly one answer may win")
        let outcome = await answering.value
        #expect(outcome == .decided(.approved, by: ChannelID("gui"))
                || outcome == .decided(.rejected(reason: "ไม่เอา"), by: ChannelID("telegram")))

        // Both sides learn the result, so the losing channel can retract its
        // own prompt instead of leaving a dead button on screen.
        try await waitUntil { await gui.resolvedCount == 1 }
        try await waitUntil { await telegram.resolvedCount == 1 }
        let guiDecision = await gui.lastDecision
        #expect(await telegram.lastDecision == guiDecision)
    }

    @Test("a late answer is rejected instead of resolving twice")
    func lateAnswerIsRefused() async throws {
        let gui = Inbox()
        let broker = ApprovalBroker()
        await broker.subscribe(recorder("gui", into: gui))

        let pending = request()
        let answering = Task { await broker.request(pending) }
        try await waitUntil { await gui.presentedCount == 1 }

        #expect(await broker.submit(pending.id, decision: .approved) == true)
        _ = await answering.value
        #expect(await broker.submit(pending.id, decision: .rejected(reason: "เปลี่ยนใจ")) == false)
    }

    /// Silence is not consent. With nowhere to ask, the gate must read a denial.
    @Test("no subscribed channel denies rather than waits forever")
    func noChannelsDenies() async {
        let broker = ApprovalBroker()
        let outcome = await broker.request(request())
        #expect(outcome == .noChannels)
        #expect(outcome.decision == .rejected(reason: "ไม่มีช่องทางที่รับคำขออนุมัติอยู่"))
    }

    @Test("a channel that connects late still sees what is waiting")
    func lateSubscriberSeesOutstanding() async throws {
        let gui = Inbox(), telegram = Inbox()
        let broker = ApprovalBroker()
        await broker.subscribe(recorder("gui", into: gui))

        let pending = request()
        let answering = Task { await broker.request(pending) }
        try await waitUntil { await gui.presentedCount == 1 }

        await broker.subscribe(recorder("telegram", into: telegram))
        try await waitUntil { await telegram.presentedCount == 1 }
        #expect(await broker.outstandingRequests.map(\.id) == [pending.id])

        await broker.submit(pending.id, decision: .approved)
        _ = await answering.value
        #expect(await broker.outstandingRequests.isEmpty)
    }

    @Test("a timeout resolves as a denial, never as an approval")
    func timeoutDenies() async throws {
        let gui = Inbox()
        let broker = ApprovalBroker()
        await broker.subscribe(recorder("gui", into: gui))

        let outcome = await broker.request(request(), timeout: .milliseconds(120))
        #expect(outcome == .timedOut)
        #expect(outcome.decision == .rejected(reason: "หมดเวลารออนุมัติ"))
        #expect(await broker.outstandingRequests.isEmpty)
    }

    @Test("cancelling a turn releases everything it was waiting on")
    func cancelAllReleases() async throws {
        let gui = Inbox()
        let broker = ApprovalBroker()
        await broker.subscribe(recorder("gui", into: gui))

        let pending = request()
        let answering = Task { await broker.request(pending) }
        try await waitUntil { await gui.presentedCount == 1 }

        await broker.cancelAll()
        #expect(await answering.value == .cancelled)
    }

    @Test("the whole approval life cycle is one span, start to answer")
    func spansCoverTheWait() async throws {
        let sink = InMemorySpanSink()
        let gui = Inbox()
        let broker = ApprovalBroker(spanSink: sink)
        await broker.subscribe(recorder("gui", into: gui))

        let pending = request()
        let answering = Task { await broker.request(pending) }
        try await waitUntil { await gui.presentedCount == 1 }
        #expect(await sink.spans.first?.status == .awaitingApproval)

        await broker.submit(pending.id, decision: .approved, from: ChannelID("gui"))
        _ = await answering.value

        let spans = await sink.spans
        #expect(spans.last?.status == .succeeded)
        #expect(spans.last?.detail?.contains("approved by gui") == true)
        // Same span id start and end, so the Live Monitor shows one row.
        #expect(Set(spans.map(\.id.rawValue)).count == 1)
    }
}

/// Polls a condition instead of sleeping a fixed amount: the broker's fan-out
/// is asynchronous, and a fixed sleep is either flaky or slow.
private func waitUntil(timeout: Duration = .seconds(2),
                       _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never became true within \(timeout)")
}
