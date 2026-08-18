import Foundation

// ─────────────────────────────────────────────────────────────
// Statistical Verification Gate (ARCHITECTURE §12.3, P6.6).
//
// §12.3 calls this a PostToolUse hook of the Analyst's: every statistical test
// gets its assumptions checked automatically, **before** the result reaches the
// supervisor's context. The shape that makes that true is not a checker you can
// call afterwards — it is that **the only way to get a test result out of this
// module is to get the assumption report with it**. `StatResult` has no
// initialiser that produces one without the other, and the tests are not
// exposed separately.
//
// The rule when a check fails is §12.3's: not "failed", but *this is the wrong
// test* — a structured warning, a named alternative, and a trip back to the
// Analysis Plan for approval, because changing the method is a change of
// methodology and not a retry (P6.7 owns the plan; this module owns the
// verdict).
//
// Three deliberate refusals:
//
//  • **An assumption we cannot check is not an assumption that passed.**
//    Proportional hazards needs a fitted Cox model, which this module does not
//    have, so it is reported as unchecked and the result is not called clean.
//  • **No silent n.** Shapiro–Wilk below n = 3, a chi-square with an empty
//    row — these come back as "could not be checked", never as a p-value.
//  • **The numbers travel with the verdict.** "not normal" with no W and no
//    p is something a reader has to take on trust, and §2.5's whole point is
//    that they should not have to.
// ─────────────────────────────────────────────────────────────

public enum StatisticalTest: String, Sendable, Codable, CaseIterable {
    case studentT
    case welchT
    case pairedT
    case oneWayANOVA
    case chiSquare
    case linearRegression
    case logisticRegression
    case survival
    // The non-parametric alternatives §12.3 asks the gate to propose. Runnable,
    // not just nameable: a gate that suggests a test the system cannot run
    // leaves the user exactly where they were.
    case mannWhitney
    case wilcoxonSignedRank
    case kruskalWallis
    case fisherExact
    /// Bland ch. 13 — paired proportions. A plain χ² on the same table throws
    /// the pairing away and answers a question nobody asked.
    case mcNemar
    /// Bland ch. 13 — an ordered exposure. A plain χ² would give the same
    /// answer with the columns shuffled.
    case chiSquareTrend
    /// Bland ch. 11–12.
    case correlation
    /// Bland ch. 20 — agreement between raters, with the chance part removed.
    case kappa
    /// §12.6.1's count models (P19.4). The negative binomial is listed as its
    /// own test rather than a mode of the Poisson because the gate proposes it
    /// *by name* when dispersion fails, and a proposal has to be runnable.
    case poissonRegression
    case negativeBinomialRegression
    /// §12.6.1's multilevel model (P19.5). Random intercepts today; the slope
    /// half refuses by name rather than approximating.
    case mixedModel

    public var label: String {
        switch self {
        case .studentT: localised("two-sample t-test (Student)", "Name of a statistical test.")
        case .welchT: localised("two-sample t-test (Welch)", "Name of a statistical test.")
        case .pairedT: "paired t-test"
        case .oneWayANOVA: localised("one-way ANOVA", "Name of a statistical test.")
        case .chiSquare: localised("chi-square", "Name of a statistical test.")
        case .linearRegression: localised("linear regression", "Name of a statistical test.")
        case .logisticRegression: localised("logistic regression", "Name of a statistical test.")
        case .survival: localised("survival analysis", "Name of a statistical test.")
        case .mixedModel: localised("multilevel model (nested data)", "Name of a statistical test.")
        case .poissonRegression: localised("Poisson regression (count data)", "Name of a statistical test.")
        case .negativeBinomialRegression: localised("negative binomial regression (overdispersed counts)", "Name of a statistical test.")
        case .mannWhitney: "Mann–Whitney U"
        case .wilcoxonSignedRank: "Wilcoxon signed-rank"
        case .kruskalWallis: "Kruskal–Wallis"
        case .fisherExact: "Fisher's exact"
        case .mcNemar: localised("McNemar (paired proportions)", "Name of a statistical test.")
        case .chiSquareTrend: localised("chi-square for trend", "Name of a statistical test.")
        case .correlation: localised("correlation (Pearson/Spearman)", "Name of a statistical test.")
        case .kappa: localised("inter-rater agreement (κ)", "Name of a statistical test.")
        }
    }

    /// Whether the test assumes a distribution. The rank tests do not, which is
    /// why they are what the gate proposes.
    public var isParametric: Bool {
        switch self {
        case .mannWhitney, .wilcoxonSignedRank, .kruskalWallis, .fisherExact: false
        // κ and the two table tests make no distributional assumption about
        // the data; the trend test assumes only that the ordering means
        // something, which is a design question rather than a distribution.
        case .mcNemar, .chiSquareTrend, .kappa: false
        case .correlation: true
        default: true
        }
    }
}

/// One assumption, and what happened when it was checked.
public struct AssumptionCheck: Sendable, Equatable, Identifiable {
    public let name: String
    /// False when the check could not be run at all — reported apart from
    /// "passed", because they are not the same thing.
    public let wasChecked: Bool
    public let passed: Bool
    public let statistic: Double?
    public let pValue: Double?
    /// What was measured and what it means, with the numbers in it.
    public let detail: String

    public var id: String { name }

    /// Something a person has to look at: a failure, or a check that could not
    /// be made.
    public var isWarning: Bool { !passed || !wasChecked }
}

public struct StatResult: Sendable {
    public let test: StatisticalTest
    public let statistic: Double
    public let pValue: Double
    public let degreesOfFreedom: Double?
    /// The estimate, where the test has one (mean difference, F, coefficients).
    public let summary: String
    public let assumptions: [AssumptionCheck]
    /// Tests to run instead, when an assumption did not hold.
    public let alternatives: [StatisticalTest]

