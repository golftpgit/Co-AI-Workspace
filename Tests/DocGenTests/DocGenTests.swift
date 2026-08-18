import Testing
import Foundation
import AgentKit
import Knowledge
@testable import DocGen

// ─────────────────────────────────────────────────────────────
// Citations and the Limitations section (ARCHITECTURE §14.1, P7.7/P7.8).
//
// The two Done-whens are about things that must be true of every draft rather
// than of a happy path: every sentence taken from the knowledge base carries a
// real provenance, and the Limitations section writes itself out of facts the
// system already recorded.
// ─────────────────────────────────────────────────────────────

private func source(_ id: String, title: String, tier: SourceTier,
                    authors: [String] = ["สมชาย ก."], year: Int? = 2025,
                    page: Int? = nil) -> Provenance {
    Provenance(documentID: id, title: title, origin: .upload(filename: "\(id).pdf"),
               tier: tier, authors: authors, year: year, page: page)
}

private let webSource = Provenance(
    documentID: "who1", title: "Guideline on metformin",
    origin: .web(url: URL(string: "https://www.who.int/guide")!),
    tier: .t1, authors: ["WHO"], year: 2026,
    accessedAt: Date(timeIntervalSince1970: 1_786_000_000))

@Suite("Citations")
struct CitationTests {

    /// The Done-when, as a property of the type: there is no initialiser that
    /// makes a cited sentence without a source.
    @Test("a cited sentence cannot exist without its provenance")
    func citationCarriesItsSource() {
        let cited = CitedText("เมตฟอร์มินลด HbA1c ได้ราว 1%", from: source("a", title: "การศึกษา ก", tier: .t2))
        #expect(cited.provenance.documentID == "a")
        #expect(cited.provenance.tier == .t2)
    }

    @Test("APA cites by author and year; the numbered styles number by first appearance")
    func inlineMarkers() {
        let first = CitedText("ข้อความหนึ่ง", from: source("a", title: "งาน ก", tier: .t1))
        let second = CitedText("ข้อความสอง", from: source("b", title: "งาน ข", tier: .t2,
                                                          authors: ["สมหญิง ข.", "สมศักดิ์ ค."]))
        let again = CitedText("ข้อความสาม", from: source("a", title: "งาน ก", tier: .t1))

        var apa = Bibliography(style: .apa)
        #expect(apa.marker(for: first) == "(สมชาย ก., 2025)")
        #expect(apa.marker(for: second) == "(สมหญิง ข. & สมศักดิ์ ค., 2025)")

        var ieee = Bibliography(style: .ieee)
        #expect(ieee.marker(for: first) == "[1]")
        #expect(ieee.marker(for: second) == "[2]")
        // The same work keeps its number however many sentences cite it.
        #expect(ieee.marker(for: again) == "[1]")
        #expect(ieee.works.count == 2)

        var vancouver = Bibliography(style: .vancouver)
        #expect(vancouver.marker(for: first) == "(1)")
    }

    @Test("the bibliography lists works, not sentences")
    func bibliographyListsWorks() {
        var bibliography = Bibliography(style: .ieee)
        let rendered = bibliography.render([
            CitedText("หนึ่ง", from: source("a", title: "งาน ก", tier: .t1)),
            CitedText("สอง", from: source("a", title: "งาน ก", tier: .t1, page: 12)),
            CitedText("สาม", from: source("b", title: "งาน ข", tier: .t3)),
        ])
        #expect(rendered.contains("หนึ่ง [1]"))
        #expect(rendered.contains("สาม [2]"))

        let entries = bibliography.entries()
        #expect(entries.count == 2)
        #expect(entries[0].hasPrefix("[1] สมชาย ก."))
        #expect(entries[0].contains("งาน ก"))
        #expect(entries[0].contains("(T1)"))
    }

    /// §11.3 keeps `accessedAt` because the same URL says something else next
    /// month; a web citation without it is not checkable.
    @Test("a web source is cited with its URL and the date it was read")
    func webCitationsCarryAccessDate() {
        var bibliography = Bibliography(style: .vancouver)
        _ = bibliography.marker(for: CitedText("แนวทางล่าสุด", from: webSource))
        let entry = bibliography.entries()[0]
        #expect(entry.contains("https://www.who.int/guide"))
        #expect(entry.contains("accessed 2026-08-06") || entry.contains("accessed 2026-08-05"))
        #expect(entry.contains("(T1)"))
    }

