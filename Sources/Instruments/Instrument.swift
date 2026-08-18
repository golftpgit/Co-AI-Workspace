import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// M15 Instruments — the thing data is collected with (ARCHITECTURE §20.3, P11.2).
//
// This module designs instruments and **touches no network at all**. Serving a
// form is M16's job (§20.7), and the separation is not tidiness: an instrument's
// life cycle is much longer than a request's — draft, content validity, publish,
// collect, close a wave — and the only moment the two meet is the one type this
// file will not let anybody forge.
//
// The rule that shapes everything here is §20.3's: **an item that measures
// nothing must say so.** Every question is either tied to a construct (and
// through it to a research question) or tagged `demographic`. An untied,
// untagged question is the most common defect in a real questionnaire — it looks
// like data and answers nothing — so it fails publication rather than producing
// a column nobody can analyse.
//
// Bilingual from the start, not as a later feature: the instruments this system
// is for get answered in Thai and written up in English, and a translation added
// after content validity has been assessed is a different instrument.
// ─────────────────────────────────────────────────────────────

/// Text in both languages. Thai is required, English optional — the reverse of
/// what a library would default to, and correct here: a form with no Thai cannot
/// be answered by the people it is for, while a missing translation only makes
/// the manuscript harder to write.
public struct Bilingual: Sendable, Codable, Equatable {
    public var thai: String
    public var english: String?

    public init(_ thai: String, english: String? = nil) {
        self.thai = thai
        self.english = english
    }

    public var isEmpty: Bool { thai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func text(_ language: Language) -> String {
        switch language {
        case .thai: thai
        case .english: english ?? thai
        }
    }

    public enum Language: String, Sendable, Codable, CaseIterable {
        case thai, english
    }
}

/// The question types §20.3 lists. A closed enum: a form runtime that has to
/// render an unknown type is a runtime that renders nothing, and adding a type
/// should fail to compile until every renderer has handled it.
public enum ItemKind: Sendable, Codable, Equatable {
    /// n-point scale. `levels` carries the labels, so a 5-point agreement scale
    /// and a 5-point frequency scale are different instruments rather than the
    /// same number with different prose in the paper.
    case likert(levels: [Bilingual])
    case single(options: [Bilingual])
    case multiple(options: [Bilingual], maximum: Int?)
    case openText(maximumLength: Int?)
    case number(minimum: Double?, maximum: Double?)
    case date
    /// Rows share one set of columns — the shape that turns twenty Likert items
    /// into one screen.
    case matrix(rows: [Bilingual], columns: [Bilingual])
    case ranking(options: [Bilingual])
    case fileUpload(accepts: [String])

    public var label: String {
        switch self {
        case .likert(let levels): localised("\(levels.count)-point Likert", "A question type. Placeholder: how many points the scale has.")
        case .single: localised("single choice", "A question type.")
        case .multiple: localised("multiple choice", "A question type.")
        case .openText: localised("open text", "A question type.")
        case .number: localised("number", "A question type.")
        case .date: localised("date", "A question type.")
        case .matrix(let rows, let columns): "matrix \(rows.count)×\(columns.count)"
        case .ranking: localised("ranking", "A question type.")
        case .fileUpload: localised("file upload", "A question type.")
        }
    }

    /// Whether an answer to this can be scored into a scale. Open text and file
    /// uploads cannot, which is why a construct made only of those is a defect
    /// the blueprint reports rather than a reliability figure of zero.
    public var isScorable: Bool {
        switch self {
        case .likert, .single, .number, .ranking, .matrix: true
        case .multiple, .openText, .date, .fileUpload: false
        }
    }
}

/// Show this item only when an earlier answer says so (§20.3's skip logic).
///
/// Deliberately one condition against one earlier item rather than an expression
/// language: every real questionnaire's branching is "if they said no, skip the
/// next four", and an expression language here would be a second thing to
/// validate, translate and render.
public struct SkipCondition: Sendable, Codable, Equatable {
    public enum Test: String, Sendable, Codable {
        case equals, notEquals, atLeast, atMost
    }

    /// The item whose answer decides. Must come earlier in the form — the
    /// blueprint refuses a condition that points forward, because a form cannot
    /// ask about an answer it has not collected.
    public let itemID: String
    public let test: Test
    /// Compared as a string for choices, as a number for `atLeast`/`atMost`.
    public let value: String

    public init(itemID: String, test: Test, value: String) {
        self.itemID = itemID
        self.test = test
        self.value = value
    }
}

public struct Item: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var prompt: Bilingual
    public var help: Bilingual?
    public var kind: ItemKind
    public var required: Bool
    /// Which construct this measures (§20.3). `nil` is only allowed together
    /// with `isDemographic`.
    public var constructID: String?
    /// "This question is about who the respondent is, not about the thing being
    /// measured." The escape hatch the blueprint rule needs to be usable — and
    /// it has to be *said*, because saying it is the whole check.
    public var isDemographic: Bool
    public var skip: SkipCondition?
    public var order: Int

    public init(id: String = OpaqueID.make(OpaqueID.item),
                prompt: Bilingual,
                help: Bilingual? = nil,
                kind: ItemKind,
                required: Bool = true,
                constructID: String? = nil,
                isDemographic: Bool = false,
                skip: SkipCondition? = nil,
                order: Int = 0) {
        self.id = id
        self.prompt = prompt
        self.help = help
        self.kind = kind
        self.required = required
        self.constructID = constructID
        self.isDemographic = isDemographic
        self.skip = skip
        self.order = order
    }
}

