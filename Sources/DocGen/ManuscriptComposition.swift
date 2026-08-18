import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Writing a sentence whose numbers are not typed (ARCHITECTURE §20.8, P11.9).
//
// `Manuscript.swift` settled what a reported number *is*: a `ResultReference`
// resolved against a run that happened, refused when the cell never ran or its
// source has changed since. What it did not settle is how a person produces one,
// and the obvious answer is the one that fails.
//
// The obvious answer is: type the sentence with `{ค่าเฉลี่ยอายุ}` in it, then
// fill in a form describing where that number comes from. Two strings, typed
// twice, that have to match exactly — including in a script where the visual
// difference between "อายุ" and "อายุ " is nothing. When they do not match the
// export is refused, which is correct and arrives long after the mistake, with
// a message about a placeholder the author believes they wrote correctly.
//
// So the placeholder is never typed. `insert(_:)` writes `{label}` into the
// text **and** records the reference in one move, and the text and the
// reference list cannot disagree because one action produces both.
//
// Three things this refuses outright, each of them a way to lose a number
// quietly:
//
//  • **A duplicate label in one sentence.** Filling is a string replacement, so
//    two references called "ค่าเฉลี่ย" means the first number is written into
//    both places and the second is never printed at all.
//  • **A label with a brace in it.** The placeholder parser reads `{` and `}`,
//    so a label containing one produces a placeholder nothing can fill.
//  • **An empty label.** `{}` is not a placeholder; it is two characters that
//    render into the document.
//
// And one thing it reports rather than refuses: a reference whose placeholder
// has been deleted from the text. The number is no longer claimed by the
// sentence, so refusing the whole export would be wrong — but it must not stay
// in the provenance table either, where it would appear as a figure the reader
// cannot find in the text.
// ─────────────────────────────────────────────────────────────

public extension ReportedSentence {
    /// References whose placeholder is not in the text any more — usually
    /// because the author edited the sentence around it.
    ///
    /// Not an error. It means the number is not being claimed, and the
    /// appendix must agree with the text about that.
    var orphanedReferences: [ResultReference] {
        let present = Set(Self.placeholders(in: text))
        return references.filter { !present.contains($0.label) }
    }

    /// The references this sentence actually prints.
    var claimedReferences: [ResultReference] {
        let present = Set(Self.placeholders(in: text))
        return references.filter { present.contains($0.label) }
    }
}

public enum SentenceCompositionError: Error, CustomStringConvertible, Equatable {
    case duplicateLabel(String)
    case labelContainsBrace(String)
    case emptyLabel

    public var description: String {
        switch self {
        case .duplicateLabel(let label):
            localised("this sentence already has a “\(label)” — the same name twice means the second number ", "A duplicate slot name. Placeholder: the name.")
                + localised("never reaches the page while the first appears in both places · give them different names ", "Continues the duplicate-name warning.")
                + localised("for instance “treatment group mean” and “control group mean”", "Ends the duplicate-name warning with an example.")
        case .labelContainsBrace(let label):
            localised("the name “\(label)” contains a brace, which is what marks a slot — it cannot be used in a name", "An invalid slot name. Placeholder: the name.")
        case .emptyLabel:
            localised("this number needs a name first — the name is what appears when binding fails", "An unnamed slot.")
        }
    }
}

/// A sentence being written, with its numbers inserted rather than typed.
public struct SentenceComposer: Sendable, Equatable {
    public private(set) var text: String
    public private(set) var references: [ResultReference]

    public init(_ text: String = "", references: [ResultReference] = []) {
        self.text = text
        self.references = references
    }

    public init(_ sentence: ReportedSentence) {
        self.text = sentence.text
        self.references = sentence.references
    }

    /// Ordinary typing. The placeholders already in the text are left alone.
    public mutating func write(_ text: String) {
        self.text = text
    }

