import Testing
import Foundation
import AgentKit
import Knowledge
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// §11.6's promise is that a decision is made once. That promise is only worth
// anything if it survives quitting the app.
// ─────────────────────────────────────────────────────────────

private func side(_ text: String, tier: SourceTier, year: Int, title: String) -> ConflictSide {
    ConflictSide(text: text,
                 provenance: Provenance(documentID: title, title: title,
                                        origin: .upload(filename: "\(title).pdf"),
                                        tier: tier, year: year))
}

private let now = Calendar(identifier: .gregorian)
    .date(from: DateComponents(year: 2026, month: 8, day: 11))!

@Suite("Conflict store", .serialized)
struct ConflictStoreTests {
    @Test("an open conflict survives a restart", .timeLimit(.minutes(2)))
    func openConflictRoundTrips() async throws {
        guard let server = try await makeServer(port: 18_470) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConflictStore(client: await server.client)

        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐานคือเท่าไร",
            a: side("ค่ามาตรฐานคือ 5", tier: .t2, year: 2025, title: "งานวิจัย ก"),
            b: side("ค่ามาตรฐานคือ 7", tier: .t2, year: 2024, title: "งานวิจัย ข"),
            scope: .central, now: now)
        try await store.save(conflict, scope: .central)

        let loaded = try await store.open(scope: .central)
        #expect(loaded.count == 1)
        let restored = try #require(loaded.first)

