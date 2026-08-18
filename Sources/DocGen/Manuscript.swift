import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The five-chapter manuscript (ARCHITECTURE §20.8, P11.9).
//
// P11.9's Done-when is not "produce a document Word can open" — that part is
// P7.7's and already works. It is the second clause: **the statistics in
// chapter 4 point back to a cell in a notebook that actually ran, rather than
// being numbers somebody typed in.**
//
// That is a promise about the commonest way a thesis becomes untrue. Nobody
// falsifies a result; what happens is that a number is copied into the draft,
// the analysis is re-run three weeks later after a data correction, and the
// draft still says 3.42. The paper is then wrong in a way no reviewer can see
// and the author cannot remember.
//
// So a reported number is not text here. It is a `ResultReference` — notebook,
// cell, column, row — and a manuscript is produced by *resolving* those against
// recorded runs. Three things stop a stale number reaching the page:
//
//  • A reference to a cell that never ran does not resolve, and the document is
//    refused rather than rendered with a gap.
//  • A run whose source no longer matches the cell does not resolve either. The
//    number came from a different query, which is exactly the case above.
//  • `BoundResult` has no public initialiser and one producer, so a number in a
//    manuscript cannot have been written down. Same shape as
//    `PublishedInstrument`, `DiscardableInstrument` and `TranscriptQuotation`.
//
// The refusal is the feature. A document that renders with "[ไม่พบผล]" where a
// mean should be is a document somebody sends anyway.
// ─────────────────────────────────────────────────────────────

/// Where a number in the manuscript comes from.
public struct ResultReference: Sendable, Codable, Equatable, Identifiable {
    public let notebookID: String
    public let cellID: String
    /// Which column of the cell's answer, by name — a position would silently
    /// point at a different column the day somebody adds one to the SELECT.
    public let column: String
    /// Which row, from 0. Most reported statistics are a single-row answer.
    public let row: Int
    /// The placeholder this fills in a sentence, and what it is called when the
    /// binding fails: "ค่าเฉลี่ยอายุ" reads better in an error than "column 2".
    public let label: String

    public var id: String { "\(notebookID)|\(cellID)|\(column)|\(row)" }

    public init(notebookID: String, cellID: String, column: String, row: Int = 0,
                label: String) {
        self.notebookID = notebookID
        self.cellID = cellID
        self.column = column
        self.row = row
        self.label = label
    }
}

extension CellRun {
    /// One cell of the answer, by column name and row.
    ///
    /// Lives here rather than on the type in M2 because it is the question
    /// *this* module asks — M2 holds the record, and the meaning of "row 0 of
    /// mean_age" belongs where the citation is built.
    func value(column: String, row: Int) -> String? {
        guard let index = columns.firstIndex(of: column),
              row >= 0, row < rows.count,
              index < rows[row].count else { return nil }
        return rows[row][index]
    }
}

public enum ResultBindingFailure: Error, Sendable, Equatable, Identifiable {
    case cellNeverRan(ResultReference)
    case sourceChanged(ResultReference, ranAt: Date)
    case noSuchColumn(ResultReference, available: [String])
    case noSuchRow(ResultReference, rows: Int)
    case valueIsNull(ResultReference)

    public var id: String { reference.id }

    public var reference: ResultReference {
        switch self {
        case .cellNeverRan(let reference), .sourceChanged(let reference, _),
             .noSuchColumn(let reference, _), .noSuchRow(let reference, _),
             .valueIsNull(let reference):
            reference
        }
    }

    public var text: String {
        switch self {
        case .cellNeverRan(let reference):
            localised("“\(reference.label)” points at a cell that has never been run — a number in the manuscript has to come from a real run", "Why a manuscript cannot be built. Placeholder: the reference's name.")
        case .sourceChanged(let reference, let ranAt):
            localised("“\(reference.label)” comes from a run on ", "A stale manuscript reference. Placeholder: the reference's name.")
                + "\(ranAt.formatted(date: .abbreviated, time: .shortened)) "
                + localised("but the cell has been edited since — this number answers a different question than the cell asks now", "Ends the stale-reference warning.")
        case .noSuchColumn(let reference, let available):
            localised("“\(reference.label)” cites column \(reference.column), which is not in the result ", "A manuscript reference to a missing column. Placeholders: the reference's name and the column.")
                + {
                    let columns = available.joined(separator: ", ")
                    return localised("(available: \(columns))",
                                     "Lists the columns a result does have. Placeholder: the column names.")
                }()
        case .noSuchRow(let reference, let rows):
            localised("“\(reference.label)” cites row \(reference.row), but the result has \(rows)", "A manuscript reference to a missing row. Placeholders: the reference's name, the row and the row count.")
        case .valueIsNull(let reference):
            localised("“\(reference.label)” came back empty (NULL) from the run — that is not a number to put in a manuscript", "A manuscript reference that resolved to null. Placeholder: the reference's name.")
        }
    }
}

