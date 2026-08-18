import Testing
import Foundation
import AgentKit
@testable import Instruments

// ─────────────────────────────────────────────────────────────
// M15's gate and blueprint (ARCHITECTURE §20.3–§20.6, P11.2/P11.4/P11.6).
//
// Two of P11's Done-whens are about things that must be *impossible*:
//
//  • an item tied to nothing and not tagged demographic must fail publication;
//  • `PublishedInstrument` must be unforgeable — creatable only by the gate.
//
// The second one cannot be tested by writing the illegal line, because the point
// is that it does not compile. What a test can do is pin the two facts that make
// it true — no public initializer, and one producer — so that a later change which
// adds either is a change that breaks a test rather than a rule somebody forgot.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_research")

private func consent() -> ConsentText {
    ConsentText(purpose: Bilingual("ศึกษาความชุกของภาวะหมดไฟในพยาบาล"),
                whatIsCollected: Bilingual("ข้อมูลพื้นฐานและคะแนนแบบวัด ไม่เก็บชื่อ"),
                voluntary: Bilingual("เข้าร่วมโดยสมัครใจ ถอนตัวได้ทุกเมื่อ"),
                contact: "researcher@example.ac.th")
}

private func ethics() -> EthicsRecord {
    .approved(committee: "คณะกรรมการจริยธรรมการวิจัยในมนุษย์",
              number: "COA-2026-014", date: Date(), declaredBy: "ผู้วิจัย")
}

/// A five-point agreement scale, the shape most of these instruments use.
private func likert() -> ItemKind {
    .likert(levels: [Bilingual("ไม่เห็นด้วยอย่างยิ่ง"), Bilingual("ไม่เห็นด้วย"),
                     Bilingual("เฉย ๆ"), Bilingual("เห็นด้วย"),
                     Bilingual("เห็นด้วยอย่างยิ่ง")])
}

/// A complete, publishable instrument: one RQ, one construct, two scored items
/// measuring it, and one demographic question.
private func wellFormed() -> Instrument {
    let question = ResearchQuestion(text: Bilingual("พยาบาลมีภาวะหมดไฟมากน้อยเพียงใด"))
    let construct = Construct(name: Bilingual("ภาวะหมดไฟ"),
                              definition: "ความอ่อนล้าทางอารมณ์จากงาน",
                              researchQuestionID: question.id)
    let items = [
        Item(prompt: Bilingual("ฉันรู้สึกอ่อนล้าทางอารมณ์จากงาน"), kind: likert(),
             constructID: construct.id, order: 1),
        Item(prompt: Bilingual("ฉันรู้สึกหมดพลังเมื่อคิดถึงเวรถัดไป"), kind: likert(),
             constructID: construct.id, order: 2),
        Item(prompt: Bilingual("อายุ"), kind: .number(minimum: 18, maximum: 70),
             isDemographic: true, order: 3),
    ]
    return Instrument(projectID: project, title: Bilingual("แบบวัดภาวะหมดไฟ"),
                      researchQuestions: [question], constructs: [construct],
                      items: items, consent: consent(), ethics: ethics())
}

/// A panel of three who all agree, on both scales — scoring the items that claim
/// to measure something, which is every item except the demographic ones (§20.4).
private func goodRatings(for instrument: Instrument,
                         panel: [String] = ["ผู้เชี่ยวชาญ ก", "ผู้เชี่ยวชาญ ข", "ผู้เชี่ยวชาญ ค"])
    -> ContentValidity {
    let reviewed = instrument.itemsUnderContentReview
    let ratings = reviewed.flatMap { item in
        panel.map {
            ExpertRating(itemID: item.id, expert: $0, congruence: 1, relevance: 4)
        }
    }
    return ContentValidity.assess(ratings: ratings, itemIDs: reviewed.map(\.id))
}

@Suite("Instrument gate")
struct InstrumentGateTests {

    @Test("an item that measures nothing and says nothing fails publication")
    func untiedItemFailsPublish() throws {
        var instrument = wellFormed()
        // §20.3's rule, and the defect it exists for: a question that looks like
        // data and answers nothing.
        instrument.items.append(Item(prompt: Bilingual("คุณคิดว่าโรงพยาบาลควรปรับอะไร"),
                                     kind: .openText(maximumLength: 500), order: 4))

        let problems = Blueprint.problems(in: instrument)
        #expect(problems.contains { $0.kind == .itemMeasuresNothing })

        let validity = goodRatings(for: instrument)
        let gate = InstrumentGate.evaluate(instrument, validity: validity)
        #expect(!gate.passed)
        #expect(throws: InstrumentError.self) {
            try InstrumentGate.approve(instrument, validity: validity, by: "ผู้วิจัย")
        }

