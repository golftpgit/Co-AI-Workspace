import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// The measures a medical or public-health paper is written in
// (ARCHITECTURE §12.6.1, P19.1).
//
// **Every estimate carries an interval.** Not as a nicety: a bare point
// estimate is the number that gets quoted, and "risk was cut by 44%" from
// eleven events reads exactly like "risk was cut by 44%" from eleven hundred.
// The interval is what tells the two apart, so there is no way to ask this
// module for one without the other — the return type does not have that shape.
//
// The intervals are the standard analytic ones and each says which, because
// "95% CI" alone does not identify a method: Katz for the risk ratio, Woolf for
// the odds ratio, Wald for the risk difference, Wilson for a proportion (never
// Wald — at 0/20 the Wald interval is zero wide, which is not humility, it is a
// wrong answer), and the log-transformed Poisson interval for a rate.
// ─────────────────────────────────────────────────────────────

/// A number and the range it is really known to. `Sendable` and `Equatable` so
/// a result can travel to a screen and be compared in a test.
public struct Estimate: Sendable, Equatable {
    public let value: Double
    public let lower: Double
    public let upper: Double
    /// Which interval this is — "95% CI" names a level, not a method, and two
    /// methods on the same data disagree by enough to change a conclusion.
    public let method: String

    public init(value: Double, lower: Double, upper: Double, method: String) {
        self.value = value
        self.lower = lower
        self.upper = upper
        self.method = method
    }

    /// Whether the interval contains a value — the null for a ratio is 1 and
    /// for a difference is 0, and this is where "significant" is decided in
    /// epidemiology rather than by a p-value.
    public func includes(_ null: Double) -> Bool { lower <= null && null <= upper }

    public var isFinite: Bool { value.isFinite && lower.isFinite && upper.isFinite }
}

/// The table every measure below is computed from.
///
/// Named by what the cells are rather than a, b, c, d: transposing a 2×2 is the
/// single easiest way to invert a conclusion, and `exposedCases` cannot be put
/// where `unexposedCases` goes without somebody noticing.
public struct TwoByTwo: Sendable, Equatable {
    public let exposedCases: Int
    public let exposedNonCases: Int
    public let unexposedCases: Int
    public let unexposedNonCases: Int

    public init(exposedCases: Int, exposedNonCases: Int,
                unexposedCases: Int, unexposedNonCases: Int) {
        self.exposedCases = exposedCases
        self.exposedNonCases = exposedNonCases
        self.unexposedCases = unexposedCases
        self.unexposedNonCases = unexposedNonCases
    }

    public var exposedTotal: Int { exposedCases + exposedNonCases }
    public var unexposedTotal: Int { unexposedCases + unexposedNonCases }
    public var riskExposed: Double { Double(exposedCases) / Double(exposedTotal) }
    public var riskUnexposed: Double { Double(unexposedCases) / Double(unexposedTotal) }

    /// Whether any cell is zero, which is what makes the log-based intervals
    /// undefined. Reported rather than silently patched: adding 0.5 to every
    /// cell is a real and defensible correction, and doing it without saying so
    /// changes the estimate the reader thinks they are looking at.
    public var hasEmptyCell: Bool {
        [exposedCases, exposedNonCases, unexposedCases, unexposedNonCases].contains(0)
    }
}

public enum Epidemiology {
    /// 1.959963985… — the two-sided 95% normal quantile, from the same function
    /// every other interval in this codebase uses rather than typed as 1.96.
    static let z95 = Statistics.normalQuantile(0.975)

    // MARK: - comparing two groups

    /// Risk ratio with the Katz log interval.
    ///
    /// Undefined when a cell is empty, and that is returned as a refusal rather
    /// than as an infinite interval: a paper reporting "RR 3.2 (95% CI 0–∞)" has
    /// reported nothing, and the reader has to notice that themselves.
    public static func riskRatio(_ table: TwoByTwo) throws -> Estimate {
        try requireCounts(table)
        guard table.unexposedCases > 0, table.exposedCases > 0 else {
            throw StatError.notEnoughData(
                localised("a cell is zero — the log interval for a risk ratio cannot be computed", "Why a risk ratio cannot be reported."))
        }
        let ratio = table.riskExposed / table.riskUnexposed
        // Katz: SE(ln RR) = √(1/a − 1/(a+b) + 1/c − 1/(c+d))
        let se = (1 / Double(table.exposedCases) - 1 / Double(table.exposedTotal)
                  + 1 / Double(table.unexposedCases) - 1 / Double(table.unexposedTotal))
            .squareRoot()
        let halfWidth = z95 * se
        return Estimate(value: ratio,
                        lower: ratio * exp(-halfWidth),
                        upper: ratio * exp(halfWidth),
                        method: "Katz (log) 95% CI")
    }

