import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// The Statistical Verification Gate (ARCHITECTURE §12.3, P6.6).
//
// The numbers are checked against values that can be looked up rather than
// against our own output: t and F critical points from the standard tables, the
// tea-tasting table for Fisher's exact, a Kruskal–Wallis worked by hand. A
// statistics module tested only against itself is a module that is
// self-consistently wrong.
// ─────────────────────────────────────────────────────────────

/// A perfectly normal sample: the expected order statistics themselves. Any
/// correct Shapiro–Wilk gives W = 1 here, which is a stronger check than any
/// published example.
private func idealNormalSample(_ n: Int) -> [Double] {
    (1...n).map { Statistics.normalQuantile((Double($0) - 0.375) / (Double(n) + 0.25)) }
}

/// Sharply right-skewed, the shape a length-of-stay or cost variable actually
/// has — and the reason this gate exists.
private let skewed: [Double] = [1, 1, 1, 2, 2, 2, 3, 3, 4, 5, 8, 14, 27, 61, 140]

@Suite("Statistics")
struct StatisticsTests {

    @Test("the distribution tails match the published critical values")
    func distributions() {
        // t(10) two-sided 5% point is 2.228.
        #expect(abs(Statistics.tTestPValue(t: 2.228, degreesOfFreedom: 10) - 0.05) < 0.0005)
        // F(3, 10) upper 5% point is 3.708.
        #expect(abs(Statistics.fTestPValue(f: 3.708, d1: 3, d2: 10) - 0.05) < 0.0005)
        // χ²(3) upper 5% point is 7.815.
        #expect(abs(Statistics.chiSquarePValue(7.815, degreesOfFreedom: 3) - 0.05) < 0.0005)
        // The 97.5th percentile of the standard normal.
        #expect(abs(Statistics.normalQuantile(0.975) - 1.959964) < 1e-5)
        #expect(abs(Statistics.normalCDF(1.959964) - 0.975) < 1e-6)
    }

    /// Royston's corrected end weights mean W does not come out at exactly 1
    /// even here — but anything below 0.99 on this sample is an arithmetic
    /// mistake, not a property of the data.
    @Test("Shapiro–Wilk is at its ceiling for a sample that is exactly normal")
    func shapiroOnIdealSample() throws {
        let test = try #require(Statistics.shapiroWilk(idealNormalSample(20)))
        #expect(test.w > 0.99)
        #expect(test.pValue > 0.9)
    }

    @Test("Shapiro–Wilk rejects a sharply skewed sample")
    func shapiroOnSkewedSample() throws {
        let test = try #require(Statistics.shapiroWilk(skewed))
        #expect(test.w < 0.8)
        #expect(test.pValue < 0.01)
    }

    @Test("it says it cannot test rather than testing nothing")
    func shapiroRefusesImpossibleInput() {
        #expect(Statistics.shapiroWilk([1, 2]) == nil)
        // Every value identical: there is no spread to judge.
        #expect(Statistics.shapiroWilk([5, 5, 5, 5, 5]) == nil)
    }

    @Test("ties share their rank, which every rank test depends on")
    func midranks() {
        #expect(Statistics.ranks([10, 20, 20, 30]) == [1, 2.5, 2.5, 4])
    }

    @Test("least squares recovers a line it was given")
    func regressionRecoversTheLine() throws {
        let x = (1...20).map(Double.init)
        let y = x.map { 2 * $0 + 1 }
        let fit = try #require(Statistics.leastSquares(y: y, predictors: [x]))
        #expect(abs(fit.coefficients[0] - 1) < 1e-9)
        #expect(abs(fit.coefficients[1] - 2) < 1e-9)
        #expect(abs(fit.rSquared - 1) < 1e-9)
    }

    @Test("logistic regression recovers a direction it was given")
    func logisticRecoversDirection() throws {
        let x = (1...24).map { Double($0) }
        let y = x.map { $0 > 12.5 ? 1.0 : 0.0 }
        let fit = try #require(Statistics.logistic(y: y, predictors: [x]))
        #expect(fit.coefficients[1] > 0)
        // Perfectly separable data: the fit runs away, and saying so is the
        // whole value of the flag.
        #expect(fit.separated)
    }
}