    /// §14.1: a file with no author or year is flagged for the user to fill in
    /// rather than having something plausible written for it.
    @Test("a source with no author or year is flagged before anything is generated")
    func missingMetadataIsFlagged() {
        let audit = CitationAudit.audit([
            CitedText("ก", from: source("a", title: "งานที่ไม่มีข้อมูล", tier: .t3,
                                        authors: [], year: nil)),
            CitedText("ข", from: source("b", title: "งานที่ครบ", tier: .t2)),
        ])
        #expect(!audit.isComplete)
        #expect(audit.missing.count == 1)
        #expect(audit.missing[0].fields == ["author", "year"])
        // "n.d." rather than a guessed year — the flag above is what fixes it.
        #expect(Bibliography.year(source("a", title: "x", tier: .t3, year: nil)) == "n.d.")
    }

    @Test("work the system wrote itself has no author to be missing")
    func selfAuthoredIsNotFlagged() {
        let authored = Provenance.authored(documentID: "run1",
                                           title: "ผลการวิเคราะห์รอบที่ 3",
                                           runID: "run1")
        #expect(CitationAudit.audit([CitedText("ค่าเฉลี่ยคือ 7.2", from: authored)]).isComplete)
    }
}

@Suite("Cross-source corroboration")
struct CorroborationTests {

    /// §14.1: two or more T1–T2 sources is what lets something be written
    /// plainly.
    @Test("two strong sources is strong; one is not")
    func strongNeedsTwo() {
        let two = [CitedText("ก", from: source("a", title: "ก", tier: .t1)),
                   CitedText("ข", from: source("b", title: "ข", tier: .t2))]
        #expect(CrossSource.assess(two) == .strong)
        #expect(CrossSource.assess(two).mayStatePlainly)

        let one = [CitedText("ก", from: source("a", title: "ก", tier: .t1))]
        #expect(!CrossSource.assess(one).mayStatePlainly)
    }

    /// Quoting one paper three times is one source. A rule that counted
    /// sentences would let a single blog post look like a consensus.
    @Test("the same work cited three times is still one source")
    func repeatsAreOneWork() {
        let repeated = (1...3).map {
            CitedText("ประโยคที่ \($0)", from: source("a", title: "งานเดียว", tier: .t1))
        }
        guard case .weak(let reason) = CrossSource.assess(repeated) else {
            Issue.record("three quotes from one paper should not corroborate anything")
            return
        }
        #expect(reason.contains("a single source"))
    }

    /// §14.1 is explicit: ten weak sources are not two strong ones.
    @Test("weak sources do not add up to a strong claim")
    func weakSourcesDoNotAccumulate() {
        let many = (1...10).map {
            CitedText("ประโยค \($0)", from: source("w\($0)", title: "บล็อก \($0)", tier: .t5))
        }
        guard case .weak(let reason) = CrossSource.assess(many) else {
            Issue.record("ten T5 sources must not read as corroboration")
            return
        }
        #expect(reason.contains("T1–T3"))

        // One credible source standing behind them changes the verdict.
        let withSupport = many + [CitedText("ยืนยัน", from: source("t", title: "งานทบทวน", tier: .t3))]
        #expect(CrossSource.assess(withSupport) == .adequate)
    }

    @Test("no sources at all is not corroboration")
    func nothingIsWeak() {
        #expect(!CrossSource.assess([]).mayStatePlainly)
    }
}

@Suite("Automatic Limitations")
struct LimitationsTests {

    private func planWithAssumptions() -> AnalysisPlan {
        var plan = AnalysisPlan(title: "เมตฟอร์มิน")
        plan.add(AnalysisDecision(question: "ประชากรที่ศึกษา",
                                  value: "ผู้ป่วยเบาหวานชนิดที่ 2 อายุ ≥ 18",
                                  origin: .proposalStated))
        plan.add(AnalysisDecision(question: "นิยามของการติดตามครบ",
                                  value: "มีผลเลือดอย่างน้อย 2 ครั้งใน 12 เดือน",
                                  origin: .agentSuggested,
                                  note: "โครงร่างไม่ได้ระบุไว้"))
        return plan
    }

    /// P7.8's Done-when: the section is right without anyone asking for one.
    @Test("an assumption the proposal never made appears in Limitations by itself")
    func assumptionsBecomeLimitations() {
        let section = LimitationsBuilder.build(plan: planWithAssumptions())
        #expect(section.items.count == 1)
        #expect(section.items[0].kind == .assumption)
        #expect(section.items[0].text.contains("นิยามของการติดตามครบ"))
        #expect(section.items[0].text.contains("โครงร่างไม่ได้ระบุ"))
        // What the proposal did say is not a limitation.
        #expect(!section.items.contains { $0.subject == "ประชากรที่ศึกษา" })
    }

