import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P3.6's Done-when: contradictory documents produce a Conflict Card; once
// decided the same question is not asked again; a stronger source reopens it.
// ─────────────────────────────────────────────────────────────

private func side(_ text: String, tier: SourceTier, year: Int?,
                  title: String = "เอกสาร", corroborations: Int = 0) -> ConflictSide {
    ConflictSide(
        text: text,
        provenance: Provenance(documentID: title, title: title,
                               origin: .upload(filename: "\(title).pdf"), tier: tier,
                               year: year),
        corroborations: corroborations)
}

private let now = Calendar(identifier: .gregorian)
    .date(from: DateComponents(year: 2026, month: 8, day: 11))!

@Suite("Conflict ledger")
struct ConflictLedgerTests {
    @Test("a clear-cut difference is decided without asking")
    func obviousConflictIsAutomatic() {
        var ledger = ConflictLedger()
        // §11.6's own example: T1 from 2026 against T5 from 2019.
        let conflict = ledger.record(
            question: "ขนาดยาที่แนะนำคือเท่าไร",
            a: side("แนะนำ 500 มก. ต่อวัน", tier: .t1, year: 2026, title: "แนวทางเวชปฏิบัติ"),
            b: side("แนะนำ 1000 มก. ต่อวัน", tier: .t5, year: 2019, title: "บล็อกสุขภาพ"),
            scope: .central, now: now)

        #expect(conflict.needsHuman == false)
        #expect(conflict.decision?.decidedByHuman == false)
        if case .preferA = conflict.decision?.resolution {} else {
            Issue.record("expected the T1 source to win, got \(String(describing: conflict.decision))")
        }
        // Decided, but on the record as having been a conflict — the point of
        // §11.6 is that the alternative never vanishes.
        #expect(ledger.all.count == 1)
    }

    @Test("a close call goes to the human")
    func closeConflictNeedsAHuman() {
        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐานคือเท่าไร",
            a: side("ค่ามาตรฐานคือ 5", tier: .t2, year: 2025, title: "งานวิจัย ก"),
            b: side("ค่ามาตรฐานคือ 7", tier: .t2, year: 2024, title: "งานวิจัย ข"),
            scope: .central, now: now)