/// What the instrument is trying to measure, and which research question it
/// serves. The middle of §20.3's item ↔ construct ↔ RQ chain.
public struct Construct: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var name: Bilingual
    public var definition: String
    /// The research question this construct exists to answer. Required: a
    /// construct nothing asks about is a scale nobody will report.
    public var researchQuestionID: String

    public init(id: String = OpaqueID.make(OpaqueID.construct),
                name: Bilingual,
                definition: String,
                researchQuestionID: String) {
        self.id = id
        self.name = name
        self.definition = definition
        self.researchQuestionID = researchQuestionID
    }
}

public struct ResearchQuestion: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var text: Bilingual
    public init(id: String = OpaqueID.make(OpaqueID.researchQuestion),
                text: Bilingual) {
        self.id = id
        self.text = text
    }
}

/// The consent page §20.5 requires before the first question. Not optional and
/// not a checkbox with no text: the gate reads the words.
public struct ConsentText: Sendable, Codable, Equatable {
    public var purpose: Bilingual
    public var whatIsCollected: Bilingual
    public var voluntary: Bilingual
    public var contact: String

    public init(purpose: Bilingual, whatIsCollected: Bilingual,
                voluntary: Bilingual, contact: String) {
        self.purpose = purpose
        self.whatIsCollected = whatIsCollected
        self.voluntary = voluntary
        self.contact = contact
    }

    /// Every field filled in. A consent page with an empty "what is collected"
    /// is not consent to anything.
    public var isComplete: Bool {
        ![purpose, whatIsCollected, voluntary].contains(where: \.isEmpty)
            && !contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// §20.5's ethics record: an approval number, or an explicit declaration that
/// this is not human-subjects research — with a person's name against it either
/// way. There is no third state, and no default.
public enum EthicsRecord: Sendable, Codable, Equatable {
    case approved(committee: String, number: String, date: Date, declaredBy: String)
    /// "This does not require review, and I am saying so." The honest version of
    /// the box everybody ticks.
    case notHumanSubjects(reason: String, declaredBy: String)

    public var isComplete: Bool {
        switch self {
        case .approved(let committee, let number, _, let by):
            ![committee, number, by].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .notHumanSubjects(let reason, let by):
            ![reason, by].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    public var summary: String {
        switch self {
        case .approved(let committee, let number, _, let by):
            localised("approved by \(committee), reference \(number) · recorded by \(by)", "An ethics approval. Placeholders: the committee, its reference number and who recorded it.")
        case .notHumanSubjects(let reason, let by):
            localised("declared not to be human-subjects research: \(reason) · by \(by)", "An ethics exemption. Placeholders: the stated reason and who recorded it.")
        }
    }
}

/// An instrument being designed. One version; editing a published one produces
/// the next version rather than changing this (§20.6 invariant 1).
public struct Instrument: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    /// 1, 2, 3… Immutable per version, like a baseline (§19.11).
    public let version: Int
    /// The version this one was made from, if any. A version chain that only
    /// exists in a comment is not a chain: without this, "which form did these
    /// answers come from" has no answer once two versions are in the database.
    public let supersedes: String?
    public var title: Bilingual
    public var researchQuestions: [ResearchQuestion]
    public var constructs: [Construct]
    public var items: [Item]
    public var consent: ConsentText?
    public var ethics: EthicsRecord?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = OpaqueID.make(OpaqueID.instrument),
                projectID: ProjectID,
                version: Int = 1,
                supersedes: String? = nil,
                title: Bilingual,
                researchQuestions: [ResearchQuestion] = [],
                constructs: [Construct] = [],
                items: [Item] = [],
                consent: ConsentText? = nil,
                ethics: EthicsRecord? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.version = version
        self.supersedes = supersedes
        self.title = title
        self.researchQuestions = researchQuestions
        self.constructs = constructs
        self.items = items
        self.consent = consent
        self.ethics = ethics
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var ordered: [Item] { items.sorted { $0.order < $1.order } }

    public func items(measuring constructID: String) -> [Item] {
        ordered.filter { $0.constructID == constructID }
    }

    /// The items a panel of experts is asked to score (§20.4).
    ///
    /// Demographic items are not among them, and that is method rather than
    /// convenience: IOC is the congruence between an item and the thing it claims
    /// to measure, and a demographic item claims nothing. Asking a panel to score
    /// "years of experience" for congruence either blocks the instrument forever
    /// or teaches everybody to type a number that means nothing.
    public var itemsUnderContentReview: [Item] {
        ordered.filter { !$0.isDemographic }
    }

    /// The next version of this instrument, for editing after publication.
    ///
    /// A new id as well as a new number: two rows that share an id are two
    /// versions of one thing only if something enforces it, and nothing here
    /// can — so they are separate objects that name their ancestor through
    /// `supersedes`.
    public func nextVersion() -> Instrument {
        Instrument(projectID: projectID,
                   version: version + 1,
                   supersedes: id,
                   title: title,
                   researchQuestions: researchQuestions,
                   constructs: constructs,
                   items: items,
                   consent: consent,
                   ethics: ethics)
    }
}

/// Where instruments are kept. Same split as the rest of the system: rules here,
/// rows in Persistence.
public protocol InstrumentPersisting: Sendable {
    func save(_ instrument: Instrument) async throws
    func all(project: ProjectID) async throws -> [Instrument]
}