    /// The subtle one. By the time a plan is approved every `agent_suggested`
    /// has become `human_confirmed` — that is what approval *means* (§12.4) —
    /// so a builder reading `origin` would write an empty section for exactly
    /// the plans that need one.
    @Test("an approved plan still declares what the agent originally assumed")
    func approvalDoesNotEraseTheAssumption() throws {
        var plan = planWithAssumptions()
        let suggestion = plan.agentSuggestions[0].id
        plan.confirm(suggestion)
        try plan.approve(by: "the researcher")

        #expect(plan.agentSuggestions.isEmpty)      // §12.4's rule still holds
        let section = LimitationsBuilder.build(plan: plan)
        #expect(section.items.count == 1)
        #expect(section.items[0].text.contains("confirmed by the researcher"))
    }

    /// §11.6 keeps both sides verbatim precisely so this can be written.
    @Test("a passage that survived a disagreement says so")
    func resolvedConflictsAreDeclared() {
        var ledger = ConflictLedger()
        let conflict = ledger.record(
            question: "ให้ยาต่อกี่ชั่วโมงหลังผ่าตัด",
            a: ConflictSide(text: "ให้ต่ออีก 24 ชั่วโมง",
                            provenance: source("a", title: "แนวทาง 2026", tier: .t1)),
            b: ConflictSide(text: "หยุดได้ทันทีหลังผ่าตัด",
                            provenance: source("b", title: "ตำราเก่า", tier: .t5)),
            scope: .central)
        _ = ledger.decide(conflict.id, .preferA(reason: "แหล่งใหม่กว่าและ tier สูงกว่า"),
                          scope: .central)

        let section = LimitationsBuilder.build(conflicts: ledger.all)
        #expect(section.items.count == 1)
        #expect(section.items[0].kind == .resolvedConflict)
        #expect(section.items[0].text.contains("ให้ยาต่อกี่ชั่วโมงหลังผ่าตัด"))
        #expect(section.items[0].text.contains("the researcher"))
    }

    @Test("a conflict nobody has decided is not reported as a resolved one")
    func openConflictsAreNotDeclaredAsSettled() {
        var ledger = ConflictLedger()
        _ = ledger.record(question: "ยังไม่ตัดสิน",
                          a: ConflictSide(text: "ก", provenance: source("a", title: "ก", tier: .t2)),
                          b: ConflictSide(text: "ข", provenance: source("b", title: "ข", tier: .t2)),
                          scope: .central)
        #expect(LimitationsBuilder.build(conflicts: ledger.all).isEmpty)
    }

    @Test("thin evidence is declared, and strong evidence is not")
    func evidenceDensityIsDeclared() {
        let thin = LimitationsBuilder.build(citations: [
            CitedText("ข้อความ", from: source("w", title: "บล็อก", tier: .t5)),
            CitedText("อีกข้อความ", from: source("x", title: "บล็อกอื่น", tier: .t4)),
        ])
        #expect(thin.items.contains { $0.kind == .thinEvidence })

        let strong = LimitationsBuilder.build(citations: [
            CitedText("ก", from: source("a", title: "งาน ก", tier: .t1)),
            CitedText("ข", from: source("b", title: "งาน ข", tier: .t2)),
        ])
        #expect(strong.isEmpty)
    }

    /// §12.3 → §14.1: an assumption that failed is a limitation of the
    /// analysis, not a detail of it.
    @Test("a failed statistical assumption reaches the document")
    func statisticalWarningsReachTheDraft() {
        let section = LimitationsBuilder.build(
            statistical: ["t-test: ข้อมูลไม่ผ่านการตรวจการแจกแจงปกติ (Shapiro–Wilk p = 0.0003)"])
        #expect(section.items[0].kind == .statistical)
        #expect(section.rendered().contains("Shapiro–Wilk"))
    }

    /// A run with nothing to declare says so, which is a different statement
    /// from a section nobody wrote.
    @Test("a run with nothing to declare says that, rather than being absent")
    func emptySectionIsExplicit() {
        let section = LimitationsBuilder.build()
        #expect(section.isEmpty)
        #expect(section.rendered().contains("no limitation was recorded"))
    }

    @Test("everything a run recorded ends up in one section, in order")
    func everythingTogether() {
        let section = LimitationsBuilder.build(
            plan: planWithAssumptions(),
            citations: [CitedText("ก", from: source("w", title: "บล็อก", tier: .t5)),
                        CitedText("ข", from: source("x", title: "บล็อกอื่น", tier: .t5))],
            statistical: ["ANOVA: ความแปรปรวนไม่เท่ากันระหว่างกลุ่ม"])
        #expect(section.items.map(\.kind) == [.assumption, .thinEvidence, .statistical])
        let text = section.rendered()
        #expect(text.hasPrefix("Limitations of this study"))
        #expect(text.components(separatedBy: "•").count == 4)
    }
}
