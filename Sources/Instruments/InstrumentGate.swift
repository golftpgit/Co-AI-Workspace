import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The gate between designing an instrument and collecting with it
// (ARCHITECTURE §20.1, §20.5, §20.6, P11.4/P11.6).
//
// §20.1 says this is the strongest gate in a research project, and why: you
// cannot fix an instrument after collecting with it. Data gathered with a
// questionnaire that never passed content validity is not weak evidence, it is a
// wasted round of fieldwork and somebody's time.
//
// So the gate is not a validation function that returns advice. It is the only
// producer of `PublishedInstrument`, and `PublishedInstrument` has no public
// initializer — which makes "publish something unapproved" not a rule anybody has
// to remember but a sentence that does not compile. M16 accepts nothing else, so
// there is no representation of an unapproved instrument that a server could
// serve (§20.6 invariant 2).
// ─────────────────────────────────────────────────────────────

/// What is wrong with a blueprint, in the words the screen shows.
public struct BlueprintProblem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// §20.3's rule: measures nothing and does not say it is demographic.
        case itemMeasuresNothing
        /// Tagged demographic *and* tied to a construct — one of the two is a
        /// mistake, and guessing which would be worse than asking.
        case demographicWithConstruct
        case constructWithoutItems
        case constructWithoutResearchQuestion
        case researchQuestionWithoutConstruct
        /// Skip logic pointing at an item that does not exist or comes later.
        case skipTargetInvalid
        /// A construct measured only by things that cannot be scored — no
        /// reliability figure can ever be computed for it.
        case constructNotScorable
        case noItems
    }

    public let kind: Kind
    public let subject: String
    public var id: String { "\(kind.rawValue):\(subject)" }

    public var text: String {
        switch kind {
        case .itemMeasuresNothing:
            "“\(subject)” ไม่ได้ผูกกับ construct และไม่ได้ติดป้ายว่าเป็นข้อมูลพื้นฐาน — "
                + "ข้อที่ไม่วัดอะไรเลยคือคอลัมน์ที่วิเคราะห์ไม่ได้ (§20.3)"
        case .demographicWithConstruct:
            "“\(subject)” ติดป้ายข้อมูลพื้นฐานแต่ผูกกับ construct ด้วย — เลือกอย่างใดอย่างหนึ่ง"
        case .constructWithoutItems:
            "construct “\(subject)” ยังไม่มีข้อคำถามวัดมันเลย"
        case .constructWithoutResearchQuestion:
            "construct “\(subject)” ไม่ได้ผูกกับคำถามวิจัยข้อใด"
        case .researchQuestionWithoutConstruct:
            "คำถามวิจัย “\(subject)” ไม่มี construct ใดตอบมัน"
        case .skipTargetInvalid:
            "เงื่อนไขข้ามของ “\(subject)” ชี้ไปที่ข้อที่ไม่มีอยู่ หรืออยู่หลังตัวมันเอง"
        case .constructNotScorable:
            "construct “\(subject)” วัดด้วยข้อที่ให้คะแนนไม่ได้ทั้งหมด — คำนวณความเที่ยงไม่ได้เลย"
        case .noItems:
            "แบบสอบถามยังไม่มีข้อคำถาม"
        }
    }
}

