import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// P19.2 — and the arithmetic error this whole module exists for.
//
// A test with 90% sensitivity and 90% specificity, used where 1 person in 100
// has the disease, is right about a positive result 8% of the time. That figure
// is the standard teaching example precisely because clinicians, and papers,
// keep reading sensitivity as if it answered "does this patient have it".
//
// Every expected value below was computed independently outside this codebase
// (R12), from Bayes' theorem and the Wilson and Hanley–McNeil formulas.
// ─────────────────────────────────────────────────────────────

/// A screening study: 1,000 people, 50 with the disease, a test at 90/90.
private let screening = DiagnosticTable(
    truePositives: 45, falseNegatives: 5,
    falsePositives: 95, trueNegatives: 855)

private func isClose(_ actual: Double, _ expected: Double,
                     tolerance: Double = 1e-9) -> Bool {
    abs(actual - expected) <= tolerance * max(1, abs(expected))
}

@Suite("Diagnostic test accuracy")
struct DiagnosticAccuracyTests {

    @Test("sensitivity and specificity carry Wilson intervals, not bare percentages")
    func sensitivityAndSpecificity() throws {
        let sensitivity = try DiagnosticAccuracy.sensitivity(screening)
        #expect(isClose(sensitivity.value, 0.9))
        #expect(isClose(sensitivity.lower, 0.7863976856252035, tolerance: 1e-6))
        #expect(isClose(sensitivity.upper, 0.9565242350681096, tolerance: 1e-6))

        let specificity = try DiagnosticAccuracy.specificity(screening)
        #expect(isClose(specificity.value, 0.9))
        // Same point estimate, much tighter interval: 950 well people against
        // 50 diseased ones. A screen showing "90% / 90%" hides that.
        #expect(isClose(specificity.lower, 0.8792825890166878, tolerance: 1e-6))
        #expect(specificity.upper - specificity.lower < sensitivity.upper - sensitivity.lower)
    }

    /// The Done-when, in one test: the same test, three populations, three
    /// completely different answers to "does this patient have it".
    @Test("predictive values move with prevalence — the same test, three answers")
    func predictiveValuesFollowPrevalence() throws {
        let rare = try DiagnosticAccuracy.predictiveValues(screening, prevalence: 0.01)
        #expect(isClose(rare.positive, 0.0833333333, tolerance: 1e-8))
        #expect(isClose(rare.negative, 0.9988789238, tolerance: 1e-8))

        let common = try DiagnosticAccuracy.predictiveValues(screening, prevalence: 0.10)
        #expect(isClose(common.positive, 0.5, tolerance: 1e-9))

        let clinic = try DiagnosticAccuracy.predictiveValues(screening, prevalence: 0.50)
        #expect(isClose(clinic.positive, 0.9, tolerance: 1e-9))

        // 8% against 90% — same test, same sensitivity, same specificity.
        #expect(clinic.positive > rare.positive * 10)
    }

    @Test("a predictive value carries the prevalence it was computed at")
    func predictiveValuesRememberTheirPrevalence() throws {
        // A PPV without its prevalence is not a number anybody can use, and a
        // screen that prints one without the other is where the error starts.
        let values = try DiagnosticAccuracy.predictiveValues(screening, prevalence: 0.02)
        #expect(values.atPrevalence == 0.02)
    }

    @Test("a study's own prevalence is available but has to be asked for by name")
    func samplePrevalenceIsNamed() throws {
        // 5% here, because the study enrolled 50 diseased people out of 1,000 —
        // a design choice, not a fact about any population. Reading PPV off the
        // table's own cells silently assumes this number.
        #expect(isClose(screening.samplePrevalence, 0.05))
        let atSample = try DiagnosticAccuracy.predictiveValues(
            screening, prevalence: screening.samplePrevalence)
        // Which agrees with the raw cells, as it must: 45/(45+95).
        #expect(isClose(atSample.positive, 45.0 / 140.0, tolerance: 1e-9))
    }

    @Test("a prevalence outside 0–1 is refused rather than producing a probability")
    func impossiblePrevalenceIsRefused() {
        #expect(throws: StatError.self) {
            _ = try DiagnosticAccuracy.predictiveValues(screening, prevalence: 0)
        }
        #expect(throws: StatError.self) {
            _ = try DiagnosticAccuracy.predictiveValues(screening, prevalence: 1.5)
        }
    }

    @Test("likelihood ratios do not depend on prevalence, which is what they are for")
    func likelihoodRatios() throws {
        let ratios = try DiagnosticAccuracy.likelihoodRatios(screening)
        #expect(isClose(ratios.positive, 9.0, tolerance: 1e-9))
        #expect(isClose(ratios.negative, 0.1111111111, tolerance: 1e-8))
    }

    @Test("a specificity of exactly 1 is refused instead of reporting an infinite LR+")
    func perfectSpecificityIsRefused() {
        // 40 well people, none flagged: LR+ is infinite, which is a fact about
        // the sample size and not about the test.
        let small = DiagnosticTable(truePositives: 18, falseNegatives: 2,
                                    falsePositives: 0, trueNegatives: 40)
        #expect(throws: StatError.self) { _ = try DiagnosticAccuracy.likelihoodRatios(small) }
        // Sensitivity and specificity themselves are still reportable — Wilson
        // handles the boundary, which is why it is the interval used here.
        #expect(throws: Never.self) { _ = try DiagnosticAccuracy.specificity(small) }
    }

    @Test("the ROC area is the probability of ranking a case above a control")
    func areaUnderROC() throws {
        let scores = [0.1, 0.2, 0.35, 0.4, 0.55, 0.6, 0.7, 0.8, 0.9, 0.95]
        let labels = [false, false, false, true, false, true, true, false, true, true]
        let auc = try DiagnosticAccuracy.areaUnderROC(scores: scores, labels: labels)
        #expect(isClose(auc.value, 0.84, tolerance: 1e-9))
        #expect(isClose(auc.lower, 0.5758835812125116, tolerance: 1e-6))
        // Clamped at 1: the normal interval runs past it on a sample this
        // small, and an area above 1 is not a thing.
        #expect(auc.upper == 1)
    }

    @Test("a test that ranks everything backwards scores below a coin flip")
    func reversedTestScoresBelowHalf() throws {
        let scores = [0.9, 0.8, 0.7, 0.2, 0.1]
        let labels = [false, false, false, true, true]
        let auc = try DiagnosticAccuracy.areaUnderROC(scores: scores, labels: labels)
        #expect(auc.value == 0)
    }

    @Test("ties count a half rather than being resolved in the test's favour")
    func tiesCountHalf() throws {
        let auc = try DiagnosticAccuracy.areaUnderROC(scores: [0.5, 0.5], labels: [true, false])
        #expect(auc.value == 0.5)
    }

    @Test("an ROC with only one class refuses rather than returning 0 or 1")
    func oneClassIsRefused() {
        #expect(throws: StatError.self) {
            _ = try DiagnosticAccuracy.areaUnderROC(scores: [0.2, 0.8], labels: [true, true])
        }
    }
}
