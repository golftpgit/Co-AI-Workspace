import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// P19.5 — the most common error in public-health analysis, and the reason it
// survives: nothing in the output looks wrong.
//
// The variance components come from the balanced one-way ANOVA identities,
// which are exact for a balanced design and can be checked by hand — the
// fixture below is balanced for that reason, and every expected value was
// computed independently outside this codebase.
// ─────────────────────────────────────────────────────────────

/// Six clinics, five patients each. Clinics differ a great deal; patients
/// inside a clinic barely differ at all — which is the shape that makes thirty
/// observations behave like six.
private let clinics: [[Double]] = [
    [52, 55, 53, 54, 51],
    [68, 71, 69, 70, 72],
    [45, 44, 47, 46, 43],
    [61, 63, 60, 62, 64],
    [75, 77, 74, 76, 78],
    [57, 58, 56, 59, 55],
]

private func isClose(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-5) -> Bool {
    abs(actual - expected) <= tolerance
}

@Suite("Data that comes in clusters")
struct MultilevelTests {

    @Test("the variance splits into between-clinic and within-clinic")
    func varianceComponents() throws {
        let fit = try Multilevel.randomIntercept(clinics)
        #expect(isClose(fit.betweenVariance, 127.8))
        #expect(isClose(fit.withinVariance, 2.5))
        #expect(isClose(fit.intraclassCorrelation, 0.980814, 1e-6))
        #expect(fit.clusters == 6)
        #expect(fit.observations == 30)
    }

    /// The number that matters, in the words that make it matter.
    @Test("thirty observations from six clinics are worth about six")
    func effectiveSampleSize() throws {
        let fit = try Multilevel.randomIntercept(clinics)
        #expect(isClose(fit.designEffect, 4.923254, 1e-6))
        #expect(isClose(fit.effectiveSampleSize, 6.0935, 1e-4))
        // Every interval from a method that assumed independence is this much
        // too narrow.
        #expect(isClose(fit.standardErrorInflation, 2.218841, 1e-6))
    }

    @Test("clustered data is warned about, in terms of what it does to the interval")
    func clusteringIsWarnedAbout() throws {
        let fit = try Multilevel.randomIntercept(clinics)
        let check = Multilevel.independenceCheck(fit)
        #expect(check.wasChecked)
        #expect(check.passed == false)
        #expect(check.detail.contains("แคบเกินจริง"))
        #expect(check.detail.contains("6.1") || check.detail.contains("6.09"),
                "the warning does not say what the sample is really worth")
    }

    @Test("data that is not really clustered passes rather than being warned about")
    func independentDataPasses() throws {
        // Six groups drawn from one population: the between-group variance is
        // no bigger than chance, so nothing is lost by treating them as one
        // sample — and a warning here would teach people to ignore the warning.
        let unclustered: [[Double]] = [
            [50, 52, 48, 51, 49], [49, 51, 50, 52, 48], [51, 49, 52, 50, 48],
            [48, 50, 52, 49, 51], [52, 48, 50, 51, 49], [50, 51, 49, 48, 52],
        ]
        let fit = try Multilevel.randomIntercept(unclustered)
        #expect(fit.intraclassCorrelation < 0.05)
        #expect(Multilevel.independenceCheck(fit).passed)
    }

    /// A negative variance estimate is not a quantity, and printing one invites
    /// somebody to interpret its sign.
    @Test("clusters that differ less than chance report no clustering, not a negative variance")
    func negativeComponentsAreClamped() throws {
        let overlyUniform: [[Double]] = [[10, 20], [20, 10], [10, 20], [20, 10]]
        let fit = try Multilevel.randomIntercept(overlyUniform)
        #expect(fit.betweenVariance == 0)
        #expect(fit.intraclassCorrelation == 0)
        #expect(fit.designEffect == 1)
    }

    @Test("the gate's interval is the corrected one, and shows what the wrong one would be")
    func gateReportsBothIntervals() throws {
        // The result has to *be* the corrected analysis — a warning attached to
        // the uncorrected estimate would be the same mistake with a note.
        let result = try StatGate.clustered(clinics)
        #expect(result.test == .mixedModel)
        #expect(result.summary.contains("แก้ตามการจับกลุ่มแล้ว"))
        #expect(result.summary.contains("แคบเกินจริง"))
        #expect(result.assumptions.first?.passed == false)
        // 60.5 ± 1.96 × 4.30 rather than ± 1.96 × 1.94.
        #expect(result.summary.contains("60.5"))
        #expect(result.summary.contains("52.0"))
    }

    @Test("one cluster, or one observation each, is refused rather than guessed")
    func degenerateShapesAreRefused() {
        #expect(throws: StatError.self) { _ = try Multilevel.randomIntercept([[1, 2, 3]]) }
        #expect(throws: StatError.self) {
            _ = try Multilevel.randomIntercept([[1], [2], [3]])
        }
    }

    /// P19.0's rule, applied to the half of this task that is not built: an
    /// approximation would read exactly like the real thing.
    @Test("random slopes refuse rather than being approximated")
    func randomSlopesRefuse() {
        #expect(throws: StatError.self) { _ = try Multilevel.randomSlope(clinics) }
    }
}
