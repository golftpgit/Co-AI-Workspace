import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// `burnout` and `ภาวะหมดไฟ` are one thing (ARCHITECTURE §11.8, P18.3).
//
// **The defect this fixes is structural**: `EntityGraph.normalise` trims and
// lowercases, so two names for one concept in two languages are two nodes for
// ever. A bilingual library's graph is therefore cut in half along the language
// line, and the question somebody opens a graph to ask — "what is this
// connected to?" — comes back half-answered with nothing saying so.
//
// **Merged as one node with several names, never one name overwriting another.**
// The word an author chose is evidence; replacing "ภาวะหมดไฟ" with "burnout"
// because the graph prefers English throws away which term the source used, and
// relations still have to point back at the chunk in its own language (§11.6's
// verbatim rule applies here too).
//
// **Nothing merges until a person says so, and that is a measurement, not
// caution.** §11.8 proposed aligning by embedding distance. Measured on the
// real model (E.26), the distances do not separate the two groups — and they
// fail on exactly the example §11.8 names:
//
//     same concept, two languages   0.485  0.506  0.525  0.620
//     different concepts            0.414  0.504  0.510  **0.919**
//
// The 0.919 is "ความดัน" against "pressure": blood pressure and physical force,
// the merge that must not happen, scoring higher than every correct merge in
// the set. There is no threshold that admits the right ones and excludes it.
//
// So `propose` suggests and a person decides. `canonicalKey` honours only
// confirmed alignments — a suggestion changes nothing about the graph until
// somebody agrees with it. That keeps §11.8's promise ("a merge the system
// guessed must be visible and reversible") and adds the one the numbers force:
// it is not applied in the first place.
//
// **Not merged is not in conflict.** Two nodes that were never joined are
// knowledge that has not been connected yet, which is a different thing from
// knowledge that disagrees (§11.7).
// ─────────────────────────────────────────────────────────────

/// One name for a concept, in the language it was written in.
public struct EntityLabel: Sendable, Equatable, Hashable, Codable {
    public let text: String
    public let script: TextScript

    /// Three letters, not the twelve a passage needs: an entity name is short
    /// by nature — "burnout" is seven — and the floor is there to stop a
    /// confident answer about "ok", not to refuse ordinary words.
    static let minimumLetters = 3

    public init(text: String) {
        self.text = text
        self.script = TextScriptReader.script(of: text,
                                              minimumLetters: Self.minimumLetters)
    }

    public init(text: String, script: TextScript) {
        self.text = text
        self.script = script
    }
}

/// A merge the system proposed, with everything needed to judge or undo it.
public struct EntityAlignment: Sendable, Equatable, Identifiable {
    public let id: String
    public let labels: [EntityLabel]
    /// Cosine between the two names' embeddings. Kept because "the system
    /// thought they were the same" is not a reason anybody can weigh.
    public let similarity: Double
    /// Who decided. A merge the system guessed and a merge a person confirmed
    /// are different facts, and only one of them should survive a disagreement.
    public let confirmedByHuman: Bool

    public init(labels: [EntityLabel], similarity: Double, confirmedByHuman: Bool = false) {
        // Identity is the names it joins, sorted — so proposing the same merge
        // twice is the same record rather than a second one.
        self.id = labels.map(\.text).sorted().joined(separator: "|")
        self.labels = labels
        self.similarity = similarity
        self.confirmedByHuman = confirmedByHuman
    }

    /// The name to show a reader working in this script, falling back to
    /// whatever the concept has. Never a translation: every label here is a
    /// word some source actually used.
    public func display(preferring script: TextScript) -> String {
        labels.first { $0.script == script }?.text ?? labels.first?.text ?? ""
    }
}

public enum EntityAligner {
    /// How close two names must sit to be **suggested** as one concept.
    ///
    /// High, and it still does not make the suggestion trustworthy: E.26
    /// measured a wrong merge at 0.919 and correct ones as low as 0.485. The
    /// number's job is to keep the suggestion list short enough to read, not to
    /// decide anything — deciding is `confirmedByHuman`.
    public static let suggestionThreshold = 0.90

    /// Suggests merges between names in different scripts, for a person to
    /// accept or reject. Nothing here changes a graph.
    ///
    /// Same-script names are left alone: `burnout` and `burn-out` are a
    /// spelling problem, and `normalise` is where spelling belongs. This
    /// answers only the question §11.8 raises, which is the language split.
    public static func propose(names: [String],
                               vectors: [String: [Float]],
                               threshold: Double = suggestionThreshold) -> [EntityAlignment] {
        var proposals: [EntityAlignment] = []
        let labels = names.map(EntityLabel.init(text:))

        for i in labels.indices {
            for j in labels.indices where j > i {
                let a = labels[i], b = labels[j]
                // Only across a script boundary, and only when both sides are
                // decidable: `mixed` and `undetermined` are never "a different
                // language from" anything (E.25's rule).
                guard TextScriptReader.differentLanguages(
                        a.text, b.text, minimumLetters: EntityLabel.minimumLetters),
                      let left = vectors[a.text], let right = vectors[b.text] else { continue }
                let similarity = TextScriptReader.cosine(left, right)
                guard similarity >= threshold else { continue }
                proposals.append(EntityAlignment(labels: [a, b], similarity: similarity))
            }
        }
        return proposals.sorted { $0.similarity > $1.similarity }
    }

    /// The name a graph keys an entity by, once merges have been **confirmed**.
    ///
    /// Only confirmed alignments count. A suggestion that silently joined two
    /// nodes would be indistinguishable from a fact about the library, and on
    /// this embedder the highest-scoring suggestion in the fixture is a wrong
    /// one (E.26).
    ///
    /// The key itself is deterministic — the alphabetically first label —
    /// rather than "whichever language the reader prefers", because the key is
    /// what edges join on, and a key that moved with the interface language
    /// would change the graph's shape when somebody switched languages.
    public static func canonicalKey(for name: String,
                                    alignments: [EntityAlignment]) -> String {
        let normalised = EntityGraph.normalise(name)
        for alignment in alignments where alignment.confirmedByHuman
        && alignment.labels.contains(where: { EntityGraph.normalise($0.text) == normalised }) {
            return alignment.labels.map { EntityGraph.normalise($0.text) }.sorted()[0]
        }
        return normalised
    }

    /// A person accepting a suggestion. The only thing that makes a merge real.
    public static func confirm(_ alignment: EntityAlignment) -> EntityAlignment {
        EntityAlignment(labels: alignment.labels, similarity: alignment.similarity,
                        confirmedByHuman: true)
    }

    /// Undoes one merge. Named for what it is: the system guessed, and a person
    /// is saying no. The alignment is removed rather than marked rejected —
    /// with the record gone the two names are simply two names again, which is
    /// exactly the state before the guess.
    public static func split(_ id: String,
                             from alignments: [EntityAlignment]) -> [EntityAlignment] {
        alignments.filter { $0.id != id }
    }
}