@Suite("Statistical verification gate")
struct StatGateTests {

    /// P6.6's Done-when, exactly: a t-test on data that is not normal has to
    /// warn and name the non-parametric test to use instead.
    @Test("a t-test on non-normal data warns and proposes a non-parametric test")
    func theDoneWhen() throws {
        let result = try StatGate.twoSample(skewed, skewed.map { $0 * 1.4 + 1 })
        #expect(!result.isClean)
        #expect(result.warnings.contains { $0.name.contains("การแจกแจงปกติ") })
        #expect(result.alternatives == [.mannWhitney])
        // And it goes back to the plan, because changing the test is a change
        // of methodology (§12.3).
        #expect(result.requiresPlanReapproval)
        // The numbers travel with the verdict.
        #expect(result.report.contains("Shapiro–Wilk"))
        #expect(result.report.contains("Mann–Whitney"))
    }

    @Test("a t-test on normal data comes back clean, with nothing to approve again")
    func cleanTTest() throws {
        let a = idealNormalSample(24)
        let b = idealNormalSample(24).map { $0 + 0.4 }
        let result = try StatGate.twoSample(a, b)
        #expect(result.isClean)
        #expect(result.alternatives.isEmpty)
        #expect(!result.requiresPlanReapproval)
    }

    /// t = 1 on 8 degrees of freedom is p = 0.3466 in the tables.
    @Test("the t statistic and its p-value are the published ones")
    func tStatisticIsCorrect() throws {
        let result = try StatGate.twoSample([1, 2, 3, 4, 5], [2, 3, 4, 5, 6],
                                            assumingEqualVariance: true)
        #expect(abs(result.statistic + 1) < 1e-9)
        #expect(abs(result.pValue - 0.3466) < 0.001)
        #expect(result.test == .studentT)
    }

    /// Student's t assumes equal variances; Welch does not, so only the first
    /// one has to be checked for it.
    @Test("equal variance is checked for Student and not claimed for Welch")
    func varianceAssumption() throws {
        let tight = idealNormalSample(15)
        let wide = idealNormalSample(15).map { $0 * 8 }
        let student = try StatGate.twoSample(tight, wide, assumingEqualVariance: true)
        #expect(student.warnings.contains { $0.name.contains("ความแปรปรวน") })
        #expect(student.report.contains("Levene"))

        let welch = try StatGate.twoSample(tight, wide)
        #expect(!welch.assumptions.contains { $0.name.contains("ความแปรปรวน") })
        #expect(welch.isClean)
    }

    /// The paired test's assumption is about the differences, not about either
    /// column — a detail that is wrong in a lot of published analyses.
    @Test("the paired test judges the differences, not the two columns")
    func pairedJudgesDifferences() throws {
        // Both columns are wildly non-normal; their difference is a constant
        // plus a normal wobble, which is what the test actually assumes.
        let before = skewed
        let after = zip(skewed, idealNormalSample(skewed.count)).map { $0 + 1 + $1 * 0.1 }
        let result = try StatGate.paired(before, after)
        #expect(result.assumptions.count == 1)
        #expect(result.assumptions[0].name.contains("ผลต่าง"))
        #expect(result.isClean)
    }

    @Test("a paired test on non-normal differences proposes Wilcoxon")
    func pairedProposesWilcoxon() throws {
        let after = zip(skewed, skewed).map { $0 * 2 + $1 * 0.5 }
        let result = try StatGate.paired(skewed, after)
        #expect(!result.isClean)
        #expect(result.alternatives == [.wilcoxonSignedRank])
    }

    /// F = 27 on (2, 6) degrees of freedom is the 99.9th percentile.
    @Test("ANOVA's F is the published one, and it proposes Kruskal–Wallis when asked to")
    func anova() throws {
        let result = try StatGate.oneWayANOVA([[1, 2, 3], [4, 5, 6], [7, 8, 9]])
        #expect(abs(result.statistic - 27) < 1e-9)
        #expect(abs(result.pValue - 0.001) < 0.0005)
        // n = 3 per group is too small for Shapiro–Wilk to say anything, and
        // "could not check" is a warning, not a pass.
        #expect(!result.isClean)
        #expect(result.alternatives == [.kruskalWallis])
    }