    public var warnings: [AssumptionCheck] { assumptions.filter(\.isWarning) }

    /// The one thing callers should branch on: whether this result may be
    /// treated as an answer.
    public var isClean: Bool { warnings.isEmpty }

    /// §12.3: a failed assumption sends the work back to the Analysis Plan,
    /// because choosing a different test is a change of methodology.
    public var requiresPlanReapproval: Bool { !isClean && !alternatives.isEmpty }

    /// The structured warning, as one readable block. Written here so every
    /// surface — notebook, agent transcript, plan — says the same thing.
    public var report: String {
        var lines = ["\(test.label): \(summary)"]
        for assumption in assumptions {
            let mark = assumption.wasChecked ? (assumption.passed ? "✓" : "✗") : "?"
            lines.append("  \(mark) \(assumption.name) — \(assumption.detail)")
        }
        if !alternatives.isEmpty {
            lines.append(localised("  → assumptions not met, suggested instead: ", "Prefix before a list of alternative tests.")
                         + alternatives.map(\.label).joined(separator: localised(" or ", "Joins alternative test names."))
                         + localised(" (changing method means going back to the Analysis Plan for approval)", "Says that switching test needs re-approval."))
        }
        return lines.joined(separator: "\n")
    }
}

public enum StatError: Error, CustomStringConvertible, Equatable {
    case notEnoughData(String)
    case badShape(String)
    /// The test is in §12.3's table and this module cannot run it (P19.0).
    ///
    /// **A refusal, not a result.** The alternative shipped for a while: a
    /// `StatResult` with `NaN` for the statistic, the summary the caller passed
    /// in, and an assumption marked unchecked. Everything about that is
    /// defensible except the shape — it is the same shape a real answer has, so
    /// it renders in the same box, gets pasted into the same manuscript, and
    /// the one field that says "this was never computed" is an assumption row
    /// most people skim past. A method §12.4 pre-registered and nothing ever
    /// calculated must fail loudly at the point of use.
    case notImplemented(test: StatisticalTest, plannedIn: String)

    public var description: String {
        switch self {
        case .notEnoughData(let message): localised("Not enough data for this test: \(message)", "Refusal message. Placeholder says what is missing.")
        case .badShape(let message): localised("The data is the wrong shape: \(message)", "Refusal message. Placeholder says what is wrong.")
        case .notImplemented(let test, let planned):
            localised("This system cannot compute \(test.rawValue) itself yet (planned for \(planned)) — ", "Refusal for an unimplemented test. Placeholders: the test name and the phase it is planned for.")
                + localised("so there is no result to report · if it is needed now, compute it with an external tool ", "Continues the refusal for an unimplemented test.")
                + localised("and record where it came from; do not claim it as a result of this system", "Ends the refusal for an unimplemented test.")
        }
    }
}

public enum StatGate {

    /// The significance level every check below is judged at. One number, in
    /// one place: a gate whose thresholds differ per call is a gate whose
    /// verdicts cannot be compared.
    public static let alpha = 0.05

    // MARK: - two groups

    /// Two independent groups. Welch by default — equal variances are an
    /// assumption, and Welch is the test that does not need it.
    public static func twoSample(_ a: [Double], _ b: [Double],
                                 assumingEqualVariance: Bool = false) throws -> StatResult {
        guard a.count >= 2, b.count >= 2 else {
            throw StatError.notEnoughData(localised("at least 2 values per group are needed", "Why a test cannot run."))
        }
        let meanA = Statistics.mean(a), meanB = Statistics.mean(b)
        let varianceA = Statistics.variance(a), varianceB = Statistics.variance(b)
        let nA = Double(a.count), nB = Double(b.count)

        let t: Double
        let df: Double
        if assumingEqualVariance {
            let pooled = ((nA - 1) * varianceA + (nB - 1) * varianceB) / (nA + nB - 2)
            t = (meanA - meanB) / (pooled * (1 / nA + 1 / nB)).squareRoot()
            df = nA + nB - 2
        } else {
            let se = (varianceA / nA + varianceB / nB).squareRoot()
            t = (meanA - meanB) / se
            // Welch–Satterthwaite.
            let numerator = pow(varianceA / nA + varianceB / nB, 2)
            let denominator = pow(varianceA / nA, 2) / (nA - 1) + pow(varianceB / nB, 2) / (nB - 1)
            df = numerator / denominator
        }
        let p = Statistics.tTestPValue(t: t, degreesOfFreedom: df)

        var assumptions = [normality(of: a, named: localised("group 1", "Name of the first group in a two-sample test.")), normality(of: b, named: localised("group 2", "Name of the second group in a two-sample test."))]
        if assumingEqualVariance { assumptions.append(equalVariance([a, b])) }

        return StatResult(
            test: assumingEqualVariance ? .studentT : .welchT,
            statistic: t, pValue: p, degreesOfFreedom: df,
            summary: String(format: localised("mean %.4g vs %.4g (difference %.4g) · t = %.4f · p = %.4g", "Result of a two-sample t-test."),
                            meanA, meanB, meanA - meanB, t, p),
            assumptions: assumptions,
            alternatives: assumptions.contains(where: \.isWarning) ? [.mannWhitney] : [])
    }