        // Both sides verbatim: a conflict outlives the documents that caused
        // it, and the card still has to show what was actually said.
        #expect(restored.a.text == "ค่ามาตรฐานคือ 5")
        #expect(restored.b.text == "ค่ามาตรฐานคือ 7")
        #expect(restored.a.provenance.tier == .t2)
        #expect(restored.question == "ค่ามาตรฐานคือเท่าไร")
        #expect(restored.isOpen)
        // The reasons are stored as written, not recomputed — reopening this
        // in a year should show what was weighed then.
        #expect(restored.weightAReasons.contains("T2"))
        // Regression: booleans decoded as false whatever was stored, because
        // SurrealValue had no accessor for them and every caller guessed.
        #expect(restored.needsHuman, "the card forgot that it needs a person")
    }

    @Test("a decision survives, so the question is not asked twice",
          .timeLimit(.minutes(2)))
    func decisionRoundTrips() async throws {
        guard let server = try await makeServer(port: 18_471) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConflictStore(client: await server.client)

        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐาน",
            a: side("5", tier: .t2, year: 2025, title: "ก"),
            b: side("7", tier: .t2, year: 2024, title: "ข"),
            scope: .central, now: now)
        _ = ledger.decide(conflict.id, .bothInContext(condition: "ต่างกันตามช่วงอายุ"),
                          scope: .central, now: now)
        let decided = try #require(ledger.all.first)
        try await store.save(decided, scope: .central)

        let restored = try #require(try await store.load(scope: .central).first)
        #expect(restored.isOpen == false)
        #expect(restored.decision?.decidedByHuman == true)
        guard case .bothInContext(let condition) = restored.decision?.resolution else {
            Issue.record("resolution lost its shape: \(String(describing: restored.decision))")
            return
        }
        // The condition is the decision. Losing it would leave "it depends"
        // with nothing after it.
        #expect(condition == "ต่างกันตามช่วงอายุ")
    }

    @Test("re-saving the same conflict keeps one row", .timeLimit(.minutes(2)))
    func savingTwiceIsIdempotent() async throws {
        guard let server = try await makeServer(port: 18_472) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConflictStore(client: await server.client)

        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐาน",
            a: side("5", tier: .t2, year: 2025, title: "ก"),
            b: side("7", tier: .t2, year: 2024, title: "ข"),
            scope: .central, now: now)

        try await store.save(conflict, scope: .central)
        try await store.save(conflict, scope: .central)
        #expect(try await store.load(scope: .central).count == 1)
    }

    /// P3.7's remainder: a history you can go back on.
    @Test("a reversed decision leaves both the old decision and the reason behind",
          .timeLimit(.minutes(2)))
    func decisionsCanBeReversedWithoutLosingTheOldOne() async throws {
        guard let server = try await makeServer(port: 18_474) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConflictStore(client: await server.client)

        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐาน",
            a: side("5", tier: .t2, year: 2025, title: "ก"),
            b: side("7", tier: .t2, year: 2024, title: "ข"),
            scope: .central, now: now)
        try await store.save(conflict, scope: .central)

        try await store.recordDecision(
            ConflictDecision(resolution: .preferA(reason: "ใหม่กว่า"), scope: .central,
                             decidedAt: now, decidedByHuman: true),
            for: conflict.id, note: "ตัดสินครั้งแรก")
        #expect(try await store.open(scope: .central).isEmpty)

        // Somebody found out the newer paper was retracted.
        try await store.reopen(conflict.id, reason: "งานที่เลือกไว้ถูกถอนตีพิมพ์")
        #expect(try await store.open(scope: .central).count == 1,
                "reopening left the card closed")

        try await store.recordDecision(
            ConflictDecision(resolution: .preferB(reason: "อีกฝั่งยังยืนอยู่"), scope: .central,
                             decidedAt: now, decidedByHuman: true),
            for: conflict.id, note: "ตัดสินใหม่หลังการถอนตีพิมพ์")

        let history = try await store.history(of: conflict.id)
        #expect(history.count == 3, "the history lost an entry")
        // Nothing was overwritten: the decision that was later reversed is
        // still readable, which is the entire point of a reversible history.
        guard case .preferA = history.first?.decision?.resolution else {
            Issue.record("the original decision is gone: \(history)")
            return
        }
        #expect(history[1].isReopening)
        #expect(history[1].note.contains("ถอนตีพิมพ์"))
        guard case .preferB = history.last?.decision?.resolution else {
            Issue.record("the current decision is not the last entry: \(history)")
            return
        }
        // Oldest first, so "what did we think, and when did that change" reads
        // top to bottom.
        #expect(history[0].recordedAt <= history[1].recordedAt)
    }

    /// A reversal with no reason is indistinguishable from a mis-click when
    /// somebody meets it in six months.
    @Test("reopening without a reason is refused", .timeLimit(.minutes(2)))
    func reopeningNeedsAReason() async throws {
        guard let server = try await makeServer(port: 18_475) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConflictStore(client: await server.client)

        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐาน",
            a: side("5", tier: .t2, year: 2025, title: "ก"),
            b: side("7", tier: .t2, year: 2024, title: "ข"),
            scope: .central, now: now)
        try await store.save(conflict, scope: .central)
        try await store.recordDecision(
            ConflictDecision(resolution: .preferA(reason: "ใหม่กว่า"), scope: .central,
                             decidedAt: now, decidedByHuman: true),
            for: conflict.id)

        await #expect(throws: ConflictHistoryError.reversalNeedsAReason) {
            try await store.reopen(conflict.id, reason: "   ")
        }
        // And the card is still decided — a refused reversal changes nothing.
        #expect(try await store.open(scope: .central).isEmpty)
    }

    @Test("a decision made for one project does not bind another",
          .timeLimit(.minutes(2)))
    func scopesAreSeparate() async throws {
        guard let server = try await makeServer(port: 18_473) else { return }
        defer { Task { await server.shutdown() } }
        let store = ConflictStore(client: await server.client)

        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐาน",
            a: side("5", tier: .t2, year: 2025, title: "ก"),
            b: side("7", tier: .t2, year: 2024, title: "ข"),
            scope: .project(ProjectID("alpha")), now: now)
        try await store.save(conflict, scope: .project(ProjectID("alpha")))

        #expect(try await store.load(scope: .project(ProjectID("alpha"))).count == 1)
        #expect(try await store.load(scope: .project(ProjectID("beta"))).isEmpty)
        #expect(try await store.load(scope: .central).isEmpty)
    }
}