    /// Worked by hand: H = 12/(9·10)·279 − 30 = 7.2 on 2 df.
    @Test("Kruskal–Wallis matches the hand calculation")
    func kruskalWallis() throws {
        let result = try StatGate.kruskalWallis([[1, 2, 3], [4, 5, 6], [7, 8, 9]])
        #expect(abs(result.statistic - 7.2) < 1e-9)
        #expect(abs(result.pValue - 0.0273) < 0.001)
    }

    /// χ² = 0.7937 on 1 df, p = 0.373 — arithmetic anyone can repeat.
    @Test("chi-square matches the hand calculation")
    func chiSquare() throws {
        let result = try StatGate.chiSquare([[10, 20], [30, 40]])
        #expect(abs(result.statistic - 0.7937) < 0.001)
        #expect(abs(result.pValue - 0.3729) < 0.001)
        #expect(result.isClean)
    }

    /// §12.3's assumption for this test: expected count ≥ 5 in every cell.
    @Test("a chi-square with thin cells is refused and sent to Fisher's exact")
    func chiSquareWithThinCells() throws {
        let result = try StatGate.chiSquare([[1, 9], [8, 2]])
        #expect(!result.isClean)
        #expect(result.warnings[0].detail.contains("ต่ำกว่า 5"))
        #expect(result.alternatives == [.fisherExact])
    }

    /// The tea-tasting table: two-sided p = 0.4857.
    @Test("Fisher's exact matches the canonical table")
    func fisherExact() throws {
        let result = try StatGate.fisherExact([[3, 1], [1, 3]])
        #expect(abs(result.pValue - 0.4857) < 0.001)
        #expect(result.isClean)
    }

    @Test("Mann–Whitney separates two groups that do not overlap")
    func mannWhitney() throws {
        let result = try StatGate.mannWhitney([1, 2, 3, 4, 5], [6, 7, 8, 9, 10])
        #expect(result.statistic == 0)
        #expect(result.pValue < 0.05)
        #expect(result.isClean)
    }

    @Test("Wilcoxon signed-rank ignores the pairs that did not change")
    func wilcoxon() throws {
        let before: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let after: [Double] = [2, 3, 4, 5, 6, 7, 8, 9, 9]   // last pair unchanged
        let result = try StatGate.wilcoxonSignedRank(before, after)
        #expect(result.summary.contains("8 คู่"))
        #expect(result.pValue < 0.05)
    }

    // MARK: - regression

    @Test("regression reports multicollinearity when two predictors are nearly the same thing")
    func multicollinearity() throws {
        let x1 = idealNormalSample(30)
        let wobble = idealNormalSample(30).shuffled()
        // Age in years and age in months, with a rounding difference between
        // them: the pair a real dataset actually contains.
        let x2 = zip(x1, wobble).map { $0 * 12 + $1 * 0.05 }
        let y = zip(x1, wobble).map { $0 * 2 + $1 * 0.3 }
        let result = try StatGate.linearRegression(y: y, predictors: [x1, x2],
                                                   names: ["อายุ", "อายุ (เดือน)"])
        let vif = try #require(result.assumptions.first { $0.name.contains("multicollinearity") })
        #expect(!vif.passed)
        #expect(vif.detail.contains("อายุ"))
        #expect((vif.statistic ?? 0) > 10)
    }