    /// Paired measurements — the same subjects before and after.
    public static func paired(_ before: [Double], _ after: [Double]) throws -> StatResult {
        guard before.count == after.count else {
            throw StatError.badShape(localised("paired data must have the same number of values on both sides", "Why a test cannot run."))
        }
        guard before.count >= 2 else { throw StatError.notEnoughData(localised("at least 2 pairs are needed", "Why a test cannot run.")) }
        let differences = zip(after, before).map { $0 - $1 }
        let n = Double(differences.count)
        let meanDifference = Statistics.mean(differences)
        let se = Statistics.standardDeviation(differences) / n.squareRoot()
        let t = meanDifference / se
        let df = n - 1
        let p = Statistics.tTestPValue(t: t, degreesOfFreedom: df)
        // The assumption is about the *differences*, not about either column —
        // a detail that is wrong in a lot of published analyses.
        let assumption = normality(of: differences, named: localised("the per-pair differences", "What a normality check was run on."))
        return StatResult(
            test: .pairedT, statistic: t, pValue: p, degreesOfFreedom: df,
            summary: String(format: localised("mean difference %.4g · t = %.4f · p = %.4g", "Result of a paired t-test."),
                            meanDifference, t, p),
            assumptions: [assumption],
            alternatives: assumption.isWarning ? [.wilcoxonSignedRank] : [])
    }

    // MARK: - several groups

    public static func oneWayANOVA(_ groups: [[Double]]) throws -> StatResult {
        guard groups.count >= 2, groups.allSatisfy({ $0.count >= 2 }) else {
            throw StatError.notEnoughData(localised("at least 2 groups with 2 values each are needed", "Why a test cannot run."))
        }
        let all = groups.flatMap { $0 }
        let grandMean = Statistics.mean(all)
        let betweenSS = groups.reduce(0.0) { total, group in
            let difference = Statistics.mean(group) - grandMean
            return total + Double(group.count) * difference * difference
        }
        let withinSS = groups.reduce(0.0) { total, group in
            let average = Statistics.mean(group)
            return total + group.reduce(0) { $0 + ($1 - average) * ($1 - average) }
        }
        let d1 = Double(groups.count - 1)
        let d2 = Double(all.count - groups.count)
        let f = (betweenSS / d1) / (withinSS / d2)
        let p = Statistics.fTestPValue(f: f, d1: d1, d2: d2)

        var assumptions = groups.enumerated().map {
            normality(of: $0.element, named: localised("group \($0.offset + 1)", "Name of one group in a multi-group test. Placeholder is its number."))
        }
        assumptions.append(equalVariance(groups))

        return StatResult(
            test: .oneWayANOVA, statistic: f, pValue: p, degreesOfFreedom: d1,
            summary: String(format: "F(%.0f, %.0f) = %.4f · p = %.4g", d1, d2, f, p),
            assumptions: assumptions,
            alternatives: assumptions.contains(where: \.isWarning) ? [.kruskalWallis] : [])
    }

    // MARK: - counts

    /// Chi-square test of independence over a contingency table.
    public static func chiSquare(_ table: [[Int]]) throws -> StatResult {
        guard table.count >= 2, let width = table.first?.count, width >= 2,
              table.allSatisfy({ $0.count == width }) else {
            throw StatError.badShape(localised("the table must be at least 2×2 with rows of equal length", "Why a test cannot run."))
        }
        let rowTotals = table.map { $0.reduce(0, +) }
        let columnTotals = (0..<width).map { column in table.reduce(0) { $0 + $1[column] } }
        let total = rowTotals.reduce(0, +)
        guard total > 0 else { throw StatError.notEnoughData(localised("the table is empty", "Why a test cannot run.")) }

        var chiSquare = 0.0
        var expected: [Double] = []
        for (rowIndex, row) in table.enumerated() {
            for column in 0..<width {
                let e = Double(rowTotals[rowIndex]) * Double(columnTotals[column]) / Double(total)
                expected.append(e)
                guard e > 0 else { continue }
                let difference = Double(row[column]) - e
                chiSquare += difference * difference / e
            }
        }
        let df = Double((table.count - 1) * (width - 1))
        let p = Statistics.chiSquarePValue(chiSquare, degreesOfFreedom: df)

        // §12.3's assumption for this test, and the reason Fisher's exact
        // exists: the chi-square approximation falls apart in small cells.
        let smallest = expected.min() ?? 0
        let below5 = expected.filter { $0 < 5 }.count
        let assumption = AssumptionCheck(
            name: localised("expected count in every cell ≥ 5", "Name of a statistical assumption."),
            wasChecked: true,
            passed: below5 == 0,
            statistic: smallest,
            pValue: nil,
            detail: below5 == 0
                ? String(format: localised("the smallest expected count is %.2f", "Detail of a satisfied assumption."), smallest)
                : String(format: localised("%d cells expect fewer than 5 (smallest %.2f) — ", "Detail of a failed assumption.")
                         + localised("the chi-square approximation is not trustworthy at these counts", "Ends the failed expected-count detail."), below5, smallest))

        let isTwoByTwo = table.count == 2 && width == 2
        return StatResult(
            test: .chiSquare, statistic: chiSquare, pValue: p, degreesOfFreedom: df,
            summary: String(format: "χ²(%.0f) = %.4f · p = %.4g", df, chiSquare, p),
            assumptions: [assumption],
            alternatives: assumption.isWarning && isTwoByTwo ? [.fisherExact] : [])
    }

    /// Fisher's exact test for a 2×2 table — the answer when the expected
    /// counts are too small for chi-square. Two-sided by the usual convention:
    /// every table at least as unlikely as the observed one.
    /// Bland ch. 13 — paired proportions, through the gate so the result
    /// carries the same shape every other test's does.
    public static func mcNemar(_ table: [[Int]]) throws -> StatResult {
        guard table.count == 2, table[0].count == 2, table[1].count == 2 else {
            throw StatError.badShape(localised("McNemar takes a 2×2 table of *pairs* (before × after)", "Why a test cannot run."))
        }
        let result = try PairedCategorical.mcNemar(bothPositive: table[0][0],
                                                   changedOneWay: table[0][1],
                                                   changedOtherWay: table[1][0],
                                                   bothNegative: table[1][1])
        return StatResult(test: .mcNemar, statistic: result.statistic, pValue: result.pValue,
                          degreesOfFreedom: result.exact ? nil : 1,
                          summary: result.summary,
                          assumptions: [], alternatives: [])
    }