/// A number that was resolved out of a recorded run.
///
/// No public initialiser: `bind(_:to:currentSources:)` is the only producer, so
/// a number in a manuscript cannot be one somebody typed.
public struct BoundResult: Sendable, Equatable, Identifiable {
    public let reference: ResultReference
    public let value: String
    public let ranAt: Date
    /// The statement that produced it, kept so the manuscript can say where the
    /// number came from without anybody opening the notebook.
    public let source: String

    public var id: String { reference.id }

    fileprivate init(reference: ResultReference, value: String, ranAt: Date, source: String) {
        self.reference = reference
        self.value = value
        self.ranAt = ranAt
        self.source = source
    }

    /// The only producer.
    ///
    /// `currentSources` maps cell id → the source that cell holds *now*. A run
    /// recorded against different text is refused: it answered a different
    /// question, and the number it produced is about that other question.
    public static func bind(_ reference: ResultReference, to runs: [CellRun],
                            currentSources: [String: String] = [:])
        -> Result<BoundResult, ResultBindingFailure> {
        guard let run = runs.first(where: {
            $0.notebookID == reference.notebookID && $0.cellID == reference.cellID
        }) else {
            return .failure(.cellNeverRan(reference))
        }
        if let now = currentSources[reference.cellID], now != run.source {
            return .failure(.sourceChanged(reference, ranAt: run.ranAt))
        }
        guard run.columns.contains(reference.column) else {
            return .failure(.noSuchColumn(reference, available: run.columns))
        }
        guard reference.row >= 0, reference.row < run.rows.count else {
            return .failure(.noSuchRow(reference, rows: run.rows.count))
        }
        guard let value = run.value(column: reference.column, row: reference.row) else {
            return .failure(.valueIsNull(reference))
        }
        return .success(BoundResult(reference: reference, value: value,
                                    ranAt: run.ranAt, source: run.source))
    }
}

/// A sentence whose numbers come from runs.
///
/// The text carries `{label}` placeholders rather than digits, so the sentence
/// and the number are stored apart and joined only at render time — which is
/// what makes re-running the analysis change the manuscript instead of leaving
/// it behind.
public struct ReportedSentence: Sendable, Codable, Equatable {
    public let text: String
    public let references: [ResultReference]

    public init(_ text: String, references: [ResultReference]) {
        self.text = text
        self.references = references
    }

    /// Placeholders in the text that no reference fills. A sentence that says
    /// `{ค่าเฉลี่ย}` and carries no reference for it would otherwise render the
    /// braces into the manuscript.
    public var unfilledPlaceholders: [String] {
        let named = Set(references.map(\.label))
        return Self.placeholders(in: text).filter { !named.contains($0) }
    }

    static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        var current: String?
        for character in text {
            if character == "{" { current = "" }
            else if character == "}" {
                if let name = current, !name.isEmpty { found.append(name) }
                current = nil
            } else if current != nil {
                current?.append(character)
            }
        }
        return found
    }

    /// The sentence with its numbers in it.
    func filled(with bound: [BoundResult]) -> String {
        var text = self.text
        for result in bound {
            text = text.replacingOccurrences(of: "{\(result.reference.label)}",
                                             with: result.value)
        }
        return text
    }
}

// ─────────────────────────────────────────────────────────────
// The five chapters
// ─────────────────────────────────────────────────────────────

/// The chapters a Thai thesis has, as cases rather than as a count.
///
/// An enum rather than an array length because "five chapters" is the shape of
/// the document, not a number to check: a manuscript with chapter 4 missing is
/// not a manuscript that failed validation, it is one that cannot be built.
public enum ManuscriptChapter: Int, Sendable, Codable, CaseIterable, Identifiable {
    case introduction = 1
    case literature = 2
    case method = 3
    case results = 4
    case discussion = 5

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .introduction: localised("Chapter 1 Introduction", "Default manuscript chapter heading.")
        case .literature: localised("Chapter 2 Literature review", "Default manuscript chapter heading.")
        case .method: localised("Chapter 3 Method", "Default manuscript chapter heading.")
        case .results: localised("Chapter 4 Results", "Default manuscript chapter heading.")
        case .discussion: localised("Chapter 5 Conclusion, discussion and recommendations", "Default manuscript chapter heading.")
        }
    }
}

public struct ManuscriptSection: Sendable, Codable, Equatable {
    public var heading: String
    public var prose: [String]
    /// Sentences whose numbers come from runs (§20.8). Kept apart from `prose`
    /// so that "which numbers does this manuscript claim" is a question the
    /// document can answer about itself.
    public var reported: [ReportedSentence]

    public init(heading: String, prose: [String] = [], reported: [ReportedSentence] = []) {
        self.heading = heading
        self.prose = prose
        self.reported = reported
    }
}