    /// Two predictors that are exactly the same line cannot be told apart at
    /// all — there is no fit to report, and inventing one is worse than saying
    /// so.
    @Test("perfectly collinear predictors are refused, not fitted")
    func perfectCollinearity() {
        let x1 = (1...20).map(Double.init)
        let x2 = x1.map { $0 * 3 }
        #expect(throws: StatError.self) {
            try StatGate.linearRegression(y: x1, predictors: [x1, x2])
        }
    }

    @Test("regression notices a curve that a straight line cannot follow")
    func curvature() throws {
        let x = (1...40).map(Double.init)
        let y = x.map { $0 * $0 }                  // a parabola, fitted with a line
        let result = try StatGate.linearRegression(y: y, predictors: [x])
        let linearity = try #require(result.assumptions.first { $0.name.contains("เส้นตรง") })
        #expect(!linearity.passed)
        #expect(!result.isClean)
    }

    @Test("a straight-line relationship passes every check")
    func cleanRegression() throws {
        let x = (1...40).map(Double.init)
        let noise = idealNormalSample(40).shuffled()
        let y = zip(x, noise).map { 2 * $0 + 5 + $1 * 2 }
        let result = try StatGate.linearRegression(y: y, predictors: [x])
        #expect(result.isClean)
        #expect(result.statistic > 0.9)             // R²
    }

    /// P19.0 — a test this module cannot run must refuse, not answer.
    ///
    /// It used to return a `StatResult` with `NaN` and an unchecked assumption:
    /// honest in content, wrong in shape. Anything shaped like a result gets
    /// rendered like one, and the row saying nothing was computed is the row a
    /// reader skims. The refusal also has to say what to do instead, or it is
    /// just a dead end.
    @Test("a test that is not implemented refuses instead of returning a result")
    func survivalRefuses() {
        #expect(throws: StatError.notImplemented(test: .survival, plannedIn: "P19.3")) {
            _ = try StatGate.survival()
        }
        let message = StatError.notImplemented(test: .survival, plannedIn: "P19.3").description
        #expect(message.contains("ยังคำนวณ"))
        #expect(message.contains("เครื่องมือภายนอก"), "the refusal does not say what to do instead")
    }

    @Test("logistic regression says out loud which assumption it cannot check")
    func logisticIsHonest() throws {
        let x = idealNormalSample(40)
        let y = x.map { $0 > 0 ? 1.0 : 0.0 }
        let result = try StatGate.logisticRegression(y: y, predictors: [x], names: ["คะแนน"])
        let logit = try #require(result.assumptions.first { $0.name.contains("logit") })
        #expect(!logit.wasChecked)
        #expect(!result.isClean)
        // Perfectly separable: the coefficient runs away, and the flag is what
        // stops anyone reading it as a strong effect.
        #expect(result.assumptions.contains { $0.name.contains("separation") && !$0.passed })
    }

    /// A predictor that does nothing should not come back looking significant,
    /// and one that does should — the Wald test per coefficient, from the same
    /// inverse the fit already produced.
    @Test("logistic regression reports an odds ratio, a CI and a p per predictor")
    func logisticReportsPerCoefficient() throws {
        // Odds double every unit of `dose`; `noise` is unrelated to the outcome.
        let dose: [Double] = (0..<60).map { Double($0 % 10) }
        let noise: [Double] = (0..<60).map { Double(($0 * 7) % 5) }
        let y: [Double] = dose.enumerated().map { index, value in
            // Deterministic but not separable: the high doses are mostly 1s,
            // the low doses mostly 0s, with overlap in the middle.
            (value >= 5 ? (index % 5 == 0 ? 0.0 : 1.0) : (index % 5 == 0 ? 1.0 : 0.0))
        }
        let result = try StatGate.logisticRegression(y: y, predictors: [dose, noise],
                                                     names: ["ขนาดยา", "ตัวแปรที่ไม่เกี่ยว"])
        #expect(result.summary.contains("ขนาดยา: OR ="))
        #expect(result.summary.contains("95% CI"))
        #expect(result.summary.contains("p = "))
        #expect(result.pValue < 0.05)              // the dose effect is real
        #expect(!result.assumptions.contains { $0.name.contains("separation") && !$0.passed })
    }

    @Test("too little data is an error, not a p-value")
    func refusesThinData() {
        #expect(throws: StatError.self) { try StatGate.twoSample([1], [2, 3]) }
        #expect(throws: StatError.self) { try StatGate.paired([1, 2], [3]) }
        #expect(throws: StatError.self) { try StatGate.chiSquare([[1, 2]]) }
    }
}