    /// Bland ch. 13 — proportions across an ordered exposure.
    public static func chiSquareTrend(_ groups: [(cases: Int, total: Int)],
                                      scores: [Double]? = nil) throws -> StatResult {
        let result = try PairedCategorical.trend(groups, scores: scores)
        return StatResult(test: .chiSquareTrend, statistic: result.statistic,
                          pValue: result.pValue, degreesOfFreedom: 1,
                          summary: result.summary,
                          // The one assumption worth stating: the order has to
                          // mean something. Nothing in the numbers can check
                          // it, so it is said rather than tested.
                          assumptions: [AssumptionCheck(
                            name: localised("the order of the groups is meaningful", "Name of a statistical assumption."),
                            // Nothing in the numbers can check this: it is a
                            // fact about the design. Reported as unchecked
                            // rather than as passed, which is what
                            // `wasChecked` is for.
                            wasChecked: false, passed: true,
                            statistic: nil, pValue: nil,
                            detail: localised("This test assumes the groups are ordered by a real quantity — ", "Detail of an ordinal-group assumption.")
                                + localised("if they could be shuffled without losing meaning, use an ordinary chi-square", "Ends the ordinal-group detail."))],
                          alternatives: [.chiSquare])
    }

    /// Bland ch. 11–12.
    public static func correlation(_ x: [Double], _ y: [Double],
                                   kind: Correlation.Kind = .pearson) throws -> StatResult {
        let result = try Reliability.correlation(x, y, kind: kind)
        // Pearson assumes the relationship is a straight line and both are
        // roughly Normal; Spearman does not. Reported as a check rather than
        // enforced, because a bent relationship is a finding about the data.
        var assumptions: [AssumptionCheck] = []
        if kind == .pearson {
            let spearman = try Reliability.correlation(x, y, kind: .spearman)
            let gap = abs(spearman.coefficient) - abs(result.coefficient)
            assumptions.append(AssumptionCheck(
                name: localised("the relationship is linear", "Name of a statistical assumption."),
                wasChecked: true, passed: gap < 0.1,
                statistic: spearman.coefficient, pValue: nil,
                detail: gap < 0.1
                    ? localised("Pearson and Spearman agree closely — no sign of curvature", "Detail of a satisfied linearity assumption.")
                    : String(format: localised("Spearman (%.3f) is well above Pearson (%.3f) — ", "Detail of a failed linearity assumption.")
                             + localised("the relationship is probably curved; use Spearman or describe the shape first", "Ends the failed linearity detail."),
                             spearman.coefficient, result.coefficient)))
        }
        return StatResult(test: .correlation, statistic: result.coefficient,
                          pValue: result.pValue, degreesOfFreedom: Double(result.n - 2),
                          summary: result.summary, assumptions: assumptions,
                          alternatives: assumptions.contains(where: \.isWarning) ? [.correlation] : [])
    }

    /// Bland ch. 20.
    public static func kappa(_ first: [Int], _ second: [Int],
                             ordered: Bool = false) throws -> StatResult {
        let result = try Reliability.kappa(first, second, ordered: ordered)
        return StatResult(test: .kappa, statistic: result.value, pValue: .nan,
                          degreesOfFreedom: nil, summary: result.interpretation,
                          // κ has no null hypothesis worth testing here — "is
                          // agreement better than chance" is answered by the
                          // interval, and a p-value beside it invites reading
                          // significance as agreement.
                          assumptions: [], alternatives: [])
    }

    public static func fisherExact(_ table: [[Int]]) throws -> StatResult {
        guard table.count == 2, table[0].count == 2, table[1].count == 2 else {
            throw StatError.badShape(localised("Fisher's exact here supports 2×2 tables only", "Why a test cannot run."))
        }
        let a = table[0][0], b = table[0][1], c = table[1][0], d = table[1][1]
        let rowOne = a + b, rowTwo = c + d, columnOne = a + c, total = a + b + c + d
        guard total > 0 else { throw StatError.notEnoughData(localised("the table is empty", "Why a test cannot run.")) }

        func logFactorial(_ n: Int) -> Double { lgamma(Double(n) + 1) }
        func probability(_ x: Int) -> Double {
            let y = columnOne - x
            guard x >= 0, y >= 0, rowOne - x >= 0, rowTwo - y >= 0 else { return 0 }
            return exp(logFactorial(rowOne) + logFactorial(rowTwo)
                       + logFactorial(columnOne) + logFactorial(total - columnOne)
                       - logFactorial(total) - logFactorial(x) - logFactorial(rowOne - x)
                       - logFactorial(y) - logFactorial(rowTwo - y))
        }
        let observed = probability(a)
        var p = 0.0
        for x in max(0, columnOne - rowTwo)...min(columnOne, rowOne) {
            let candidate = probability(x)
            if candidate <= observed * (1 + 1e-7) { p += candidate }
        }
        let oddsRatio = Double(a * d) / Double(max(b * c, 1))
        return StatResult(
            test: .fisherExact, statistic: oddsRatio, pValue: min(1, p), degreesOfFreedom: nil,
            summary: String(format: localised("odds ratio ≈ %.4g · p = %.4g (two-sided)", "Result of Fisher's exact test."), oddsRatio, min(1, p)),
            // Exact by construction: there is no large-sample approximation
            // here to be wrong about.
            assumptions: [AssumptionCheck(name: localised("no assumption about sample size", "Name of a statistical assumption."),
                                          wasChecked: true, passed: true,
                                          statistic: nil, pValue: nil,
                                          detail: localised("The probability is computed exactly from the table, not approximated", "Detail of Fisher's exact assumption."))],
            alternatives: [])
    }