        // Tagging it demographic is the honest fix, and it publishes.
        instrument.items[instrument.items.count - 1].isDemographic = true
        #expect(Blueprint.problems(in: instrument).isEmpty)
    }

    @Test("demographic and tied to a construct is a contradiction, not a shortcut")
    func demographicPlusConstructIsRefused() {
        var instrument = wellFormed()
        instrument.items[0].isDemographic = true
        #expect(Blueprint.problems(in: instrument).contains { $0.kind == .demographicWithConstruct })
    }

    @Test("both halves of the chain are checked, in both directions")
    func chainIsCheckedBothWays() {
        var instrument = wellFormed()
        // A construct nothing measures.
        instrument.constructs.append(Construct(name: Bilingual("ความพึงพอใจ"),
                                               definition: "…",
                                               researchQuestionID: instrument.researchQuestions[0].id))
        #expect(Blueprint.problems(in: instrument).contains { $0.kind == .constructWithoutItems })

        // A research question no construct answers — only visible from this end,
        // which is why it is checked separately (§19.6's 100% rule, same shape).
        var second = wellFormed()
        second.researchQuestions.append(ResearchQuestion(text: Bilingual("ปัจจัยใดทำนายภาวะหมดไฟ")))
        #expect(Blueprint.problems(in: second)
            .contains { $0.kind == .researchQuestionWithoutConstruct })
    }

    @Test("a construct measured only by open text can never have a reliability figure")
    func unscorableConstructIsReported() {
        var instrument = wellFormed()
        instrument.items[0].kind = .openText(maximumLength: nil)
        instrument.items[1].kind = .fileUpload(accepts: ["pdf"])
        #expect(Blueprint.problems(in: instrument).contains { $0.kind == .constructNotScorable })
    }

    @Test("skip logic may only look backwards")
    func skipLogicMustPointBackwards() {
        var instrument = wellFormed()
        let later = instrument.ordered[2].id
        // Item 1 asking about the answer to item 3: the form cannot know it yet.
        instrument.items[0].skip = SkipCondition(itemID: later, test: .equals, value: "1")
        #expect(Blueprint.problems(in: instrument).contains { $0.kind == .skipTargetInvalid })

        instrument.items[0].skip = SkipCondition(itemID: "it_nonexistent",
                                                test: .equals, value: "1")
        #expect(Blueprint.problems(in: instrument).contains { $0.kind == .skipTargetInvalid })
    }

    @Test("no consent page, no publication — checked at the gate, not in the UI")
    func consentIsRequired() throws {
        var instrument = wellFormed()
        let validity = goodRatings(for: instrument)
        instrument.consent = nil
        #expect(InstrumentGate.evaluate(instrument, validity: validity).unmet
            .contains { $0.contains("consent page") })

        // A consent page with an empty field is not consent to anything.
        instrument.consent = ConsentText(purpose: Bilingual("ศึกษา"),
                                         whatIsCollected: Bilingual(""),
                                         voluntary: Bilingual("สมัครใจ"),
                                         contact: "x@example.org")
        #expect(!InstrumentGate.evaluate(instrument, validity: validity).passed)
    }

    @Test("an ethics record is a number or a declaration, and both name a person")
    func ethicsIsRequired() {
        var instrument = wellFormed()
        let validity = goodRatings(for: instrument)
        instrument.ethics = nil
        #expect(!InstrumentGate.evaluate(instrument, validity: validity).passed)

        // The honest version of the box everybody ticks: not human subjects, with
        // a reason and a name.
        instrument.ethics = .notHumanSubjects(reason: "ใช้ข้อมูลทุติยภูมิที่เผยแพร่แล้ว",
                                              declaredBy: "ผู้วิจัย")
        #expect(InstrumentGate.evaluate(instrument, validity: validity).passed)

        // …but not an unsigned one.
        instrument.ethics = .notHumanSubjects(reason: "ไม่เข้าข่าย", declaredBy: "  ")
        #expect(!InstrumentGate.evaluate(instrument, validity: validity).passed)
    }

    @Test("no expert ratings at all is unmet, not passed by default")
    func missingValidityIsUnmet() {
        let instrument = wellFormed()
        let gate = InstrumentGate.evaluate(instrument, validity: nil)
        #expect(!gate.passed)
        #expect(gate.unmet.contains { $0.contains("no expert content-validity assessment") })
    }

    @Test("a complete instrument publishes, and only through the gate")
    func approvalIsTheOnlyProducer() throws {
        let instrument = wellFormed()
        let validity = goodRatings(for: instrument)
        #expect(InstrumentGate.evaluate(instrument, validity: validity).passed)

        let published = try InstrumentGate.approve(instrument, validity: validity,
                                                  by: "ผู้วิจัย")
        #expect(published.instrument.id == instrument.id)
        #expect(published.approvedBy == "ผู้วิจัย")
        // The approval carries the numbers it was granted on, so "it passed" is
        // auditable rather than merely asserted.
        #expect(published.contentValidity.passes)
        #expect(published.id == "\(instrument.id)@1")

        // An approval with nobody attached is the box everybody ticks.
        #expect(throws: InstrumentError.self) {
            try InstrumentGate.approve(instrument, validity: validity, by: "   ")
        }
    }

    @Test("PublishedInstrument has exactly one producer and no public initializer")
    func publishedInstrumentIsUnforgeable() throws {
        // P11.6's Done-when is a line that must not compile, so what is pinned
        // here are the two facts that make that true. If either changes, this
        // fails and whoever changed it has to say why.
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/InstrumentsTests/InstrumentGateTests.swift",
                                  with: "Sources/Instruments/InstrumentGate.swift"),
                                encoding: .utf8)
        let initialisers = source.components(separatedBy: "init(").count - 1
        let publicInitialisers = source.components(separatedBy: "public init(").count - 1
        #expect(initialisers >= 1)
        // Every initializer on `PublishedInstrument` is fileprivate; the public
        // ones in this file belong to the condition/evaluation value types.
        let publishedBlock = source[source.range(of: "public struct PublishedInstrument")!.lowerBound...]
        let publishedInit = publishedBlock[..<publishedBlock.range(of: "public enum InstrumentGate")!.lowerBound]
        #expect(publishedInit.contains("fileprivate init("))
        #expect(!publishedInit.contains("public init("))
        _ = publicInitialisers

        // And one producer, which is the gate.
        #expect(source.components(separatedBy: "PublishedInstrument(instrument:").count - 1 == 1)
    }

    @Test("editing a published instrument makes a new version, never an edit")
    func versionsAreImmutable() throws {
        let instrument = wellFormed()
        let published = try InstrumentGate.approve(instrument,
                                                  validity: goodRatings(for: instrument),
                                                  by: "ผู้วิจัย")
        var next = published.instrument.nextVersion()
        next.items.append(Item(prompt: Bilingual("ข้อใหม่"), kind: likert(),
                               isDemographic: true, order: 9))

        #expect(next.version == 2)
        #expect(next.id != published.instrument.id)
        // The ancestry is recorded rather than described in a comment: without it
        // "which form did these answers come from" has no answer once two versions
        // are in the database.
        #expect(next.supersedes == published.instrument.id)
        // §20.6 invariant 1: the published version is untouched, so answers
        // already collected still describe the form they were collected with.
        #expect(published.instrument.items.count == 3)
    }

    @Test("one expert is not a panel, and the thresholds say so")
    func oneExpertIsNotAPanel() {
        let instrument = wellFormed()
        // The defect this exists for was live in the app: a single rater clicking
        // +1 down the list turned every condition green. I-CVI from one person can
        // only be 0 or 1, so it clears 0.78 by construction (risk R12).
        let alone = goodRatings(for: instrument, panel: ["ผู้เชี่ยวชาญ ก"])
        #expect(!alone.hasPanel)
        #expect(!alone.passes)
        #expect(!InstrumentGate.evaluate(instrument, validity: alone).passed)

        let two = goodRatings(for: instrument, panel: ["ก", "ข"])
        #expect(!two.passes)

        #expect(goodRatings(for: instrument).passes)
    }

    @Test("a demographic question is not scored for congruence with anything")
    func demographicItemsAreNotUnderContentReview() throws {
        let instrument = wellFormed()
        #expect(instrument.items.count == 3)
        #expect(instrument.itemsUnderContentReview.count == 2)
        #expect(!instrument.itemsUnderContentReview.contains { $0.isDemographic })

        // And the gate passes on ratings that cover only those two: demanding an
        // IOC for "อายุ" would have made this instrument unpublishable forever.
        #expect(InstrumentGate.evaluate(instrument, validity: goodRatings(for: instrument)).passed)
    }

    @Test("an assessment of some other item set is not this instrument's evidence")
    func validityMustCoverTheInstrument() {
        let instrument = wellFormed()
        // Half the panel's work, handed in as if it were all of it. `validity`
        // arrives as an argument, so without this check the gate would take the
        // caller's word for what was assessed.
        let partial = ContentValidity.assess(
            ratings: instrument.itemsUnderContentReview.prefix(1).flatMap { item in
                ["ก", "ข", "ค"].map {
                    ExpertRating(itemID: item.id, expert: $0, congruence: 1, relevance: 4)
                }
            },
            itemIDs: instrument.itemsUnderContentReview.prefix(1).map(\.id))
        #expect(partial.passes)          // it passes on its own terms…
        let gate = InstrumentGate.evaluate(instrument, validity: partial)
        #expect(!gate.passed)            // …and is still not evidence about this form
        #expect(gate.conditions.last?.detail?.contains("does not match this instrument's items") == true)
    }

    @Test("passing the gate leaves a record with a name and a date on it")
    func approvalIsRecorded() throws {
        let instrument = wellFormed()
        let published = try InstrumentGate.approve(instrument,
                                                   validity: goodRatings(for: instrument),
                                                   by: "ผู้วิจัย")
        let record = published.approval
        #expect(record.instrumentID == instrument.id)
        #expect(record.version == 1)
        #expect(record.approvedBy == "ผู้วิจัย")
        // The figures as they read at the moment of approval, not as they read
        // now: experts can still be added afterwards.
        #expect(record.validity == published.contentValidity.summary)
        #expect(record.id == published.id)
    }
}
