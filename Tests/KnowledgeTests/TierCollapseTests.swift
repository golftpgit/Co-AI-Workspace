import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// The two tier enums, collapsed (§14.1, P13.2's outstanding item).
//
// `Knowledge.SourceTier` and `AgentKit.CredibilityTier` were the same five
// tiers with **opposite `<`**: `t1 < t2` was true in one module and false in
// the other. Nothing crashed. A filter just kept the wrong sources, which is
// the failure §0.2 rule 3 is about, and `TierParityTests` could only stop the
// two drifting apart — not stop them meaning opposite things.
//
// These are the properties that make the collapse safe to have done.
// ─────────────────────────────────────────────────────────────

@Suite("One tier type, one direction")
struct TierCollapseTests {

    @Test("the alias and the type are the same thing")
    func aliasIsTheType() {
        #expect(SourceTier.t3 == CredibilityTier.t3)
        #expect(SourceTier.allCases.count == 5)
        #expect(SourceTier.t2.credibility == .t2)
    }

    /// One meaning: `<` is "worth less". The old `SourceTier` said the
    /// opposite and every comparison in Knowledge had to be re-read.
    @Test("a weaker source is less than a stronger one")
    func orderingHasOneDirection() {
        #expect(SourceTier.t5 < SourceTier.t1)
        #expect(SourceTier.t1 > SourceTier.t3)
        #expect([SourceTier.t3, .t1, .t5].max() == .t1)
        #expect([SourceTier.t3, .t1, .t5].min() == .t5)
        #expect(SourceTier.t1.isMoreCredibleThan(.t2))
        #expect(SourceTier.t4.isMoreCredibleThan(.t2) == false)
    }

    /// Provenance rows have been stored as `"t3"` since P2 and evidence rows
    /// as `3` since P1. A decoder that took one shape would have made half the
    /// stored knowledge base unreadable — the migration rule P9.2 settled.
    @Test("both stored shapes still decode")
    func decodesBothShapes() throws {
        let fromString = try JSONDecoder().decode(SourceTier.self, from: Data("\"t2\"".utf8))
        let fromNumber = try JSONDecoder().decode(SourceTier.self, from: Data("2".utf8))
        #expect(fromString == .t2)
        #expect(fromNumber == .t2)
        // Written as the string form, which is what the larger population uses.
        #expect(String(decoding: try JSONEncoder().encode(SourceTier.t2), as: UTF8.self) == "\"t2\"")
    }

    @Test("a tier that is neither shape is refused rather than guessed at")
    func rubbishIsRefused() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SourceTier.self, from: Data("9".utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SourceTier.self, from: Data("\"t9\"".utf8))
        }
    }

    @Test("the label and the number are still what people say out loud")
    func labelsSurvive() {
        #expect(SourceTier.t3.label == "T3")
        #expect(SourceTier.t3.number == 3)
        #expect(SourceTier.t1.rawValue == "t1")
    }

    /// The rule this whole thing protects: "at least T2" keeps T1 and T2 and
    /// drops T3 downwards, in every module, with one comparison.
    @Test("at least as credible as reads the same everywhere")
    func atLeastAsCredible() {
        let kept = SourceTier.allCases.filter { $0 >= .t2 }
        #expect(kept == [.t1, .t2])
    }
}
