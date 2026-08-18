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
            localised("“\(subject)” is tied to no construct and is not marked as background data — ", "A gate failure. Placeholder: the item.")
                + localised("an item that measures nothing is a column nothing can be done with (§20.3)", "Ends a gate failure.")
        case .demographicWithConstruct:
            localised("“\(subject)” is marked as background data and tied to a construct — it must be one or the other", "A gate failure. Placeholder: the item.")
        case .constructWithoutItems:
            localised("no item measures the construct “\(subject)”", "A gate failure. Placeholder: the construct.")
        case .constructWithoutResearchQuestion:
            localised("the construct “\(subject)” is tied to no research question", "A gate failure. Placeholder: the construct.")
        case .researchQuestionWithoutConstruct:
            localised("no construct answers the research question “\(subject)”", "A gate failure. Placeholder: the research question.")
        case .skipTargetInvalid:
            localised("the skip condition on “\(subject)” points at an item that does not exist, or at one before itself", "A gate failure. Placeholder: the item.")
        case .constructNotScorable:
            localised("every item measuring the construct “\(subject)” is unscorable — its reliability cannot be computed at all", "A gate failure. Placeholder: the construct.")
        case .noItems:
            localised("the questionnaire has no items yet", "A gate failure.")
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
            localised("this instrument cannot be published yet — outstanding: ", "Introduces the unmet gate conditions.") + unmet.joined(separator: " · ")
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
        localised("through the gate, approved by \(approvedBy) · ", "Says who approved an instrument. Placeholder: the approver.")
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
            InstrumentCondition(text: localised("the item map is complete (every item is tied to a construct or marked as background data)", "A gate condition."),
                                satisfied: problems.isEmpty,
                                detail: problems.isEmpty
                                    ? nil
                                    : problems.map(\.text).joined(separator: " · ")),
            // §20.5 — checked at the gate, not in the UI, because a UI check is
            // a check that a second entry point skips.
            InstrumentCondition(text: localised("the consent page is complete", "A gate condition."),
                                satisfied: instrument.consent?.isComplete == true),
            InstrumentCondition(text: localised("an ethics record exists (an approval number or a declaration of exemption) naming who recorded it", "A gate condition."),
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
                text: localised("content validity meets the thresholds (IOC ≥ 0.5 on every item · I-CVI ≥ 0.78 · S-CVI/Ave ≥ 0.90)", "A gate condition."),
                satisfied: validity.passes && coversTheInstrument,
                detail: coversTheInstrument
                    ? validity.summary
                    : localised("the assessment submitted does not match this instrument's items ", "Why a gate condition is unmet.")
                        + localised("(\(assessed.count) items assessed of the \(reviewed.count) that need it)", "Ends the mismatch reason. Placeholders: the assessed and required counts.")))
        } else {
            conditions.append(InstrumentCondition(
                text: localised("no expert content-validity assessment has been made yet", "Why a gate condition is unmet."),
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
            unmet.append(localised("an approver has to be named", "Why a gate condition is unmet."))
        }
        guard unmet.isEmpty, let validity else {
            throw InstrumentError.notReady(unmet: unmet)
        }
        return PublishedInstrument(instrument: instrument, approvedBy: person,
                                   approvedAt: date, contentValidity: validity)
    }
}