    // MARK: - the non-parametric alternatives

    /// Mann–Whitney U, normal approximation with a tie correction. The gate's
    /// answer to a t-test on data that is not normal.
    public static func mannWhitney(_ a: [Double], _ b: [Double]) throws -> StatResult {
        guard a.count >= 2, b.count >= 2 else {
            throw StatError.notEnoughData(localised("at least 2 values per group are needed", "Why a test cannot run."))
        }
        let combined = a + b
        let ranks = Statistics.ranks(combined)
        let rankSumA = ranks.prefix(a.count).reduce(0, +)
        let nA = Double(a.count), nB = Double(b.count), n = nA + nB
        let u = rankSumA - nA * (nA + 1) / 2
        let mean = nA * nB / 2
        let ties = Statistics.tieBlocks(combined)
            .reduce(0.0) { $0 + Double($1 * $1 * $1 - $1) }
        let variance = nA * nB / 12 * ((n + 1) - ties / (n * (n - 1)))
        let z = (u - mean - (u > mean ? 0.5 : -0.5)) / variance.squareRoot()
        let p = 2 * (1 - Statistics.normalCDF(abs(z)))
        return StatResult(
            test: .mannWhitney, statistic: u, pValue: min(1, p), degreesOfFreedom: nil,
            summary: String(format: localised("U = %.1f · z = %.4f · p = %.4g (normal approximation, corrected for ties)", "Result of a Mann–Whitney test."),
                            u, z, min(1, p)),
            assumptions: [AssumptionCheck(
                name: localised("no normal distribution required", "Name of a statistical assumption."),
                wasChecked: true, passed: true, statistic: nil, pValue: nil,
                detail: localised("The test works on ranks, so it does not depend on the shape of the distribution", "Detail of a rank-based assumption."))],
            alternatives: [])
    }

    public static func wilcoxonSignedRank(_ before: [Double], _ after: [Double]) throws -> StatResult {
        guard before.count == after.count else {
            throw StatError.badShape(localised("paired data must have the same number of values on both sides", "Why a test cannot run."))
        }
        // Zero differences carry no information about direction and are
        // dropped, which is the standard treatment and changes n.
        let differences = zip(after, before).map { $0 - $1 }.filter { $0 != 0 }
        guard differences.count >= 2 else {
            throw StatError.notEnoughData(localised("at least 2 pairs with a non-zero difference are needed", "Why a test cannot run."))
        }
        let ranks = Statistics.ranks(differences.map { abs($0) })
        let positive = zip(differences, ranks).reduce(0.0) { $0 + ($1.0 > 0 ? $1.1 : 0) }
        let n = Double(differences.count)
        let mean = n * (n + 1) / 4
        let variance = n * (n + 1) * (2 * n + 1) / 24
        let z = (positive - mean) / variance.squareRoot()
        let p = 2 * (1 - Statistics.normalCDF(abs(z)))
        return StatResult(
            test: .wilcoxonSignedRank, statistic: positive, pValue: min(1, p),
            degreesOfFreedom: nil,
            summary: String(format: localised("W⁺ = %.1f · z = %.4f · p = %.4g (using %d differing pairs)", "Result of a Wilcoxon signed-rank test."),
                            positive, z, min(1, p), differences.count),
            assumptions: [AssumptionCheck(
                name: localised("no normal distribution required", "Name of a statistical assumption."),
                wasChecked: true, passed: true, statistic: nil, pValue: nil,
                detail: localised("The test works on the ranks of the differences", "Detail of a signed-rank assumption."))],
            alternatives: [])
    }

    public static func kruskalWallis(_ groups: [[Double]]) throws -> StatResult {
        guard groups.count >= 2, groups.allSatisfy({ !$0.isEmpty }) else {
            throw StatError.notEnoughData(localised("at least 2 non-empty groups are needed", "Why a test cannot run."))
        }
        let combined = groups.flatMap { $0 }
        let ranks = Statistics.ranks(combined)
        let n = Double(combined.count)
        var offset = 0
        var sum = 0.0
        for group in groups {
            let slice = ranks[offset..<(offset + group.count)]
            let rankSum = slice.reduce(0, +)
            sum += rankSum * rankSum / Double(group.count)
            offset += group.count
        }
        var h = 12 / (n * (n + 1)) * sum - 3 * (n + 1)
        let ties = Statistics.tieBlocks(combined).reduce(0.0) { $0 + Double($1 * $1 * $1 - $1) }
        if ties > 0 { h /= 1 - ties / (n * n * n - n) }
        let df = Double(groups.count - 1)
        let p = Statistics.chiSquarePValue(h, degreesOfFreedom: df)
        return StatResult(
            test: .kruskalWallis, statistic: h, pValue: p, degreesOfFreedom: df,
            summary: String(format: "H(%.0f) = %.4f · p = %.4g", df, h, p),
            assumptions: [AssumptionCheck(
                name: localised("no normal distribution required", "Name of a statistical assumption."),
                wasChecked: true, passed: true, statistic: nil, pValue: nil,
                detail: localised("The test works on ranks pooled across the groups", "Detail of a Kruskal–Wallis assumption."))],
            alternatives: [])
    }

    // MARK: - regression

