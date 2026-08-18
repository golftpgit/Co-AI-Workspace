import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// Cross-tabulations that an ordinary χ² gets wrong (Bland, ch. 13).
//
// Two cases, both common in medicine and both silently wrong if fed to
// `chiSquare`:
//
//  • **Paired data.** The same people before and after, or matched pairs. A
//    plain χ² treats them as two independent samples, which throws away the
//    pairing and answers a question nobody asked. McNemar looks only at the
//    pairs that *changed*, because the ones that did not carry no information
//    about change.
//  • **An ordered exposure.** Dose groups, age bands, stage I–IV. A plain χ²
//    asks "are these four proportions different at all" and would give the
//    same answer if the columns were shuffled. The trend test asks the
//    question the design was built for: does the proportion move in step with
//    the ordering.
// ─────────────────────────────────────────────────────────────

public struct McNemarResult: Sendable, Equatable {
    /// Pairs that were positive before and negative after, and the reverse.
    public let changedOneWay: Int
    public let changedOtherWay: Int
    public let statistic: Double
    public let pValue: Double
    /// Whether the exact binomial was used instead of the χ² approximation.
    public let exact: Bool

    public var summary: String {
        let base = localised("pairs that went + to −: \(changedOneWay) · − to +: \(changedOtherWay)", "Counts of the pairs that changed each way. Placeholders: the two counts.")
        let test = exact
            ? String(format: localised("tested exactly (binomial) because so few pairs changed — p = %.4f", "Says the exact test was used. Placeholder: the p-value."), pValue)
            : String(format: "McNemar χ² = %.3f, p = %.4f", statistic, pValue)
        return localised("\(base) · \(test) · **pairs that did not change are not counted** because they say nothing about change", "The McNemar summary. Placeholders: the pair counts and the test result.")
    }
}

public struct TrendResult: Sendable, Equatable {
    public let statistic: Double
    public let pValue: Double
    /// The proportions, in the order given.
    public let proportions: [Double]

    public var summary: String {
        String(format: "χ² for trend = %.3f (1 df), p = %.4f", statistic, pValue)
            + localised(" · proportions in order: ", "Introduces the proportions of a trend test.")
            + proportions.map { String(format: "%.1f%%", $0 * 100) }.joined(separator: " → ")
            + localised(" · **this test asks whether the proportions run in order**, not which group differs from which ", "Warns what a trend test does and does not answer.")
            + localised("if the groups could be reordered without losing meaning, this is the wrong test", "Ends the warning about what a trend test answers.")
    }
}

public enum PairedCategorical {

    /// McNemar's test on a 2×2 table of *pairs*.
    ///
    /// - Parameters:
    ///   - bothPositive/bothNegative: the concordant pairs. Taken so the caller
    ///     cannot pass a table that does not add up, even though the test does
    ///     not use them — a function that silently ignored two of its four
    ///     numbers would invite somebody to pass an unpaired table.
    public static func mcNemar(bothPositive: Int, changedOneWay: Int,
                               changedOtherWay: Int, bothNegative: Int) throws -> McNemarResult {
        guard bothPositive >= 0, changedOneWay >= 0, changedOtherWay >= 0, bothNegative >= 0 else {
            throw StatError.badShape(localised("pair counts cannot be negative", "Why McNemar's test cannot run."))
        }
        let discordant = changedOneWay + changedOtherWay
        guard discordant > 0 else {
            throw StatError.notEnoughData(
                localised("no pair changed — there is no change to test", "Why McNemar's test cannot run."))
        }

        // Under 25 discordant pairs the χ² approximation is poor and Bland
        // says to use the exact binomial. Chosen by the data rather than by
        // the caller: a test that is right only when somebody remembers to
        // ask for it is a test that is usually wrong.
        if discordant < 25 {
            let p = Distributions.binomialTwoSided(successes: min(changedOneWay, changedOtherWay),
                                                   trials: discordant, probability: 0.5)
            return McNemarResult(changedOneWay: changedOneWay, changedOtherWay: changedOtherWay,
                                 statistic: Double(min(changedOneWay, changedOtherWay)),
                                 pValue: p, exact: true)
        }
        // Continuity-corrected, which is the form Bland gives.
        let difference = abs(Double(changedOneWay - changedOtherWay)) - 1
        let statistic = difference * difference / Double(discordant)
        return McNemarResult(changedOneWay: changedOneWay, changedOtherWay: changedOtherWay,
                             statistic: statistic,
                             pValue: Statistics.chiSquarePValue(statistic, degreesOfFreedom: 1),
                             exact: false)
    }

    /// χ² for trend across ordered groups (Cochran–Armitage).
    ///
    /// - Parameters:
    ///   - groups: cases and total per group, **in the order of the exposure**.
    ///   - scores: what the ordering is worth. Defaults to 0, 1, 2… — equal
    ///     spacing — and a caller with real doses should pass them, because
    ///     "10 mg, 20 mg, 100 mg" is not three equal steps.
    public static func trend(_ groups: [(cases: Int, total: Int)],
                             scores: [Double]? = nil) throws -> TrendResult {
        guard groups.count >= 3 else {
            throw StatError.notEnoughData(localised("a trend needs at least three groups that can be put in order", "Why a trend test cannot run."))
        }
        guard groups.allSatisfy({ $0.total > 0 && $0.cases >= 0 && $0.cases <= $0.total }) else {
            throw StatError.badShape(localised("the number of cases must be between 0 and the size of the group", "Why a trend test cannot run."))
        }
        let x = scores ?? (0..<groups.count).map(Double.init)
        guard x.count == groups.count else {
            throw StatError.badShape(localised("there must be as many ordinal scores as groups", "Why a trend test cannot run."))
        }

        let totals = groups.map { Double($0.total) }
        let cases = groups.map { Double($0.cases) }
        let n = totals.reduce(0, +)
        let r = cases.reduce(0, +)
        let overall = r / n
        guard overall > 0, overall < 1 else {
            throw StatError.notEnoughData(localised("everyone is a case, or nobody is — there is no trend to test", "Why a trend test cannot run."))
        }

        let meanScore = zip(totals, x).reduce(0) { $0 + $1.0 * $1.1 } / n
        var numerator = 0.0, denominator = 0.0
        for index in groups.indices {
            numerator += cases[index] * (x[index] - meanScore)
            denominator += totals[index] * (x[index] - meanScore) * (x[index] - meanScore)
        }
        guard denominator > 0 else {
            throw StatError.badShape(localised("every group has the same ordinal score — there is no order to follow", "Why a trend test cannot run."))
        }
        let statistic = numerator * numerator / (overall * (1 - overall) * denominator)

        return TrendResult(statistic: statistic,
                           pValue: Statistics.chiSquarePValue(statistic, degreesOfFreedom: 1),
                           proportions: zip(cases, totals).map { $0 / $1 })
    }
}
