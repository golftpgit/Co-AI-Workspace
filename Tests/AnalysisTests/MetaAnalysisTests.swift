import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// P19.7 — pooling seven trials, and the part that has to be said out loud.
//
// I² and Q are definitional — `(Q − df)/Q` can be checked against the numbers
// printed here by hand — and every other expected value was computed by a
// separate implementation of the same formulas outside this codebase.
// ─────────────────────────────────────────────────────────────

/// Seven trials as log odds ratios: all pointing the same way, with the usual
/// spread of precisions.
private let trials = [
    StudyEffect(label: "A", effect: -0.30, standardError: 0.12),
    StudyEffect(label: "B", effect: -0.45, standardError: 0.20),
    StudyEffect(label: "C", effect: -0.12, standardError: 0.15),
    StudyEffect(label: "D", effect: -0.62, standardError: 0.30),
    StudyEffect(label: "E", effect: -0.05, standardError: 0.10),
    StudyEffect(label: "F", effect: -0.55, standardError: 0.25),
    StudyEffect(label: "G", effect: -0.38, standardError: 0.18),
]

private func isClose(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-5) -> Bool {
    abs(actual - expected) <= tolerance
}

@Suite("Meta-analysis")
struct MetaAnalysisTests {

    @Test("fixed effect pools by precision, not by how many people were enrolled")
    func fixedEffect() throws {
        let pooled = try MetaAnalysis.pool(trials, model: .fixed)
        #expect(isClose(pooled.effect, -0.235239))
        #expect(isClose(pooled.standardError, 0.058039))
        #expect(isClose(pooled.lower, -0.348993))
        #expect(isClose(pooled.upper, -0.121484))
        #expect(pooled.pValue < 0.001)
        // Study E is the most precise and carries the most weight; D the least.
        #expect(pooled.weights[4] > pooled.weights[3])
        #expect(isClose(pooled.weights.reduce(0, +), 1, 1e-9))
    }

    @Test("random effects widens the interval, because it stops assuming one true value")
    func randomEffects() throws {
        let fixed = try MetaAnalysis.pool(trials, model: .fixed)
        let random = try MetaAnalysis.pool(trials, model: .random)
        #expect(isClose(random.effect, -0.273556))
        #expect(isClose(random.standardError, 0.077712))
        #expect(random.upper - random.lower > fixed.upper - fixed.lower)
        // The weights even out: a random-effects model trusts the big study
        // less, because part of the disagreement is real rather than noise.
        #expect(random.weights[4] < fixed.weights[4])
    }

    @Test("Q, I² and τ² say whether pooling means anything")
    func heterogeneity() throws {
        let spread = try MetaAnalysis.heterogeneity(trials)
        #expect(isClose(spread.q, 9.342753))
        #expect(spread.degreesOfFreedom == 6)
        // (9.342753 − 6) / 9.342753 = 35.78%, checkable by hand.
        #expect(isClose(spread.iSquared, 35.779100, 1e-4))
        #expect(isClose(spread.tauSquared, 0.014304, 1e-6))
        #expect(spread.interpretation.contains("ปานกลาง"))
    }

    @Test("studies that disagree completely are described as such, not just pooled")
    func highHeterogeneityIsNamed() throws {
        let contradictory = [
            StudyEffect(label: "A", effect: -1.2, standardError: 0.10),
            StudyEffect(label: "B", effect: 0.9, standardError: 0.10),
            StudyEffect(label: "C", effect: -1.1, standardError: 0.12),
            StudyEffect(label: "D", effect: 1.0, standardError: 0.11),
        ]
        let spread = try MetaAnalysis.heterogeneity(contradictory)
        #expect(spread.iSquared > 95)
        // Pooling still returns a number — which is the danger, and why the
        // reading is words rather than a value somebody has to interpret.
        #expect(spread.interpretation.contains("อาจไม่มีความหมาย"))
    }

    @Test("studies that agree more closely than chance report no between-study variance")
    func negativeTauIsClamped() throws {
        // A negative estimate is not a quantity: it means zero disagreement
        // plus luck.
        let identical = [
            StudyEffect(label: "A", effect: -0.30, standardError: 0.20),
            StudyEffect(label: "B", effect: -0.30, standardError: 0.20),
            StudyEffect(label: "C", effect: -0.30, standardError: 0.20),
        ]
        let spread = try MetaAnalysis.heterogeneity(identical)
        #expect(spread.tauSquared == 0)
        #expect(spread.iSquared == 0)
        // With no between-study variance the two models agree exactly.
        #expect(isClose(try MetaAnalysis.pool(identical, model: .fixed).effect,
                        try MetaAnalysis.pool(identical, model: .random).effect, 1e-12))
    }

    /// The Done-when: asymmetry is *reported*, not drawn and left to the eye.
    @Test("funnel asymmetry is stated in words, with what it would mean")
    func asymmetryIsReported() throws {
        // The same trials, except the two least precise now show much larger
        // effects — the signature of small studies that found nothing never
        // being published.
        let skewed = [
            StudyEffect(label: "A", effect: -0.30, standardError: 0.12),
            StudyEffect(label: "B", effect: -0.45, standardError: 0.20),
            StudyEffect(label: "C", effect: -0.12, standardError: 0.15),
            StudyEffect(label: "D", effect: -1.40, standardError: 0.30),
            StudyEffect(label: "E", effect: -0.05, standardError: 0.10),
            StudyEffect(label: "F", effect: -1.30, standardError: 0.25),
            StudyEffect(label: "G", effect: -0.38, standardError: 0.18),
        ]
        let test = try MetaAnalysis.funnelAsymmetry(skewed)
        #expect(isClose(test.intercept, -6.162517, 1e-4))
        #expect(test.isAsymmetric)
        #expect(test.summary.contains("funnel ไม่สมมาตร"))
        #expect(test.summary.contains("publication bias"))
        #expect(test.summary.contains("เกินจริง"))
    }

    /// A negative result from a weak test is not the same as evidence of
    /// absence, and the sentence says so rather than leaving the reader to
    /// remember it.
    @Test("no asymmetry found is not reported as no asymmetry present")
    func absenceOfEvidenceIsSaidPlainly() throws {
        let symmetric = [
            StudyEffect(label: "A", effect: -0.30, standardError: 0.10),
            StudyEffect(label: "B", effect: -0.28, standardError: 0.20),
            StudyEffect(label: "C", effect: -0.32, standardError: 0.30),
            StudyEffect(label: "D", effect: -0.29, standardError: 0.40),
        ]
        let test = try MetaAnalysis.funnelAsymmetry(symmetric)
        #expect(test.isAsymmetric == false)
        #expect(test.summary.contains("ไม่ได้แปลว่าไม่มี"))
        #expect(test.summary.contains("พลังต่ำ"))
    }

    @Test("too few studies to pool, or to test, is refused rather than answered")
    func tooFewStudies() {
        #expect(throws: StatError.self) {
            _ = try MetaAnalysis.pool([trials[0]])
        }
        #expect(throws: StatError.self) {
            _ = try MetaAnalysis.funnelAsymmetry(Array(trials.prefix(2)))
        }
        #expect(throws: StatError.self) {
            _ = try MetaAnalysis.pool([StudyEffect(label: "A", effect: 1, standardError: 0),
                                       StudyEffect(label: "B", effect: 2, standardError: 1)])
        }
    }
}