public struct Manuscript: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    /// Which project this belongs to. A thesis draft is a project artefact —
    /// General having one would mean a manuscript that belongs to no study.
    public var scope: Scope
    public var title: String
    public var authors: [String]
    public var style: CitationStyle
    /// One entry per chapter. Missing chapters render as their heading and
    /// nothing else, which is what a manuscript in progress looks like — the
    /// five are always present because the type says so.
    public var sections: [ManuscriptChapter: [ManuscriptSection]]

    public init(id: String = OpaqueID.make("ms"), scope: Scope = .central,
                title: String, authors: [String] = [], style: CitationStyle = .apa,
                sections: [ManuscriptChapter: [ManuscriptSection]] = [:]) {
        self.id = id
        self.scope = scope
        self.title = title
        self.authors = authors
        self.style = style
        self.sections = sections
    }

    /// Every number this manuscript claims, in chapter order.
    ///
    /// *Claims*, not "has a reference for". A reference whose placeholder the
    /// author edited out of the sentence is not reported anywhere in the text,
    /// so binding it would refuse the export over a number nobody is quoting,
    /// and printing it in the appendix would list a figure the reader cannot
    /// find in the chapter (see `ManuscriptComposition`).
    public var references: [ResultReference] {
        ManuscriptChapter.allCases.flatMap { chapter in
            (sections[chapter] ?? []).flatMap { $0.reported.flatMap(\.claimedReferences) }
        }
    }

    /// References the text no longer has a place for. Shown while writing;
    /// never a reason to refuse a document.
    public var orphanedReferences: [ResultReference] {
        ManuscriptChapter.allCases.flatMap { chapter in
            (sections[chapter] ?? []).flatMap { $0.reported.flatMap(\.orphanedReferences) }
        }
    }
}

public enum ManuscriptError: Error, CustomStringConvertible, Equatable {
    case unboundResults([ResultBindingFailure])
    case unfilledPlaceholders([String])

    public var description: String {
        switch self {
        case .unboundResults(let failures):
            localised("the manuscript cannot be built — some numbers are not tied to a real run:\n", "Why a manuscript cannot be built.")
                + failures.map { "• \($0.text)" }.joined(separator: "\n")
        case .unfilledPlaceholders(let names):
            localised("the manuscript cannot be built — some slots in the text have nothing behind them: ", "Why a manuscript cannot be built.")
                + names.map { "{\($0)}" }.joined(separator: ", ")
        }
    }
}

public enum ManuscriptBuilder {

    /// Turns a manuscript into a draft the existing renderer can produce.
    ///
    /// Refuses when a number cannot be traced to a run. That refusal is the
    /// whole point of the type: a manuscript that renders with a hole where a
    /// mean should be is a manuscript somebody sends anyway, and one that
    /// renders a *stale* number is worse, because nothing about it looks wrong.
    public static func draft(_ manuscript: Manuscript, runs: [CellRun],
                             currentSources: [String: String] = [:]) throws -> DocumentDraft {
        var failures: [ResultBindingFailure] = []
        var bound: [String: BoundResult] = [:]
        for reference in manuscript.references {
            switch BoundResult.bind(reference, to: runs, currentSources: currentSources) {
            case .success(let result): bound[reference.id] = result
            case .failure(let failure): failures.append(failure)
            }
        }
        guard failures.isEmpty else { throw ManuscriptError.unboundResults(failures) }

        var unfilled: [String] = []
        for chapter in ManuscriptChapter.allCases {
            for section in manuscript.sections[chapter] ?? [] {
                for sentence in section.reported {
                    unfilled += sentence.unfilledPlaceholders
                }
            }
        }
        guard unfilled.isEmpty else {
            throw ManuscriptError.unfilledPlaceholders(Array(Set(unfilled)).sorted())
        }

        var sections: [Section] = []
        for chapter in ManuscriptChapter.allCases {
            sections.append(Section(heading: chapter.title, paragraphs: []))
            for section in manuscript.sections[chapter] ?? [] {
                var paragraphs: [Paragraph] = section.prose.map { .plain($0) }
                for sentence in section.reported {
                    let numbers = sentence.references.compactMap { bound[$0.id] }
                    paragraphs.append(.plain(sentence.filled(with: numbers)))
                }
                sections.append(Section(heading: section.heading, paragraphs: paragraphs))
            }
        }
        return DocumentDraft(title: manuscript.title, authors: manuscript.authors,
                             sections: sections, style: manuscript.style)
    }

    /// Where every number in the manuscript came from, as a table for the
    /// appendix.
    ///
    /// §12.4's habit applied to the manuscript: a result a reader cannot trace
    /// is a result they have to take on trust, and the cheapest way to give it
    /// back is to print the query beside the figure.
    public static func provenanceTable(_ manuscript: Manuscript, runs: [CellRun],
                                       currentSources: [String: String] = [:]) -> [String] {
        manuscript.references.compactMap { reference in
            guard case .success(let bound) = BoundResult.bind(reference, to: runs,
                                                              currentSources: currentSources)
            else { return nil }
            return "\(reference.label) = \(bound.value) · "
                + localised("run on \(bound.ranAt.formatted(date: .abbreviated, time: .shortened)) · ", "When a bound number was produced. Placeholder: the run time.")
                + bound.source.replacingOccurrences(of: "\n", with: " ")
        }
    }
}