        #expect(conflict.needsHuman)
        #expect(conflict.isOpen)
        #expect(ledger.open.count == 1)
    }

    @Test("the card carries both sides verbatim and says why")
    func cardHasWhatTheHumanNeeds() {
        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐานคือเท่าไร",
            a: side("ค่ามาตรฐานคือ 5", tier: .t2, year: 2025, title: "งานวิจัย ก",
                    corroborations: 2),
            b: side("ค่ามาตรฐานคือ 7", tier: .t2, year: 2024, title: "งานวิจัย ข"),
            scope: .central, now: now)

        // Verbatim, not summarised.
        #expect(conflict.a.text == "ค่ามาตรฐานคือ 5")
        #expect(conflict.b.text == "ค่ามาตรฐานคือ 7")
        // Provenance on both sides, so the user need not open the documents.
        #expect(conflict.a.provenance.tier == .t2)
        #expect(conflict.b.provenance.year == 2024)
        // And a readable reason for the weight, not just a number.
        #expect(conflict.weightA.reasons.contains { $0.contains("T2") })
        #expect(conflict.weightA.reasons.contains { $0.contains("สอดคล้อง") })
        #expect(conflict.weightA.score > conflict.weightB.score)
    }

    @Test("a decision is not asked for twice")
    func decisionsBecomePrecedent() {
        var ledger = ConflictLedger()
        let a = side("ค่ามาตรฐานคือ 5", tier: .t2, year: 2025, title: "งานวิจัย ก")
        let b = side("ค่ามาตรฐานคือ 7", tier: .t2, year: 2024, title: "งานวิจัย ข")

        let first = ledger.record(question: "ค่ามาตรฐาน", a: a, b: b, scope: .central, now: now)
        #expect(first.isOpen)

        let decided = ledger.decide(first.id, .preferB(reason: "วัดในบริบทของไทย"),
                                    scope: .central, now: now)
        #expect(decided)

        // Same disagreement encountered again in a later turn.
        let second = ledger.record(question: "ค่ามาตรฐาน", a: a, b: b, scope: .central, now: now)
        #expect(second.isOpen == false)
        #expect(second.decision?.decidedByHuman == true)
        #expect(ledger.open.isEmpty)
    }

    @Test("a human can overrule what the system decided")
    func humanOverridesAutomatic() {
        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ขนาดยา",
            a: side("500 มก.", tier: .t1, year: 2026),
            b: side("1000 มก.", tier: .t5, year: 2019, title: "บล็อก"),
            scope: .central, now: now)
        #expect(conflict.decision?.decidedByHuman == false)

        let overruled = ledger.decide(
            conflict.id,
            .bothInContext(condition: "ผู้ใหญ่ใช้ 500, ผู้ป่วยไตเสื่อมใช้ต่ำกว่า"),
            scope: .central, now: now)
        #expect(overruled)
        #expect(ledger.decision(for: conflict.id)?.decidedByHuman == true)
    }

    @Test("a decision can be scoped to one project")
    func decisionsCarryScope() {
        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐาน",
            a: side("5", tier: .t2, year: 2025), b: side("7", tier: .t2, year: 2024),
            scope: .project(ProjectID("alpha")), now: now)

        _ = ledger.decide(conflict.id, .preferA(reason: "ตรงกับบริบทของโครงการ"),
                          scope: .project(ProjectID("alpha")), now: now)
        #expect(ledger.decision(for: conflict.id)?.scope == .project(ProjectID("alpha")))
    }

    @Test("a stronger source reopens a settled question")
    func betterEvidenceReopens() {
        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐาน",
            a: side("5", tier: .t3, year: 2025), b: side("7", tier: .t3, year: 2024),
            scope: .central, now: now)
        _ = ledger.decide(conflict.id, .preferA(reason: "ใหม่กว่า"), scope: .central, now: now)
        #expect(ledger.decision(for: conflict.id) != nil)

        let authority = Provenance(documentID: "who", title: "WHO guideline",
                                   origin: .web(url: URL(string: "https://who.int/g")!),
                                   tier: .t1, year: 2026)
        let reopened = ledger.reopen(conflict.id, because: authority)
        #expect(reopened)
        #expect(ledger.decision(for: conflict.id) == nil)
        #expect(ledger.open.count == 1)
    }

    @Test("a weaker source does not reopen anything")
    func weakerEvidenceDoesNotReopen() {
        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ค่ามาตรฐาน",
            a: side("5", tier: .t1, year: 2026), b: side("7", tier: .t4, year: 2020),
            scope: .central, now: now)

        let blog = Provenance(documentID: "blog", title: "บล็อก",
                              origin: .web(url: URL(string: "https://example.com/p")!),
                              tier: .t5, year: 2026)
        // Otherwise any new page on the web could reopen every settled
        // question, and nothing would ever stay decided.
        let reopened = ledger.reopen(conflict.id, because: blog)
        #expect(reopened == false)
        #expect(ledger.decision(for: conflict.id) != nil)
    }

    @Test("ten weak sources agreeing is not an authority")
    func corroborationIsCapped() {
        let weak = ConflictLedger.weigh(
            side("x", tier: .t5, year: 2026, corroborations: 10), now: now)
        let strong = ConflictLedger.weigh(side("y", tier: .t1, year: 2026), now: now)
        #expect(strong.score > weak.score, "weak \(weak.score) vs strong \(strong.score)")
    }

    @Test("a newer year does not outrank a tier step")
    func recencyDoesNotBeatCredibility() {
        let freshBlog = ConflictLedger.weigh(side("x", tier: .t5, year: 2026), now: now)
        let oldStandard = ConflictLedger.weigh(side("y", tier: .t1, year: 2019), now: now)
        #expect(oldStandard.score > freshBlog.score)
    }
}