public enum Blueprint {
    /// Everything wrong with the item ↔ construct ↔ RQ chain (§20.3).
    ///
    /// Reported as a list rather than a first failure, because a person fixing a
    /// questionnaire wants the whole list once — the same reason `WBSProblem`
    /// exists in the plan.
    public static func problems(in instrument: Instrument) -> [BlueprintProblem] {
        var problems: [BlueprintProblem] = []
        let ordered = instrument.ordered
        if ordered.isEmpty {
            problems.append(BlueprintProblem(kind: .noItems, subject: instrument.title.thai))
        }

        let constructIDs = Set(instrument.constructs.map(\.id))
        let questionIDs = Set(instrument.researchQuestions.map(\.id))
        var position: [String: Int] = [:]
        for (index, item) in ordered.enumerated() { position[item.id] = index }

        for (index, item) in ordered.enumerated() {
            let named = item.prompt.thai.isEmpty ? item.id : item.prompt.thai
            let tied = item.constructID.map(constructIDs.contains) == true
            if !tied && !item.isDemographic {
                problems.append(BlueprintProblem(kind: .itemMeasuresNothing, subject: named))
            }
            if tied && item.isDemographic {
                problems.append(BlueprintProblem(kind: .demographicWithConstruct, subject: named))
            }
            if let skip = item.skip {
                // Forward references and dangling ones are the same defect from
                // the respondent's side: the form cannot decide whether to show
                // the question.
                let target = position[skip.itemID]
                if target == nil || target! >= index {
                    problems.append(BlueprintProblem(kind: .skipTargetInvalid, subject: named))
                }
            }
        }

        for construct in instrument.constructs {
            let measuring = instrument.items(measuring: construct.id)
            if measuring.isEmpty {
                problems.append(BlueprintProblem(kind: .constructWithoutItems,
                                                 subject: construct.name.thai))
            } else if !measuring.contains(where: { $0.kind.isScorable }) {
                problems.append(BlueprintProblem(kind: .constructNotScorable,
                                                 subject: construct.name.thai))
            }
            if !questionIDs.contains(construct.researchQuestionID) {
                problems.append(BlueprintProblem(kind: .constructWithoutResearchQuestion,
                                                 subject: construct.name.thai))
            }
        }

        // The other half of the chain, and the half people skip: a research
        // question with nothing measuring it is a question the instrument cannot
        // answer, which is only visible from this direction.
        let answered = Set(instrument.constructs.map(\.researchQuestionID))
        for question in instrument.researchQuestions where !answered.contains(question.id) {
            problems.append(BlueprintProblem(kind: .researchQuestionWithoutConstruct,
                                             subject: question.text.thai))
        }
        return problems
    }
}

/// One condition of the instrument gate, and whether it holds. Same shape as the
/// stage gates in §19.4, on purpose: a gate is a gate.
public struct InstrumentCondition: Sendable, Equatable {
    public let text: String
    public let satisfied: Bool
    public let detail: String?

    public init(text: String, satisfied: Bool, detail: String? = nil) {
        self.text = text
        self.satisfied = satisfied
        self.detail = detail
    }
}

public struct InstrumentEvaluation: Sendable, Equatable {
    public let conditions: [InstrumentCondition]
    public var passed: Bool { conditions.allSatisfy(\.satisfied) }
    public var unmet: [String] { conditions.filter { !$0.satisfied }.map(\.text) }
}

public enum InstrumentError: Error, CustomStringConvertible, Equatable {
    case notReady(unmet: [String])

    public var description: String {
        switch self {
        case .notReady(let unmet):
            "ยังเผยแพร่เครื่องมือนี้ไม่ได้ — ค้าง: " + unmet.joined(separator: " · ")
        }
    }
}

/// That a version passed the gate: who approved it, when, and the figures they
/// were looking at.
///
/// A row of its own rather than a flag on the instrument, because an approval is
/// an event and §20.5's whole point is that a person took responsibility at a
/// moment. `PublishedInstrument` is still the only thing a server will accept and
/// the gate is still its only producer — this is the *record* that the gate was
/// passed, kept so "it passed" can be read back tomorrow instead of trusted.
/// Without it the approval lived in one screen's memory: leave the tab and an
/// approved instrument looked exactly like one that had never been reviewed.
public struct InstrumentApproval: Sendable, Codable, Equatable, Identifiable {
    public let instrumentID: String
    public let version: Int
    public let approvedBy: String
    public let approvedAt: Date
    /// The content-validity summary as it read at the moment of approval. Kept
    /// verbatim: recomputing it later would answer a different question, because
    /// experts can still be added afterwards.
    public let validity: String

    public var id: String { "\(instrumentID)@\(version)" }

    public init(instrumentID: String, version: Int, approvedBy: String,
                approvedAt: Date, validity: String) {
        self.instrumentID = instrumentID
        self.version = version
        self.approvedBy = approvedBy
        self.approvedAt = approvedAt
        self.validity = validity
    }

