import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// P19.4 — counts, and the failure that does not look like one.
//
// The expected values here were computed by a separate implementation of the
// same IRLS, outside this codebase — independent code rather than a published
// table, and said so plainly. What P19.4's Done-when is actually about is not a
// coefficient matching a paper: it is that overdispersed counts pushed through
// a Poisson model produce a warning and a runnable alternative, and that is
// checked against behaviour rather than against a number.
// ─────────────────────────────────────────────────────────────

/// Three groups, rates rising, and counts inside each group that vary far more
/// than a Poisson process would: 0 and 11 in the same group.
private let group = [0.0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2]
private let overdispersedCounts = [0.0, 0, 1, 4, 8, 11, 1, 2, 4, 18, 26, 31,
                                   3, 5, 9, 44, 60, 75]
/// The same rates, behaving themselves.
private let tameCounts = [2.0, 3, 2, 3, 2, 3, 5, 6, 5, 6, 5, 6, 12, 13, 12, 13, 12, 13]

private func isClose(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-4) -> Bool {
    abs(actual - expected) <= tolerance
}

@Suite("Count and rate models")
struct CountModelTests {

    @Test("Poisson regression fits the log-linear rate")
    func poissonFits() throws {
        let fit = try CountModels.poisson(counts: tameCounts, predictors: [group])
        #expect(isClose(fit.coefficients[1], 0.809062))
        // A rate ratio of about 2.25 per group step, which is what the counts
        // say: 2.5 → 5.5 → 12.5.
        #expect(isClose(fit.rateRatios[1], exp(0.809062)))
        #expect(fit.theta == nil, "a Poisson fit must not claim a dispersion it assumed away")
        #expect(fit.iterations < 20)
    }

    /// The Done-when. The coefficient is fine; the standard error is not, and
    /// nothing about the output looks wrong — which is why this is checked
    /// every time rather than offered as an option.
    @Test("overdispersed counts in a Poisson model are caught and named")
    func overdispersionIsCaught() throws {
        let fit = try CountModels.poisson(counts: overdispersedCounts, predictors: [group])
        #expect(isClose(fit.coefficients[1], 0.986703))

        let check = CountModels.overdispersion(counts: overdispersedCounts,
                                               predictors: [group], fit: fit)
        #expect(check.wasChecked)
        #expect(check.passed == false)
        #expect(isClose(check.statistic ?? 0, 15.0011, 1e-3))
        #expect(check.detail.contains("negative binomial"),
                "the warning has to name the model that handles it")
        #expect(check.detail.contains("too narrow"))
    }

    @Test("counts that behave pass the check rather than being warned about anyway")
    func tameCountsPass() throws {
        // A warning on every fit is a warning nobody reads.
        let fit = try CountModels.poisson(counts: tameCounts, predictors: [group])
        let check = CountModels.overdispersion(counts: tameCounts, predictors: [group], fit: fit)
        #expect(check.passed)
        #expect(check.statistic! < 1)
    }

    /// Why the warning matters, in one comparison: the same data, the same
    /// effect, and an interval two and a half times wider once the spread is
    /// modelled instead of assumed away.
    @Test("the negative binomial keeps the effect and widens the interval")
    func negativeBinomialWidensTheInterval() throws {
        let poisson = try CountModels.poisson(counts: overdispersedCounts, predictors: [group])
        let nb = try CountModels.negativeBinomial(counts: overdispersedCounts,
                                                  predictors: [group])

        #expect(isClose(nb.coefficients[1], 1.041938, 1e-3))
        #expect(isClose(nb.standardErrors[1], 0.265700, 1e-3))
        #expect(isClose(poisson.standardErrors[1], 0.087852, 1e-3))
        #expect(nb.standardErrors[1] > poisson.standardErrors[1] * 2.5,
                "the interval did not widen — the extra parameter did nothing")
        #expect(nb.theta != nil)
        #expect(isClose(nb.theta ?? 0, 1.387356, 1e-3))
    }

    @Test("counts that are not overdispersed refuse a negative binomial rather than fitting one")
    func negativeBinomialRefusesWhenPointless() {
        // Fitting one here would be a Poisson with a wasted parameter, and
        // saying so is better than returning a huge theta that means the same
        // thing obscurely.
        #expect(throws: StatError.self) {
            _ = try CountModels.negativeBinomial(counts: tameCounts, predictors: [group])
        }
    }

    @Test("a continuous outcome is refused rather than rounded into a count")
    func nonCountsAreRefused() {
        #expect(throws: StatError.self) {
            _ = try CountModels.poisson(counts: [1.5, 2.5, 3.5, 4.5],
                                        predictors: [[0.0, 1, 2, 3]])
        }
        #expect(throws: StatError.self) {
            _ = try CountModels.poisson(counts: [-1, 2, 3, 4],
                                        predictors: [[0.0, 1, 2, 3]])
        }
    }

    @Test("more parameters than observations is refused, not fitted")
    func tooFewObservations() {
        #expect(throws: StatError.self) {
            _ = try CountModels.poisson(counts: [1, 2], predictors: [[0.0, 1], [1.0, 0]])
        }
    }
}