    /// Odds ratio with Woolf's log interval — the measure a case–control study
    /// can produce and a risk ratio cannot, because the sampling fixed the
    /// number of cases.
    public static func oddsRatio(_ table: TwoByTwo) throws -> Estimate {
        try requireCounts(table)
        guard !table.hasEmptyCell else {
            throw StatError.notEnoughData(
                localised("a cell is zero — Woolf's odds ratio cannot be computed until a continuity correction has been decided on", "Why an odds ratio cannot be reported."))
        }
        let ratio = (Double(table.exposedCases) * Double(table.unexposedNonCases))
            / (Double(table.exposedNonCases) * Double(table.unexposedCases))
        let se = (1 / Double(table.exposedCases) + 1 / Double(table.exposedNonCases)
                  + 1 / Double(table.unexposedCases) + 1 / Double(table.unexposedNonCases))
            .squareRoot()
        let halfWidth = z95 * se
        return Estimate(value: ratio,
                        lower: ratio * exp(-halfWidth),
                        upper: ratio * exp(halfWidth),
                        method: "Woolf (log) 95% CI")
    }

    /// Risk difference — the measure that carries the size of the effect in the
    /// units a person is treated in, which a ratio never does.
    public static func riskDifference(_ table: TwoByTwo) throws -> Estimate {
        try requireCounts(table)
        let difference = table.riskExposed - table.riskUnexposed
        let se = (table.riskExposed * (1 - table.riskExposed) / Double(table.exposedTotal)
                  + table.riskUnexposed * (1 - table.riskUnexposed) / Double(table.unexposedTotal))
            .squareRoot()
        let halfWidth = z95 * se
        return Estimate(value: difference,
                        lower: difference - halfWidth,
                        upper: difference + halfWidth,
                        method: "Wald 95% CI")
    }

    /// Number needed to treat: 1/|risk difference|, with the interval inverted
    /// from the risk difference's.
    ///
    /// **Refused when the risk-difference interval crosses zero**, which is the
    /// one thing about NNT that is reliably reported wrongly. The inverted
    /// interval there is not an interval at all — it is two rays with a hole in
    /// the middle (NNT 25 to ∞, then NNH ∞ to 40), and printing "NNT 25 (95% CI
    /// 25 to 40)" out of it says the opposite of what the data support.
    public static func numberNeededToTreat(_ table: TwoByTwo) throws -> Estimate {
        let difference = try riskDifference(table)
        guard difference.value != 0 else {
            throw StatError.notEnoughData(localised("the risk difference is zero — the number needed to treat is infinite", "Why the number needed to treat cannot be reported."))
        }
        guard !difference.includes(0) else {
            throw StatError.notEnoughData(
                localised("the interval around the risk difference crosses zero — ", "Why the number needed to treat cannot be reported.")
                    + localised("inverting it does not give one continuous interval, so it cannot be reported as a number needed to treat", "Ends the explanation of why the number needed to treat cannot be reported."))
        }
        // Reported as a count of people, which is a positive number, with the
        // direction in the name: a negative "NNT" is the kind of value whose
        // minus sign goes missing between a table and a sentence, and NNT and
        // NNH mean opposite things to a reader.
        let harms = difference.value > 0
        let ends = [abs(1 / difference.lower), abs(1 / difference.upper)].sorted()
        return Estimate(value: abs(1 / difference.value),
                        lower: ends[0], upper: ends[1],
                        method: harms
                            ? localised("NNH — how many must be exposed for one extra person to be harmed · ", "Label for the number needed to harm.")
                                + localised("inverted from the Wald 95% CI of the risk difference", "How the interval around a number needed to treat or harm was obtained.")
                            : localised("NNT — how many must be treated to prevent one case · ", "Label for the number needed to treat.")
                                + localised("inverted from the Wald 95% CI of the risk difference", "How the interval around a number needed to treat or harm was obtained."))
    }

    // MARK: - one group

    /// A proportion with the Wilson score interval.
    ///
    /// Wilson rather than Wald, and this is not a preference: at 0 of 20 the
    /// Wald interval is [0, 0] — a claim of perfect certainty from twenty
    /// observations. Wilson gives [0, 0.161], which is what twenty
    /// observations actually support.
    public static func prevalence(cases: Int, population: Int) throws -> Estimate {
        guard population > 0 else { throw StatError.notEnoughData(localised("the population is zero", "Why a rate cannot be computed.")) }
        guard cases >= 0, cases <= population else {
            throw StatError.badShape(localised("the number of cases must be between 0 and the size of the population", "Why a rate cannot be computed."))
        }
        return wilson(successes: cases, trials: population)
    }