    public var summary: String {
        "ผ่านประตูแล้วโดย \(approvedBy) · "
            + approvedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// An instrument that has passed the gate.
///
/// **There is no public initializer, and that is the design.** M16 serves this
/// type and nothing else, so an instrument that has not passed content validity,
/// has no consent page or has no ethics record has no representation the server
/// could accept — §20.6's second invariant, expressed as a type rather than as a
/// check somebody has to call.
public struct PublishedInstrument: Sendable, Equatable, Identifiable {
    public let instrument: Instrument
    /// The words the person who approved it saw, kept so "it passed" can be
    /// audited later rather than trusted.
    public let approvedBy: String
    public let approvedAt: Date
    public let contentValidity: ContentValidity
    public var id: String { "\(instrument.id)@\(instrument.version)" }

    fileprivate init(instrument: Instrument, approvedBy: String, approvedAt: Date,
                     contentValidity: ContentValidity) {
        self.instrument = instrument
        self.approvedBy = approvedBy
        self.approvedAt = approvedAt
        self.contentValidity = contentValidity
    }

    /// The durable record of this approval, for whoever asks next month.
    public var approval: InstrumentApproval {
        InstrumentApproval(instrumentID: instrument.id, version: instrument.version,
                           approvedBy: approvedBy, approvedAt: approvedAt,
                           validity: contentValidity.summary)
    }
}

public enum InstrumentGate {

    /// Everything §20.1 step 5 and §20.5 require before a form may be opened.
    public static func evaluate(_ instrument: Instrument,
                                validity: ContentValidity?) -> InstrumentEvaluation {
        let problems = Blueprint.problems(in: instrument)
        var conditions: [InstrumentCondition] = [
            InstrumentCondition(text: "ผังข้อคำถามครบ (ทุกข้อผูก construct หรือติดป้ายข้อมูลพื้นฐาน)",
                                satisfied: problems.isEmpty,
                                detail: problems.isEmpty
                                    ? nil
                                    : problems.map(\.text).joined(separator: " · ")),
            // §20.5 — checked at the gate, not in the UI, because a UI check is
            // a check that a second entry point skips.
            InstrumentCondition(text: "มีหน้าความยินยอมครบทุกช่อง",
                                satisfied: instrument.consent?.isComplete == true),
            InstrumentCondition(text: "มีบันทึกจริยธรรม (เลขรับรอง หรือคำประกาศว่าไม่เข้าข่าย) พร้อมชื่อผู้แจ้ง",
                                satisfied: instrument.ethics?.isComplete == true,
                                detail: instrument.ethics?.summary),
        ]

        // Content validity last, because it is the condition that needs other
        // people: experts have to score the items before there is anything to
        // check (§20.4).
        if let validity {
            // The assessment has to be *of this instrument*. A `ContentValidity`
            // arrives as an argument, so nothing stops a caller from computing one
            // over a friendlier subset of the items and handing it in; checking the
            // item set here is what makes that impossible rather than discouraged.
            let reviewed = Set(instrument.itemsUnderContentReview.map(\.id))
            let assessed = Set(validity.items.map(\.itemID))
            let coversTheInstrument = reviewed == assessed
            conditions.append(InstrumentCondition(
                text: "ความตรงเชิงเนื้อหาผ่านเกณฑ์ (IOC ≥ 0.5 ทุกข้อ · I-CVI ≥ 0.78 · S-CVI/Ave ≥ 0.90)",
                satisfied: validity.passes && coversTheInstrument,
                detail: coversTheInstrument
                    ? validity.summary
                    : "ผลประเมินที่ส่งมาไม่ตรงกับชุดข้อคำถามของเครื่องมือนี้ "
                        + "(ประเมิน \(assessed.count) ข้อ จากที่ต้องประเมิน \(reviewed.count) ข้อ)"))
        } else {
            conditions.append(InstrumentCondition(
                text: "ยังไม่มีผลประเมินความตรงเชิงเนื้อหาจากผู้เชี่ยวชาญ",
                satisfied: false))
        }
        return InstrumentEvaluation(conditions: conditions)
    }

    /// The only way a `PublishedInstrument` comes into existence.
    ///
    /// Takes the approver's name because §20.5's ethics record is about a person
    /// taking responsibility, and an approval with nobody attached is the box
    /// everybody ticks.
    public static func approve(_ instrument: Instrument,
                               validity: ContentValidity?,
                               by person: String,
                               at date: Date = Date()) throws -> PublishedInstrument {
        var unmet = evaluate(instrument, validity: validity).unmet
        if person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            unmet.append("ต้องมีชื่อผู้อนุมัติ")
        }
        guard unmet.isEmpty, let validity else {
            throw InstrumentError.notReady(unmet: unmet)
        }
        return PublishedInstrument(instrument: instrument, approvedBy: person,
                                   approvedAt: date, contentValidity: validity)
    }
}