    /// Puts a number into the sentence: writes its placeholder at the end of
    /// the text and records where it comes from, in one move.
    ///
    /// The two cannot drift because there is no way to do one without the
    /// other — which is the whole reason this type exists.
    public mutating func insert(_ reference: ResultReference) throws {
        let label = reference.label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { throw SentenceCompositionError.emptyLabel }
        guard !label.contains("{"), !label.contains("}") else {
            throw SentenceCompositionError.labelContainsBrace(label)
        }
        guard !references.contains(where: { $0.label == label }) else {
            throw SentenceCompositionError.duplicateLabel(label)
        }
        references.append(reference)
        // A space only when there is something to separate it from, so a
        // sentence does not start with one.
        if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
        text += "{\(label)}"
    }

    /// Removes a number: takes the placeholder out of the text as well as the
    /// reference off the list, for the same reason `insert` does both.
    public mutating func remove(_ reference: ResultReference) {
        references.removeAll { $0.id == reference.id }
        text = text.replacingOccurrences(of: "{\(reference.label)}", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The sentence, with the references that are still claimed by the text.
    ///
    /// Orphans are dropped here rather than carried: a reference whose
    /// placeholder was edited away is a number the sentence does not report,
    /// and keeping it would put a figure in the appendix that the reader
    /// cannot find in the chapter.
    public var sentence: ReportedSentence {
        let composed = ReportedSentence(text, references: references)
        return ReportedSentence(text, references: composed.claimedReferences)
    }

    /// What is wrong with this sentence right now, in the words the screen
    /// shows — so the author finds out while writing rather than at export.
    public var problems: [String] {
        var found: [String] = []
        let composed = ReportedSentence(text, references: references)
        for name in composed.unfilledPlaceholders {
            found.append(localised("“{\(name)}” in the text has nothing behind it — the braces will print literally", "An unbound slot. Placeholder: the slot name."))
        }
        for orphan in composed.orphanedReferences {
            found.append(localised("“\(orphan.label)” is bound but the text no longer has a slot for it — ", "An orphaned binding. Placeholder: the name.")
                         + localised("it will not print, and will not appear in the appendix of where numbers came from", "Ends the orphaned-binding warning."))
        }
        return found
    }
}

// ─────────────────────────────────────────────────────────────
// What the author sees before exporting
// ─────────────────────────────────────────────────────────────

/// The manuscript with its numbers filled in, or the reasons it cannot be.
///
/// `ManuscriptBuilder.draft` already refuses at export time, which is the
/// guarantee. This is the same check run while the author is still writing,
/// because "your chapter 4 will not export" is worth knowing before the
/// afternoon it is due.
public struct ManuscriptPreview: Sendable, Equatable {
    /// Chapter → the sentences as they would appear, numbers included.
    public let filled: [ManuscriptChapter: [String]]
    /// Every number that could not be traced to a run, with why.
    public let failures: [ResultBindingFailure]
    /// Placeholders with nothing behind them.
    public let unfilled: [String]

    public var isExportable: Bool { failures.isEmpty && unfilled.isEmpty }

    public static func of(_ manuscript: Manuscript, runs: [CellRun],
                          currentSources: [String: String] = [:]) -> ManuscriptPreview {
        var bound: [String: BoundResult] = [:]
        var failures: [ResultBindingFailure] = []
        for reference in manuscript.references {
            switch BoundResult.bind(reference, to: runs, currentSources: currentSources) {
            case .success(let result): bound[reference.id] = result
            case .failure(let failure): failures.append(failure)
            }
        }

        var filled: [ManuscriptChapter: [String]] = [:]
        var unfilled: [String] = []
        for chapter in ManuscriptChapter.allCases {
            var lines: [String] = []
            for section in manuscript.sections[chapter] ?? [] {
                lines += section.prose
                for sentence in section.reported {
                    unfilled += sentence.unfilledPlaceholders
                    let numbers = sentence.references.compactMap { bound[$0.id] }
                    lines.append(sentence.filled(with: numbers))
                }
            }
            if !lines.isEmpty { filled[chapter] = lines }
        }
        return ManuscriptPreview(filled: filled, failures: failures,
                                 unfilled: Array(Set(unfilled)).sorted())
    }
}