    /// Linear regression, with §12.3's three checks: multicollinearity,
    /// linearity, and the residual distribution.
    public static func linearRegression(y: [Double], predictors: [[Double]],
                                        names: [String] = []) throws -> StatResult {
        guard let fit = Statistics.leastSquares(y: y, predictors: predictors) else {
            throw StatError.notEnoughData(localised("there must be more rows than variables, and the variables must not be exact duplicates", "Why a regression cannot run."))
        }
        let labels = names.count == predictors.count
            ? names : (1...max(predictors.count, 1)).map { "x\($0)" }

        var assumptions: [AssumptionCheck] = []
        assumptions.append(multicollinearity(predictors, names: labels))
        assumptions.append(linearity(fit))
        assumptions.append(normality(of: fit.residuals, named: localised("the residuals", "What a normality check was run on.")))

        let terms = zip(labels, fit.coefficients.dropFirst()).map { name, value in
            String(format: "%@ = %.4g", name, value)
        }.joined(separator: " · ")
        return StatResult(
            test: .linearRegression,
            statistic: fit.rSquared,
            // The reported p is for the model's slope terms as a whole
            // (F-test), not for any one coefficient.
            pValue: modelPValue(fit, predictorCount: predictors.count),
            degreesOfFreedom: Double(fit.degreesOfFreedom),
            summary: String(format: localised("R² = %.4f · intercept %.4g · %@", "Result of a linear regression."),
                            fit.rSquared, fit.coefficients[0], terms),
            assumptions: assumptions,
            // A curved relationship is not fixed by a different test — it is
            // fixed by a different model, which is a plan-level decision.
            alternatives: [])
    }

    /// Logistic regression. §12.3 lists multicollinearity for it too; what it
    /// does *not* get here is a linearity-of-the-logit check, and that is said
    /// out loud rather than left out.
    public static func logisticRegression(y: [Double], predictors: [[Double]],
                                          names: [String] = []) throws -> StatResult {
        guard let fit = Statistics.logistic(y: y, predictors: predictors) else {
            throw StatError.badShape(localised("the outcome must be 0/1 and there must be more rows than variables", "Why a regression cannot run."))
        }
        let labels = names.count == predictors.count
            ? names : (1...max(predictors.count, 1)).map { "x\($0)" }

        var assumptions = [multicollinearity(predictors, names: labels)]
        assumptions.append(AssumptionCheck(
            name: localised("no complete separation", "Name of a statistical assumption."),
            wasChecked: true,
            passed: !fit.separated,
            statistic: nil, pValue: nil,
            detail: fit.separated
                ? localised("Some variable predicts the outcome perfectly, so its coefficient runs off to infinity ", "Detail of a failed separation check.")
                  + localised("— the number you get is not an effect size", "Ends the failed separation detail.")
                : localised("The estimate converged in \(fit.iterations) iterations", "Detail of a satisfied separation check.")))
        assumptions.append(AssumptionCheck(
            name: localised("linearity of the logit", "Name of a statistical assumption."),
            wasChecked: false, passed: false, statistic: nil, pValue: nil,
            detail: localised("This module cannot check it yet — look at it with Box–Tidwell or a plot before trusting the result", "Detail of an unchecked assumption.")))

        // Wald test per coefficient: z = β/SE, from the same inverse the fit
        // already produced. Reported per predictor rather than as one number —
        // a model-level p-value would say nothing about which variable did the
        // work. Meaningless under separation, and said so above.
        let terms = zip(labels, zip(fit.coefficients.dropFirst(),
                                    fit.standardErrors.dropFirst()))
            .map { name, estimate in
                let (coefficient, error) = estimate
                guard error.isFinite, error > 0 else {
                    return String(format: localised("%@: OR = %.4g (p could not be computed)", "A logistic coefficient."), name, exp(coefficient))
                }
                let z = coefficient / error
                let p = 2 * (1 - Statistics.normalCDF(abs(z)))
                return String(format: "%@: OR = %.4g (95%% CI %.4g–%.4g) · p = %.4g",
                              name, exp(coefficient),
                              exp(coefficient - 1.96 * error), exp(coefficient + 1.96 * error), p)
            }
            .joined(separator: " · ")
        let leading = Array(zip(fit.coefficients.dropFirst(), fit.standardErrors.dropFirst())).first
        let leadingZ = leading.flatMap { $1.isFinite && $1 > 0 ? $0 / $1 : nil }
        return StatResult(
            test: .logisticRegression,
            statistic: fit.coefficients.dropFirst().first ?? .nan,
            pValue: leadingZ.map { 2 * (1 - Statistics.normalCDF(abs($0))) } ?? .nan,
            degreesOfFreedom: nil,
            summary: terms,
            assumptions: assumptions,
            alternatives: [])
    }

    /// A clustered comparison, with the independence assumption checked
    /// against the shape of the data (P19.5).
    ///
    /// The mean and its interval are computed **from the multilevel fit**, not
    /// from the observations as if they were independent — otherwise this would
    /// be the very analysis it warns about, with a warning attached.
    public static func clustered(_ clusters: [[Double]]) throws -> StatResult {
        let fit = try Multilevel.randomIntercept(clusters)
        let values = clusters.flatMap { $0 }
        let mean = Statistics.mean(values)
        let naiveError = (Statistics.variance(values) / Double(values.count)).squareRoot()
        let corrected = naiveError * fit.standardErrorInflation
        let z = Epidemiology.z95

        return StatResult(
            test: .mixedModel,
            statistic: mean,
            // No null hypothesis is being tested here — this is an estimate and
            // its interval. A p-value invented for it would be a p-value about
            // a question nobody asked.
            pValue: .nan,
            degreesOfFreedom: Double(fit.clusters - 1),
            summary: String(format: localised("mean %.4f (95%% CI %.4f–%.4f · corrected for clustering) ", "Result of a multilevel model.")
                            + localised("· treated as independent it would be %.4f–%.4f, which is too narrow", "Ends the multilevel result."),
                            mean, mean - z * corrected, mean + z * corrected,
                            mean - z * naiveError, mean + z * naiveError),
            assumptions: [Multilevel.independenceCheck(fit)],
            alternatives: [])
    }

