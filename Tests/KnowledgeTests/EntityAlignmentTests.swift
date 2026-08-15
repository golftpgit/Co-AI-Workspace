import Testing
import Foundation
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P18.3 — one concept, two languages, one node.
//
// Vectors are scripted here: what is under test is the rule, and whether
// bge-m3 puts `burnout` and `ภาวะหมดไฟ` close together is a question for
// `EmbeddingCheck` against the real weights (E.25's lesson — a similarity
// threshold that was chosen rather than measured is the thing that went wrong
// in P18.2).
// ─────────────────────────────────────────────────────────────

private let burnout = "burnout"
private let thaiBurnout = "ภาวะหมดไฟ"
private let pressure = "pressure"
private let bloodPressure = "ความดัน"

private let vectors: [String: [Float]] = [
    burnout: [1, 0, 0],
    thaiBurnout: [0.99, 0.14, 0],       // ~0.99 — the same concept
    pressure: [0, 1, 0],
    bloodPressure: [0, 0.7, 0.71],      // ~0.70 — related, not the same
    "depression": [0, 0, 1],
    "ภาวะซึมเศร้า": [0.05, 0, 0.998],   // ~0.998
]

@Suite("One concept, two languages (P18.3)")
struct EntityAlignmentTests {

    @Test("names in two scripts that sit together are proposed as one concept")
    func crossLanguagePairsAreProposed() {
        let proposals = EntityAligner.propose(
            names: [burnout, thaiBurnout, "depression", "ภาวะซึมเศร้า"],
            vectors: vectors)

        #expect(proposals.count == 2)
        #expect(proposals[0].similarity > proposals[1].similarity, "not sorted by confidence")
        let joined = Set(proposals.flatMap { $0.labels.map(\.text) })
        #expect(joined == [burnout, thaiBurnout, "depression", "ภาวะซึมเศร้า"])
    }

    /// The merge that would be wrong: `ความดัน` is blood pressure, `pressure`
    /// is physical force. Related enough to sit near each other, not the same
    /// thing — so the threshold has to be where they stay apart.
    @Test("related but different concepts are not merged")
    func relatedIsNotTheSame() {
        let proposals = EntityAligner.propose(names: [pressure, bloodPressure],
                                              vectors: vectors)
        #expect(proposals.isEmpty)
    }

    @Test("two names in one language are not this rule's business")
    func sameLanguageIsLeftAlone() {
        // `burnout` and `burn-out` are a spelling problem, and spelling belongs
        // in `normalise`. This answers only the language split §11.8 raises.
        let proposals = EntityAligner.propose(
            names: [burnout, "burnout"],
            vectors: [burnout: [1, 0, 0]])
        #expect(proposals.isEmpty)
    }

    @Test("a merge keeps both names rather than one overwriting the other")
    func bothNamesSurvive() {
        let alignment = EntityAlignment(
            labels: [EntityLabel(text: burnout), EntityLabel(text: thaiBurnout)],
            similarity: 0.99)

        // The word an author chose is evidence. A reader working in Thai sees
        // the Thai name; the English one is still there and still points at the
        // chunk that used it.
        #expect(alignment.display(preferring: .thai) == thaiBurnout)
        #expect(alignment.display(preferring: .latin) == burnout)
        #expect(alignment.labels.count == 2)
    }

    /// The rule the measurement forced (E.26): a suggestion changes nothing.
    /// On this embedder the highest-scoring cross-language pair in the fixture
    /// is a *wrong* merge — "ความดัน" against "pressure" at 0.919 — so a system
    /// that merged on score would confidently join blood pressure to physical
    /// force.
    @Test("a suggestion does not join anything until a person confirms it")
    func suggestionsDoNotMerge() {
        let suggested = EntityAlignment(
            labels: [EntityLabel(text: burnout), EntityLabel(text: thaiBurnout)],
            similarity: 0.99)
        #expect(EntityAligner.canonicalKey(for: burnout, alignments: [suggested])
                != EntityAligner.canonicalKey(for: thaiBurnout, alignments: [suggested]),
                "an unconfirmed guess silently rewrote the graph")

        let confirmed = EntityAligner.confirm(suggested)
        #expect(confirmed.confirmedByHuman)
        #expect(EntityAligner.canonicalKey(for: burnout, alignments: [confirmed])
                == EntityAligner.canonicalKey(for: thaiBurnout, alignments: [confirmed]))
    }

    @Test("the graph keys on one deterministic name, not on the reader's language")
    func canonicalKeyIsStable() {
        let alignment = EntityAligner.confirm(EntityAlignment(
            labels: [EntityLabel(text: burnout), EntityLabel(text: thaiBurnout)],
            similarity: 0.99))
        // Both names answer to one key, so edges written in either language
        // join up — and the key does not move when somebody switches the
        // interface language, which would change the graph's shape.
        #expect(EntityAligner.canonicalKey(for: burnout, alignments: [alignment])
                == EntityAligner.canonicalKey(for: thaiBurnout, alignments: [alignment]))
        #expect(EntityAligner.canonicalKey(for: "unrelated", alignments: [alignment])
                == "unrelated")
    }

    /// §11.8's rule about guesses: a merge the system made must be visible and
    /// undoable, or it is indistinguishable from a fact.
    @Test("a merge carries its score, and can be split again")
    func mergesAreReversible() {
        let proposals = EntityAligner.propose(names: [burnout, thaiBurnout], vectors: vectors)
        let alignment = proposals[0]
        #expect(alignment.similarity > 0.9)
        #expect(alignment.confirmedByHuman == false, "a guess must not look like a decision")

        let after = EntityAligner.split(alignment.id, from: [EntityAligner.confirm(alignment)])
        #expect(after.isEmpty)
        // Split apart, they are two names again — exactly the state before the
        // guess, with nothing left behind.
        #expect(EntityAligner.canonicalKey(for: thaiBurnout, alignments: after)
                == EntityGraph.normalise(thaiBurnout))
    }

    @Test("proposing the same merge twice is one record, not two")
    func proposalsAreIdempotent() {
        let once = EntityAligner.propose(names: [burnout, thaiBurnout], vectors: vectors)
        let twice = EntityAligner.propose(names: [thaiBurnout, burnout], vectors: vectors)
        #expect(once.map(\.id) == twice.map(\.id))
    }

    @Test("a name with no vector is left alone rather than guessed at")
    func missingVectorsAreSkipped() {
        // An entity the embedder never saw is knowledge that has not been
        // connected yet, which is not the same as knowledge that disagrees.
        let proposals = EntityAligner.propose(
            names: [burnout, "ยังไม่ได้ฝัง"], vectors: vectors)
        #expect(proposals.isEmpty)
    }
}