    /// Wilson score interval, exposed because sensitivity, specificity and
    /// every other proportion on a screen needs the same one (P19.2).
    public static func wilson(successes: Int, trials: Int) -> Estimate {
        let n = Double(trials)
        let proportion = Double(successes) / n
        let z = z95
        let denominator = 1 + z * z / n
        let centre = (proportion + z * z / (2 * n)) / denominator
        let spread = z * ((proportion * (1 - proportion) / n
                           + z * z / (4 * n * n)).squareRoot()) / denominator
        return Estimate(value: proportion,
                        lower: max(0, centre - spread),
                        upper: min(1, centre + spread),
                        method: "Wilson score 95% CI")
    }

    /// An incidence rate per unit of person-time, with the log interval.
    ///
    /// - Parameter personTime: in whatever unit the rate is to be reported in —
    ///   person-years, person-days. Not converted here: a rate whose
    ///   denominator the caller and the screen disagree about is the classic
    ///   way an incidence becomes a hundred times what it is.
    public static func incidenceRate(cases: Int, personTime: Double) throws -> Estimate {
        guard personTime > 0 else { throw StatError.notEnoughData(localised("person-time must be greater than zero", "Why a rate cannot be computed.")) }
        guard cases > 0 else {
            throw StatError.notEnoughData(
                localised("there were no events — the rate is zero and a log interval cannot be computed", "Why a rate cannot be reported with an interval."))
        }
        let rate = Double(cases) / personTime
        // SE(ln rate) = 1/√cases — the count carries all the uncertainty.
        let halfWidth = z95 / Double(cases).squareRoot()
        return Estimate(value: rate,
                        lower: rate * exp(-halfWidth),
                        upper: rate * exp(halfWidth),
                        method: "Poisson (log) 95% CI")
    }

    // MARK: - comparing populations that are not the same age

    /// One age band of a population being standardised.
    public struct Stratum: Sendable, Equatable {
        public let cases: Int
        public let personTime: Double
        /// The standard population's size in this band. Any consistent units —
        /// what matters is the proportions between bands.
        public let standardWeight: Double

        public init(cases: Int, personTime: Double, standardWeight: Double) {
            self.cases = cases
            self.personTime = personTime
            self.standardWeight = standardWeight
        }
    }

    /// Directly standardised rate: what this population's rate would be if it
    /// had the standard population's age structure.
    ///
    /// The measure that makes two populations comparable at all — a district
    /// full of retirees has more cancer than a university town for reasons that
    /// have nothing to do with either place, and a crude rate cannot say so.
    public static func ageStandardisedRate(_ strata: [Stratum]) throws -> Estimate {
        guard !strata.isEmpty else { throw StatError.notEnoughData(localised("there are no age strata", "Why an age-standardised rate cannot be computed.")) }
        guard strata.allSatisfy({ $0.personTime > 0 }) else {
            throw StatError.notEnoughData(localised("every stratum must have person-time greater than zero", "Why an age-standardised rate cannot be computed."))
        }
        let totalWeight = strata.reduce(0) { $0 + $1.standardWeight }
        guard totalWeight > 0 else { throw StatError.badShape(localised("the standard population weights add up to zero", "Why an age-standardised rate cannot be computed.")) }

        var rate = 0.0
        var variance = 0.0
        for stratum in strata {
            let share = stratum.standardWeight / totalWeight
            let stratumRate = Double(stratum.cases) / stratum.personTime
            rate += share * stratumRate
            // Var(rate) within a stratum is cases / personTime², because the
            // count is the Poisson part and the person-time is fixed.
            variance += share * share * Double(stratum.cases)
                / (stratum.personTime * stratum.personTime)
        }
        let halfWidth = z95 * variance.squareRoot()
        return Estimate(value: rate,
                        lower: max(0, rate - halfWidth),
                        upper: rate + halfWidth,
                        method: "direct standardisation, normal 95% CI")
    }

    // MARK: -

    private static func requireCounts(_ table: TwoByTwo) throws {
        guard table.exposedTotal > 0, table.unexposedTotal > 0 else {
            throw StatError.notEnoughData(localised("one of the groups has nobody in it", "Why a measure cannot be computed."))
        }
        guard table.exposedCases >= 0, table.exposedNonCases >= 0,
              table.unexposedCases >= 0, table.unexposedNonCases >= 0 else {
            throw StatError.badShape(localised("a count is negative", "Why a measure cannot be computed."))
        }
    }
}