    /// Counts against predictors, with the assumption Poisson makes checked
    /// and the alternative offered by name (P19.4).
    ///
    /// The failure this exists for is quiet: overdispersed counts still produce
    /// a believable coefficient, and only the standard error is wrong — too
    /// small, which turns a null effect into a finding. So the check runs every
    /// time, and when it fails the gate proposes a model it can actually run
    /// rather than a suggestion the user has to take elsewhere (§12.3).
    public static func countRegression(_ counts: [Double],
                                       predictors: [[Double]],
                                       names: [String] = []) throws -> StatResult {
        let fit = try CountModels.poisson(counts: counts, predictors: predictors)
        let dispersion = CountModels.overdispersion(counts: counts, predictors: predictors,
                                                    fit: fit)
        let terms = zip(fit.coefficients.dropFirst(), fit.standardErrors.dropFirst())
            .enumerated()
            .map { index, pair in
                let name = index < names.count ? names[index] : "x\(index + 1)"
                return String(format: localised("%@: rate ratio %.4f (SE of the log = %.4f)", "A count-model coefficient."),
                              name, exp(pair.0), pair.1)
            }
            .joined(separator: " · ")

        let leading = Array(zip(fit.coefficients.dropFirst(),
                                fit.standardErrors.dropFirst())).first
        let z = leading.flatMap { $1 > 0 ? $0 / $1 : nil }
        return StatResult(
            test: .poissonRegression,
            statistic: fit.coefficients.dropFirst().first ?? .nan,
            pValue: z.map { 2 * (1 - Statistics.normalCDF(abs($0))) } ?? .nan,
            degreesOfFreedom: nil,
            summary: terms,
            assumptions: [dispersion],
            // Named only when it is the answer: a gate that always lists every
            // other test teaches people to ignore the list.
            alternatives: dispersion.passed ? [] : [.negativeBinomialRegression])
    }

    /// Two survival curves compared, with the assumption the comparison rests
    /// on checked (P19.3).
    ///
    /// **This used to refuse, and before that it lied.** The first version
    /// returned a `StatResult` carrying `NaN` and whatever summary the caller
    /// passed in — a claim wearing a result's clothes. P19.0 made it throw. It
    /// now computes, and the throw stays for the case that has not been built:
    /// `StatError.notImplemented` is still the answer for anything in §12.3's
    /// table that this module cannot do.
    ///
    /// The log-rank test is the answer; the Cox fit is run alongside it to get
    /// the hazard ratio a paper reports and to make the proportional-hazards
    /// check possible at all — a comparison whose assumption was never tested
    /// is the thing §12.3 exists to stop.
    public static func survival(_ a: [SurvivalObservation],
                                _ b: [SurvivalObservation]) throws -> StatResult {
        let test = try Survival.logRank(a, b)
        let all = a + b
        let group = [Double](repeating: 0, count: a.count)
            + [Double](repeating: 1, count: b.count)

        // A Cox fit that will not converge does not stop the comparison: the
        // log-rank result stands on its own, and the assumption is then
        // reported as unchecked rather than as passed.
        guard let fit = try? Survival.cox(all, covariates: [group]) else {
            return StatResult(
                test: .survival, statistic: test.statistic, pValue: test.pValue,
                degreesOfFreedom: 1, summary: test.summary,
                assumptions: [AssumptionCheck(
                    name: "proportional hazards", wasChecked: false, passed: false,
                    statistic: nil, pValue: nil,
                    detail: localised("The Cox model did not converge, so the assumption could not be checked — which is not the same as passing", "Detail of an unchecked proportional-hazards assumption."))],
                alternatives: [])
        }
        let hazard = fit.hazardRatios[0]
        let interval = fit.confidenceIntervals[0]
        return StatResult(
            test: .survival,
            statistic: test.statistic,
            pValue: test.pValue,
            degreesOfFreedom: 1,
            summary: test.summary + String(format: " · HR = %.3f (95%% CI %.3f–%.3f)",
                                           hazard, interval.lower, interval.upper),
            assumptions: [Survival.proportionalHazards(all, covariates: [group], fit: fit)],
            // No alternative *test* to offer: when proportional hazards fails
            // the answer is to report by period or to let the coefficient vary
            // with time, and neither is another row in this enum. The
            // assumption's own detail says so, which is where a reader looks.
            alternatives: [])
    }

    // MARK: - the checks themselves

    static func normality(of values: [Double], named name: String) -> AssumptionCheck {
        guard let test = Statistics.shapiroWilk(values) else {
            return AssumptionCheck(
                name: localised("normal distribution of \(name)", "Name of a normality assumption. Placeholder is what was tested."),
                wasChecked: false, passed: false, statistic: nil, pValue: nil,
                detail: values.count < 3
                    ? localised("only \(values.count) values — too few to test", "Why normality could not be tested.")
                    : localised("cannot be tested (all values identical, or n above 5000)", "Why normality could not be tested."))
        }
        let passed = test.pValue >= alpha
        return AssumptionCheck(
            name: localised("normal distribution of \(name)", "Name of a normality assumption. Placeholder is what was tested."),
            wasChecked: true, passed: passed,
            statistic: test.w, pValue: test.pValue,
            detail: String(format: passed
                           ? localised("Shapiro–Wilk W = %.4f, p = %.4g — no evidence against normality", "Detail of a satisfied normality check.")
                           : localised("Shapiro–Wilk W = %.4f, p = %.4g — the data does not fit a normal distribution", "Detail of a failed normality check."),
                           test.w, test.pValue))
    }

