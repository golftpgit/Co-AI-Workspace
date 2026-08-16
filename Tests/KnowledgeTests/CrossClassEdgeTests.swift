import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P18.5 — which line in the graph is the finding.
//
// §11.9: in interdisciplinary work the interesting relation is the one that
// goes from `RA` to `QA`, not the ones inside `RA`. The rule lives here so it
// can be checked without a window; the drawing that uses it is in
// `EntityGraphView`, and the same rule decides the spoken label so the picture
// and the list cannot disagree.
// ─────────────────────────────────────────────────────────────

/// The map the screen builds: an entity belongs to the classes of the
/// documents that name it. There is nowhere else a class could come from.
private func classes(_ pairs: [(String, [LCClass])]) -> [String: Set<LCClass>] {
    Dictionary(uniqueKeysWithValues: pairs.map {
        (EntityGraph.normalise($0.0), Set($0.1))
    })
}

private func crosses(_ subject: String, _ object: String,
                     in map: [String: Set<LCClass>]) -> Bool {
    guard let left = map[EntityGraph.normalise(subject)],
          let right = map[EntityGraph.normalise(object)],
          !left.isEmpty, !right.isEmpty else { return false }
    return left.isDisjoint(with: right)
}

@Suite("Edges that cross a class boundary")
struct CrossClassEdgeTests {

    @Test("public health to statistics crosses; public health to nursing does not")
    func crossingIsBetweenClassesNotSubclasses() {
        let map = classes([
            ("การคัดกรองเบาหวาน", [.r]),      // RA
            ("การถดถอยโลจิสติก", [.h]),        // HA — statistics
            ("การพยาบาล", [.r]),               // RT — same class, different subclass
        ])
        #expect(crosses("การคัดกรองเบาหวาน", "การถดถอยโลจิสติก", in: map))
        // Both R: a relation inside medicine is the background, not the finding.
        #expect(crosses("การคัดกรองเบาหวาน", "การพยาบาล", in: map) == false)
    }

    @Test("an entity in both classes bridges rather than crosses")
    func sharedClassIsNotACrossing() {
        // A statistician's paper about screening sits in both, so a line from
        // it to either side stays inside a shared class — which is right: it is
        // the same body of work, not two.
        let map = classes([
            ("การคัดกรองเบาหวาน", [.r]),
            ("งานวิจัยระบาดวิทยาเชิงสถิติ", [.r, .h]),
        ])
        #expect(crosses("การคัดกรองเบาหวาน", "งานวิจัยระบาดวิทยาเชิงสถิติ", in: map) == false)
    }

    /// Guessing here would highlight exactly the entities nobody has
    /// classified — the opposite of what the highlight is for.
    @Test("an end with no class is not a crossing")
    func unclassifiedEndsAreNotCrossings() {
        let map = classes([("การคัดกรองเบาหวาน", [.r])])
        #expect(crosses("การคัดกรองเบาหวาน", "คำที่ยังไม่มีหมวด", in: map) == false)
        #expect(crosses("ไม่รู้จัก", "ไม่รู้จักเช่นกัน", in: map) == false)
    }

    @Test("the same entity written two ways is one entity")
    func normalisationApplies() {
        // The graph joins on the normalised name, and so must this — otherwise
        // "Burnout" and "burnout" would be a crossing between a class and
        // nothing.
        let map = classes([("Burnout", [.r]), ("Machine Learning", [.q])])
        #expect(crosses("burnout", "machine learning", in: map))
    }
}