    /// Levene's test in the Brown–Forsythe form (deviations from the median),
    /// which is the version that survives non-normal data — and non-normal data
    /// is exactly the situation this is being asked about.
    static func equalVariance(_ groups: [[Double]]) -> AssumptionCheck {
        let sizes = groups.map(\.count)
        guard groups.count >= 2, sizes.allSatisfy({ $0 >= 2 }) else {
            return AssumptionCheck(name: localised("equal variance across groups", "Name of a statistical assumption."),
                                   wasChecked: false, passed: false,
                                   statistic: nil, pValue: nil,
                                   detail: localised("at least 2 values per group are needed", "Why a test cannot run."))
        }
        let deviations = groups.map { group -> [Double] in
            let median = Statistics.median(group)
            return group.map { abs($0 - median) }
        }
        let all = deviations.flatMap { $0 }
        let grandMean = Statistics.mean(all)
        let between = deviations.reduce(0.0) { total, group in
            let difference = Statistics.mean(group) - grandMean
            return total + Double(group.count) * difference * difference
        }
        let within = deviations.reduce(0.0) { total, group in
            let average = Statistics.mean(group)
            return total + group.reduce(0) { $0 + ($1 - average) * ($1 - average) }
        }
        let d1 = Double(groups.count - 1)
        let d2 = Double(all.count - groups.count)
        guard within > 0, d2 > 0 else {
            return AssumptionCheck(name: localised("equal variance across groups", "Name of a statistical assumption."),
                                   wasChecked: false, passed: false,
                                   statistic: nil, pValue: nil,
                                   detail: localised("there is no spread within the groups, so it cannot be tested", "Why equal variance could not be tested."))
        }
        let w = (between / d1) / (within / d2)
        let p = Statistics.fTestPValue(f: w, d1: d1, d2: d2)
        let passed = p >= alpha
        let spread = groups.map { String(format: "%.4g", Statistics.variance($0)) }
            .joined(separator: ", ")
        return AssumptionCheck(
            name: localised("equal variance across groups", "Name of a statistical assumption."),
            wasChecked: true, passed: passed, statistic: w, pValue: p,
            detail: String(format: localised("Levene (Brown–Forsythe) W = %.4f, p = %.4g · variance per group: %@", "Detail of an equal-variance check."),
                           w, p, spread)
                + (passed ? "" : localised(" — use Welch instead of Student, or move to a rank-based method", "Appended when equal variance fails.")))
    }

    static func multicollinearity(_ predictors: [[Double]], names: [String]) -> AssumptionCheck {
        guard predictors.count > 1 else {
            return AssumptionCheck(name: localised("no multicollinearity", "Name of a statistical assumption."),
                                   wasChecked: true, passed: true, statistic: nil, pValue: nil,
                                   detail: localised("there is only one predictor, so nothing can be collinear", "Why multicollinearity could not arise."))
        }
        let factors = Statistics.varianceInflationFactors(predictors)
        let worst = factors.max() ?? 1
        // VIF > 10 is the conventional line; above it the coefficient of a
        // predictor is mostly telling you about the other predictors.
        let passed = worst <= 10
        let listed = zip(names, factors).map { String(format: "%@ VIF = %.2f", $0, $1) }
            .joined(separator: " · ")
        return AssumptionCheck(
            name: localised("no multicollinearity", "Name of a statistical assumption."),
            wasChecked: true, passed: passed, statistic: worst, pValue: nil,
            detail: listed + (passed ? "" : localised(" — a VIF above 10 means the variables explain each other ", "Appended when multicollinearity fails.")
                              + localised("so the individual coefficients cannot be read separately", "Ends the multicollinearity detail.")))
    }

    /// Curvature, by Tukey's idea: if the relationship is really a line, the
    /// squared fitted values have nothing left to explain in the residuals.
    static func linearity(_ fit: Statistics.RegressionFit) -> AssumptionCheck {
        let squares = fit.fitted.map { $0 * $0 }
        guard let extra = Statistics.leastSquares(y: fit.residuals, predictors: [squares]),
              extra.standardErrors.count > 1, extra.standardErrors[1] > 0 else {
            return AssumptionCheck(name: localised("the relationship is linear", "Name of a statistical assumption."),
                                   wasChecked: false, passed: false,
                                   statistic: nil, pValue: nil,
                                   detail: localised("cannot be checked with this data", "Why an assumption could not be tested."))
        }
        let t = extra.coefficients[1] / extra.standardErrors[1]
        let p = Statistics.tTestPValue(t: t, degreesOfFreedom: Double(extra.degreesOfFreedom))
        let passed = p >= alpha
        return AssumptionCheck(
            name: localised("the relationship is linear", "Name of a statistical assumption."),
            wasChecked: true, passed: passed, statistic: t, pValue: p,
            detail: String(format: "Tukey non-additivity t = %.4f, p = %.4g", t, p)
                + (passed ? localised(" — no curvature left over", "Appended when linearity holds.")
                          : localised(" — curvature remains in the residuals; a linear model is not enough", "Appended when linearity fails.")))
    }

    /// The F-test for "does this model explain anything at all".
    private static func modelPValue(_ fit: Statistics.RegressionFit,
                                    predictorCount: Int) -> Double {
        let d1 = Double(predictorCount)
        let d2 = Double(fit.degreesOfFreedom)
        guard d1 > 0, d2 > 0, fit.rSquared.isFinite, fit.rSquared < 1 else { return .nan }
        let f = (fit.rSquared / d1) / ((1 - fit.rSquared) / d2)
        return Statistics.fTestPValue(f: f, d1: d1, d2: d2)
    }
}
