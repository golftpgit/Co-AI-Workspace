import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// Construct validity — does the instrument measure the things it claims to
// measure, in the shape it claims? (ARCHITECTURE §20.4, P11.3)
//
// Content validity (IOC/CVI) is asked *before* fieldwork and answered by
// experts. This is the other half, asked *after*: given the answers that came
// back, do the items that were written for one construct actually move
// together, and separately from the items written for another?
//
// Three deliberate differences from the way a statistics package usually
// answers that:
//
//  • **Nothing here is a gate.** EFA runs after data collection, so refusing to
//    publish on it would refuse an instrument that has already been used. It
//    reports, and the researcher writes the chapter.
//  • **The factor count is not decided silently.** Kaiser's rule (eigenvalue >
//    1) over-extracts and is still the default in most software; parallel
//    analysis is the better-supported rule and is nobody's default. Both are
//    computed, both are reported, and the one that was used is on the result.
//  • **The declared structure is compared to the found one.** The instrument
//    already says which construct each item belongs to (§20.3), so the question
//    a researcher actually has — "did my items land where I said they would" —
//    can be answered instead of left as an exercise with a loading table.
//
// CFA/SEM stays out, as §20.4 says in as many words: it needs a maximum
// likelihood estimator with fit indices, and half a confirmatory analysis is
// worse than an honest gap.
//
// Checked against structures whose answer is known without computing it —
// an equicorrelation matrix, and generated data with a planted two-factor
// structure — because a factor analysis that is quietly wrong (risk R12) is
// wrong in a table that goes in a thesis.
// ─────────────────────────────────────────────────────────────

public enum FactorAnalysisError: Error, CustomStringConvertible, Equatable {
    case tooFewItems(Int)
    case tooFewRespondents(respondents: Int, items: Int)
    case raggedData
    case constantItems([String])
    case singularCorrelation(String)
    case extractionFailed(String)

    public var description: String {
        switch self {
        case .tooFewItems(let count):
            localised("factor analysis needs at least \(ExploratoryFactorAnalysis.minimumItems) items (there are \(count)) — ", "Why a factor analysis cannot run. Placeholders: the minimum and the actual item count.")
                + localised("the structure of two items is a correlation, not a factor", "Ends the reason a factor analysis cannot run.")
        case .tooFewRespondents(let respondents, let items):
            localised("\(respondents) respondents against \(items) items — there must be more respondents than items ", "Why a factor analysis cannot run. Placeholders: respondent and item counts.")
                + localised("otherwise the correlation matrix is singular by construction, and every number out of it is an artefact of the sample size", "Ends the reason a factor analysis cannot run.")
        case .raggedData:
            localised("the rows do not all have the same number of items", "Why a factor analysis cannot run.")
        case .constantItems(let items):
            localised("everyone answered these items identically, so there is no variance to analyse: ", "Why a factor analysis cannot run.")
                + items.joined(separator: ", ")
        case .singularCorrelation(let detail):
            localised("the correlation matrix cannot be inverted — \(detail)", "Why a factor analysis cannot run. Placeholder: the underlying reason.")
        case .extractionFailed(let detail):
            localised("factor extraction failed — \(detail)", "Why a factor analysis cannot run. Placeholder: the underlying reason.")
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Is this data worth factoring at all?
// ─────────────────────────────────────────────────────────────

/// KMO, per-item MSA, and Bartlett's test of sphericity — the two checks that
/// come before a factor solution and are routinely reported beside it.
public struct SamplingAdequacy: Sendable, Equatable {
    /// Kaiser–Meyer–Olkin, over the whole matrix.
    public let kmo: Double
    /// Per-item measure of sampling adequacy, keyed by item id. The number that
    /// says *which* item to consider dropping when KMO is low.
    public let perItem: [String: Double]
    /// Bartlett's χ², testing R against an identity matrix. Non-significant means
    /// the items are unrelated and there is nothing to factor.
    public let bartlettChiSquare: Double
    public let bartlettDegreesOfFreedom: Double
    public let bartlettPValue: Double
    public let respondents: Int
    public let items: Int

    /// Kaiser's own labels for KMO, quoted rather than turned into a threshold
    /// because that is how they are reported.
    public var kmoLabel: String {
        switch kmo {
        case ..<0.50: localised("unacceptable", "KMO band.")
        case ..<0.60: localised("miserable", "KMO band.")
        case ..<0.70: localised("mediocre", "KMO band.")
        case ..<0.80: localised("middling", "KMO band.")
        case ..<0.90: localised("meritorious", "KMO band.")
        default: localised("marvellous", "KMO band.")
        }
    }

    /// The one line that decides whether a factor solution below is worth
    /// reading: KMO ≥ 0.50 (Kaiser's floor) and Bartlett significant at .05.
    public var isFactorable: Bool { kmo >= 0.50 && bartlettPValue < 0.05 }

    /// Items whose own MSA is below Kaiser's floor — candidates to drop and
    /// re-run, which is the standard move and the one a table of numbers alone
    /// does not suggest.
    public var weakItems: [String] {
        perItem.filter { $0.value < 0.50 }.keys.sorted()
    }

    public var summary: String {
        var parts = [String(format: "KMO %.3f (%@)", kmo, kmoLabel),
                     String(format: "Bartlett χ²(%.0f) = %.1f, p %@",
                            bartlettDegreesOfFreedom, bartlettChiSquare,
                            bartlettPValue < 0.001 ? "< .001"
                                : String(format: "= %.3f", bartlettPValue))]
        if !isFactorable {
            parts.append(kmo < 0.50
                         ? localised("this data is not yet suitable for factor analysis", "Verdict on sampling adequacy.")
                         : localised("Bartlett's test is not significant — the items are not related enough to share a factor", "Why the data is unsuitable for factor analysis."))
        }
        if !weakItems.isEmpty {
            parts.append(localised("items with an MSA below .50: \(weakItems.joined(separator: ", "))",
                                   "Lists items with poor sampling adequacy. Placeholder: the item names."))
        }
        return parts.joined(separator: " · ")
    }
}

// ─────────────────────────────────────────────────────────────
// The solution
// ─────────────────────────────────────────────────────────────

/// How many factors to keep. Named on the result, because "how many factors"
/// is the decision a reader of a methods section most wants to see justified.
public enum RetentionRule: Sendable, Equatable, CustomStringConvertible {
    /// Eigenvalue > 1 on the unreduced correlation matrix. The most common rule
    /// and the most criticised: it over-extracts, roughly one spurious factor
    /// per five items.
    case kaiser
    /// Horn's parallel analysis at the 95th percentile of random-data
    /// eigenvalues (Glorfeld's refinement). The rule with the best recovery
    /// record in simulation studies.
    case parallelAnalysis
    /// The researcher said so — theory, or a published instrument being
    /// replicated. Recorded as a decision rather than treated as data.
    case fixed(Int)

    public var description: String {
        switch self {
        case .kaiser: localised("Kaiser's criterion (eigenvalue > 1)", "How the number of factors was chosen.")
        case .parallelAnalysis: localised("parallel analysis (95th percentile of random data)", "How the number of factors was chosen.")
        case .fixed(let count): localised("fixed at \(count) factors", "How the number of factors was chosen. Placeholder: the count.")
        }
    }
}

/// One item's row of the rotated loading table.
public struct FactorLoading: Sendable, Equatable, Identifiable {
    public let itemID: String
    /// One loading per retained factor, after rotation.
    public let loadings: [Double]
    /// How much of this item's variance the retained factors account for.
    public let communality: Double

    public var id: String { itemID }
    public var uniqueness: Double { 1 - communality }

    /// Tabachnick & Fidell's cut: |loading| ≥ .32 is about 10% shared variance,
    /// which is the lowest most methods sections will call an item "loading on"
    /// a factor.
    public static let salient = 0.32

    /// The factor this item belongs to, or `nil` when it loads on none of them
    /// — an item that measures nothing the instrument found.
    public var primaryFactor: Int? {
        guard let best = loadings.indices.max(by: { abs(loadings[$0]) < abs(loadings[$1]) }),
              abs(loadings[best]) >= Self.salient else { return nil }
        return best
    }

    /// Loads on more than one factor. Not a defect by itself — it is a fact
    /// about the item that has to be reported and usually decided about.
    public var crossLoads: Bool {
        loadings.count { abs($0) >= Self.salient } > 1
    }
}

/// A finished exploratory factor analysis.
public struct FactorSolution: Sendable, Equatable {
    public let adequacy: SamplingAdequacy
    /// All p eigenvalues of the unreduced correlation matrix, descending — the
    /// scree plot, as numbers.
    public let eigenvalues: [Double]
    public let retained: Int
    public let rule: RetentionRule
    /// What each rule would have kept. Both are reported even when only one was
    /// used, because a solution that changes with the rule is a finding.
    public let kaiserSuggests: Int
    public let parallelSuggests: Int
    /// Proportion of total variance each retained factor accounts for after
    /// rotation, and the total.
    public let varianceExplained: [Double]
    public let loadings: [FactorLoading]
    /// Items whose communality ran into the ceiling during extraction — a
    /// Heywood case, which means the solution is improper and the loadings for
    /// those items should not be interpreted as they stand.
    public let heywoodItems: [String]
    public let iterations: Int
    public let converged: Bool
    /// How much the communalities were still moving when extraction stopped —
    /// reported with `converged` so that "it stopped early" carries a size.
    public let convergenceGap: Double
    public let respondents: Int

    public var cumulativeVariance: Double { varianceExplained.reduce(0, +) }

    /// Items that landed on no factor at all.
    public var unplacedItems: [String] {
        loadings.filter { $0.primaryFactor == nil }.map(\.itemID)
    }

    public var crossLoadingItems: [String] {
        loadings.filter(\.crossLoads).map(\.itemID)
    }

    /// The item ids on each retained factor, strongest first — the shape a
    /// methods section names its factors from.
    public func items(onFactor factor: Int) -> [String] {
        loadings.filter { $0.primaryFactor == factor }
            .sorted { abs($0.loadings[factor]) > abs($1.loadings[factor]) }
            .map(\.itemID)
    }

    /// Everything that should stand next to the table rather than be discovered
    /// by whoever reads it closely.
    public var warnings: [String] {
        var found: [String] = []
        let ratio = Double(respondents) / Double(loadings.count)
        if respondents < 100 {
            found.append(localised("\(respondents) respondents — under the 100 most textbooks give as a floor ", "Warning about sample size. Placeholder: the respondent count.")
                         + localised("the result is not stable enough to conclude a structure from", "Ends the sample-size warning."))
        }
        if ratio < 5 {
            found.append(String(format: localised("a respondent-to-item ratio of %.1f:1 — below 5:1", "Warning about sample size. Placeholder: the ratio."), ratio))
        }
        if !converged {
            found.append(String(format: localised("extraction did not converge in %d iterations — the communalities were still moving by %.4f ", "Warning that extraction stopped early. Placeholders: the iteration count and the remaining movement.")
                                + localised("per iteration when it stopped, so the figures below are where it was cut off", "Ends the non-convergence warning."),
                                iterations, convergenceGap))
        }
        if !heywoodItems.isEmpty {
            found.append(localised("a Heywood case at \(heywoodItems.joined(separator: ", "))",
                                   "Warns of a communality above 1. Placeholder: the item names.")
                         + localised(" — a communality above 1 is mathematically impossible, so either the number of factors or the sample size does not fit the data", "Ends the Heywood-case warning."))
        }
        if kaiserSuggests != parallelSuggests {
            found.append(localised("the two criteria disagree on how many factors there are (Kaiser \(kaiserSuggests) · ", "Warns that the factor-count criteria disagree. Placeholder: Kaiser's answer.")
                         + localised("parallel analysis \(parallelSuggests)) — one has to be chosen, and the choice explained", "Ends the disagreement warning. Placeholder: parallel analysis's answer."))
        }
        if !unplacedItems.isEmpty {
            found.append(localised("items that load on no factor at all: \(unplacedItems.joined(separator: ", "))",
                                   "Lists items with no factor loading. Placeholder: the item names."))
        }
        if !crossLoadingItems.isEmpty {
            found.append(localised("items that load on more than one factor: \(crossLoadingItems.joined(separator: ", "))",
                                   "Lists cross-loading items. Placeholder: the item names."))
        }
        return found
    }

    public var summary: String {
        String(format: localised("%d factors (%@) · %.1f%% of the variance explained · %d items · %d respondents", "Summary of a factor analysis. Placeholders: factor count, how they were chosen, variance explained, item count and respondent count."),
               retained, rule.description, cumulativeVariance * 100,
               loadings.count, respondents)
    }
}

// ─────────────────────────────────────────────────────────────
// The analysis
// ─────────────────────────────────────────────────────────────

public enum ExploratoryFactorAnalysis {

    /// Below this there is no structure to find — two items have a correlation,
    /// not a factor.
    public static let minimumItems = 3

    /// Runs the whole thing on a respondents × items matrix.
    ///
    /// `rule` decides how many factors are kept; whichever is chosen, both rules
    /// are computed and reported so a reader can see whether the answer depended
    /// on the choice.
    public static func analyse(scores: [[Double]], itemIDs: [String],
                               rule: RetentionRule = .parallelAnalysis) throws -> FactorSolution {
        let items = itemIDs.count
        guard items >= minimumItems else { throw FactorAnalysisError.tooFewItems(items) }
        guard scores.allSatisfy({ $0.count == items }) else {
            throw FactorAnalysisError.raggedData
        }
        let respondents = scores.count
        guard respondents > items else {
            throw FactorAnalysisError.tooFewRespondents(respondents: respondents, items: items)
        }

        let correlation = try correlationMatrix(scores, itemIDs: itemIDs)
        let eigen: SymmetricEigen
        do {
            eigen = try SymmetricEigen.of(correlation)
        } catch {
            throw FactorAnalysisError.extractionFailed("\(error)")
        }
        let inverse: [[Double]]
        do {
            inverse = try eigen.inverse()
        } catch {
            throw FactorAnalysisError.singularCorrelation("\(error)")
        }

        let adequacy = samplingAdequacy(correlation: correlation, inverse: inverse,
                                        eigen: eigen, itemIDs: itemIDs,
                                        respondents: respondents)

        let kaiser = eigen.values.count { $0 > 1 }
        let parallel = parallelAnalysisCount(observed: eigen.values,
                                             respondents: respondents, items: items)
        let retained: Int
        switch rule {
        case .kaiser: retained = kaiser
        case .parallelAnalysis: retained = parallel
        case .fixed(let count): retained = count
        }
        guard retained >= 1, retained < items else {
            throw FactorAnalysisError.extractionFailed(
                retained < 1
                    ? localised("the chosen criterion gives 0 factors — nothing shared rises above the level of random data", "Why a factor analysis produced nothing.")
                    : localised("\(retained) factors were asked for from \(items) items — there must be fewer factors than items", "Why a factor analysis cannot run. Placeholders: the factor and item counts."))
        }

        // Squared multiple correlations, the standard starting communalities for
        // principal axis factoring: how much of each item is already predictable
        // from all the others.
        let smc = (0..<items).map { index in
            min(max(1 - 1 / inverse[index][index], 0), communalityCeiling)
        }
        let extraction = principalAxis(correlation: correlation, communalities: smc,
                                       factors: retained)
        let rotated = retained > 1 ? varimax(extraction.loadings) : extraction.loadings

        // Factors come out of extraction in variance order; rotation redistributes
        // variance between them, so the order is re-established afterwards or the
        // "first factor" in the table is not the largest one.
        let ordered = orderByVariance(rotated, factors: retained)

        var rows: [FactorLoading] = []
        var heywood: [String] = []
        for (index, itemID) in itemIDs.enumerated() {
            let row = ordered[index]
            let communality = row.reduce(0) { $0 + $1 * $1 }
            if extraction.communalities[index] >= communalityCeiling - 1e-9 {
                heywood.append(itemID)
            }
            rows.append(FactorLoading(itemID: itemID, loadings: row, communality: communality))
        }

        let variance = (0..<retained).map { factor in
            ordered.reduce(0) { $0 + $1[factor] * $1[factor] } / Double(items)
        }

        return FactorSolution(adequacy: adequacy, eigenvalues: eigen.values,
                              retained: retained, rule: rule,
                              kaiserSuggests: kaiser, parallelSuggests: parallel,
                              varianceExplained: variance, loadings: rows,
                              heywoodItems: heywood, iterations: extraction.iterations,
                              converged: extraction.converged,
                              convergenceGap: extraction.residual,
                              respondents: respondents)
    }

    // MARK: - the pieces

    /// A communality of exactly 1 makes the item's uniqueness zero and the next
    /// iteration undefined. The ceiling is where an improper solution is caught
    /// and named (a Heywood case) rather than where it is hidden.
    static let communalityCeiling = 0.998

    /// Pearson correlations between every pair of columns.
    static func correlationMatrix(_ scores: [[Double]],
                                  itemIDs: [String]) throws -> [[Double]] {
        let items = itemIDs.count
        let respondents = Double(scores.count)
        let means = (0..<items).map { column in
            scores.reduce(0) { $0 + $1[column] } / respondents
        }
        let deviations = (0..<items).map { column in
            scores.map { $0[column] - means[column] }
        }
        let norms = deviations.map { column in
            column.reduce(0) { $0 + $1 * $1 }.squareRoot()
        }
        let constant = itemIDs.indices.filter { norms[$0] <= 0 }.map { itemIDs[$0] }
        guard constant.isEmpty else { throw FactorAnalysisError.constantItems(constant) }

        var matrix = [[Double]](repeating: [Double](repeating: 0, count: items), count: items)
        for row in 0..<items {
            matrix[row][row] = 1
            for column in (row + 1)..<items {
                let product = zip(deviations[row], deviations[column])
                    .reduce(0) { $0 + $1.0 * $1.1 }
                let value = product / (norms[row] * norms[column])
                matrix[row][column] = value
                matrix[column][row] = value
            }
        }
        return matrix
    }

    static func samplingAdequacy(correlation: [[Double]], inverse: [[Double]],
                                 eigen: SymmetricEigen, itemIDs: [String],
                                 respondents: Int) -> SamplingAdequacy {
        let items = itemIDs.count
        // Partial correlation, controlling for every other item: what is left of
        // r_jk once the rest of the instrument is held constant. KMO is the share
        // of correlation that survives being partialled out — near zero means the
        // pairs are held together by something common, which is what a factor is.
        var partial = [[Double]](repeating: [Double](repeating: 0, count: items), count: items)
        for row in 0..<items {
            for column in 0..<items where row != column {
                partial[row][column] = -inverse[row][column]
                    / (inverse[row][row] * inverse[column][column]).squareRoot()
            }
        }

        var correlationSum = 0.0
        var partialSum = 0.0
        var perItem: [String: Double] = [:]
        for row in 0..<items {
            var rowCorrelation = 0.0
            var rowPartial = 0.0
            for column in 0..<items where row != column {
                rowCorrelation += correlation[row][column] * correlation[row][column]
                rowPartial += partial[row][column] * partial[row][column]
            }
            correlationSum += rowCorrelation
            partialSum += rowPartial
            let denominator = rowCorrelation + rowPartial
            perItem[itemIDs[row]] = denominator > 0 ? rowCorrelation / denominator : 0
        }
        let kmo = (correlationSum + partialSum) > 0
            ? correlationSum / (correlationSum + partialSum) : 0

        // Bartlett (1951): −[(n−1) − (2p+5)/6] · ln|R| against χ² with p(p−1)/2 df.
        let n = Double(respondents)
        let p = Double(items)
        let determinant = max(eigen.determinant, Double.leastNormalMagnitude)
        let chiSquare = max(-(n - 1 - (2 * p + 5) / 6) * log(determinant), 0)
        let df = p * (p - 1) / 2
        return SamplingAdequacy(
            kmo: kmo, perItem: perItem,
            bartlettChiSquare: chiSquare, bartlettDegreesOfFreedom: df,
            bartlettPValue: Distributions.chiSquarePValue(chiSquare, degreesOfFreedom: df),
            respondents: respondents, items: items)
    }

    struct Extraction {
        let loadings: [[Double]]
        let communalities: [Double]
        let iterations: Int
        let converged: Bool
        /// How much the communalities were still moving when it stopped. Kept so
        /// that "did not converge" can be reported with a size: a run that halted
        /// while the numbers were moving by 0.002 is a different statement from
        /// one still moving by 0.3, and only one of them makes the loadings
        /// unusable.
        let residual: Double
    }

    /// Principal axis factoring: put the communalities on the diagonal, take the
    /// leading eigenvectors of *that*, recompute the communalities from the
    /// loadings, repeat.
    ///
    /// Principal axis rather than principal components, because they answer
    /// different questions and only one of them is factor analysis: components
    /// summarise all the variance including each item's own noise, factors model
    /// only what the items share. A scale development study wants the second.
    ///
    /// The iteration cap is 1000 rather than the 25–50 most packages stop at.
    /// Driving the screen is what set it: five items and forty answers — an
    /// ordinary small study — needed 183 passes to settle at this tolerance, and
    /// at 100 the screen carried a "did not converge" warning about numbers that
    /// were already right to three decimals. Each pass is one eigen-decomposition
    /// of a matrix the size of the questionnaire, so the cap costs nothing and
    /// buys an answer instead of a caveat.
    static func principalAxis(correlation: [[Double]], communalities: [Double],
                              factors: Int, maximumIterations: Int = 1_000,
                              tolerance: Double = 1e-7) -> Extraction {
        let items = correlation.count
        var current = communalities
        var loadings = [[Double]](repeating: [Double](repeating: 0, count: factors),
                                  count: items)
        var iterations = 0
        var converged = false
        var residual = Double.infinity

        while iterations < maximumIterations {
            iterations += 1
            var reduced = correlation
            for index in 0..<items { reduced[index][index] = current[index] }
            guard let eigen = try? SymmetricEigen.of(reduced) else { break }

            for index in 0..<items {
                for factor in 0..<factors {
                    // A negative eigenvalue means that factor explains less than
                    // nothing; its loadings are zero rather than the square root
                    // of a negative number.
                    let scale = max(eigen.values[factor], 0).squareRoot()
                    loadings[index][factor] = eigen.vectors[factor][index] * scale
                }
            }
            let updated = loadings.map { row in
                min(row.reduce(0) { $0 + $1 * $1 }, communalityCeiling)
            }
            let change = zip(current, updated).map { abs($0 - $1) }.max() ?? 0
            current = updated
            residual = change
            if change < tolerance { converged = true; break }
        }
        return Extraction(loadings: loadings, communalities: current,
                          iterations: iterations, converged: converged,
                          residual: residual)
    }

    /// Varimax with Kaiser normalisation — the standard pairwise algorithm.
    ///
    /// Orthogonal rather than oblique: an oblique rotation (promax, oblimin) is
    /// usually the better model of real constructs, which correlate, but it
    /// produces two matrices (pattern and structure) that are routinely confused
    /// for one another in write-ups. One honest orthogonal solution now; oblique
    /// belongs with CFA when that arrives.
    static func varimax(_ loadings: [[Double]], maximumIterations: Int = 100,
                        tolerance: Double = 1e-9) -> [[Double]] {
        let items = loadings.count
        guard let factors = loadings.first?.count, factors > 1, items > 1 else {
            return loadings
        }
        // Kaiser normalisation: rotate the directions, not the lengths, so an
        // item with a large communality does not dominate the criterion.
        let lengths = loadings.map { row in
            max(row.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-12)
        }
        var matrix = loadings.enumerated().map { index, row in
            row.map { $0 / lengths[index] }
        }

        var previous = varimaxCriterion(matrix)
        for _ in 0..<maximumIterations {
            for first in 0..<(factors - 1) {
                for second in (first + 1)..<factors {
                    var sumU = 0.0, sumV = 0.0, sumUV = 0.0, sumSquares = 0.0
                    for row in 0..<items {
                        let a = matrix[row][first]
                        let b = matrix[row][second]
                        let u = a * a - b * b
                        let v = 2 * a * b
                        sumU += u
                        sumV += v
                        sumSquares += u * u - v * v
                        sumUV += u * v
                    }
                    let count = Double(items)
                    let numerator = 2 * sumUV - 2 * sumU * sumV / count
                    let denominator = sumSquares - (sumU * sumU - sumV * sumV) / count
                    guard abs(numerator) > 1e-15 || abs(denominator) > 1e-15 else { continue }
                    let angle = atan2(numerator, denominator) / 4
                    guard abs(angle) > 1e-12 else { continue }
                    let cosine = cos(angle)
                    let sine = sin(angle)
                    for row in 0..<items {
                        let a = matrix[row][first]
                        let b = matrix[row][second]
                        matrix[row][first] = a * cosine + b * sine
                        matrix[row][second] = -a * sine + b * cosine
                    }
                }
            }
            let criterion = varimaxCriterion(matrix)
            if abs(criterion - previous) < tolerance { break }
            previous = criterion
        }

        return matrix.enumerated().map { index, row in row.map { $0 * lengths[index] } }
    }

    private static func varimaxCriterion(_ matrix: [[Double]]) -> Double {
        guard let factors = matrix.first?.count else { return 0 }
        let count = Double(matrix.count)
        var total = 0.0
        for factor in 0..<factors {
            var sumSquares = 0.0
            var sumFourth = 0.0
            for row in matrix {
                let square = row[factor] * row[factor]
                sumSquares += square
                sumFourth += square * square
            }
            total += sumFourth - sumSquares * sumSquares / count
        }
        return total
    }

    /// Sorts the rotated factors by the variance they carry and flips any factor
    /// whose loadings are mostly negative.
    ///
    /// Both are cosmetic in the mathematics and not in the reading: a table whose
    /// second column carries more variance than its first, or whose factor is
    /// "disagreement" because the signs came out that way, is a table that gets
    /// described wrongly in the text.
    static func orderByVariance(_ loadings: [[Double]], factors: Int) -> [[Double]] {
        let variance = (0..<factors).map { factor in
            loadings.reduce(0) { $0 + $1[factor] * $1[factor] }
        }
        let order = (0..<factors).sorted { variance[$0] > variance[$1] }
        let flip = order.map { factor in
            loadings.reduce(0) { $0 + $1[factor] } < 0 ? -1.0 : 1.0
        }
        return loadings.map { row in
            order.enumerated().map { position, factor in row[factor] * flip[position] }
        }
    }

    /// Horn's parallel analysis: how large would this eigenvalue be if the items
    /// were unrelated? Keeps the factors whose observed eigenvalue beats the 95th
    /// percentile of eigenvalues from random data of the same size.
    ///
    /// The generator is seeded from the *shape* of the data, not from the clock:
    /// re-running the same analysis has to give the same number of factors, or
    /// the methods section is unreproducible by construction.
    static func parallelAnalysisCount(observed: [Double], respondents: Int, items: Int,
                                      simulations: Int = 100) -> Int {
        var generator = SeededGenerator(seed: UInt64(respondents) &* 1_000_003
                                        &+ UInt64(items) &* 10_007 &+ 20_260_814)
        var perFactor = [[Double]](repeating: [], count: items)
        for _ in 0..<simulations {
            var data = [[Double]](repeating: [Double](repeating: 0, count: items),
                                  count: respondents)
            for row in 0..<respondents {
                for column in 0..<items {
                    data[row][column] = generator.nextNormal()
                }
            }
            guard let matrix = try? correlationMatrix(data, itemIDs: (0..<items).map(String.init)),
                  let eigen = try? SymmetricEigen.of(matrix) else { continue }
            for index in 0..<items { perFactor[index].append(eigen.values[index]) }
        }

        var kept = 0
        for index in 0..<items {
            let sample = perFactor[index].sorted()
            guard !sample.isEmpty else { break }
            let position = min(sample.count - 1,
                               Int((0.95 * Double(sample.count)).rounded(.down)))
            guard observed[index] > sample[position] else { break }
            kept += 1
        }
        return kept
    }
}

// ─────────────────────────────────────────────────────────────
// Random numbers that are the same tomorrow
// ─────────────────────────────────────────────────────────────

/// SplitMix64, seeded explicitly. `SystemRandomNumberGenerator` would make the
/// number of retained factors move between runs of the same data.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    /// Box–Muller produces two normals at a time; the spare is kept rather than
    /// thrown away, which halves the work in the simulation loop.
    private var spare: Double?

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextNormal() -> Double {
        if let spare { self.spare = nil; return spare }
        let radius = (-2 * log(Double.random(in: 1e-12..<1, using: &self))).squareRoot()
        let angle = 2 * Double.pi * Double.random(in: 0..<1, using: &self)
        spare = radius * sin(angle)
        return radius * cos(angle)
    }
}

// ─────────────────────────────────────────────────────────────
// Did the items land where the instrument said they would?
// ─────────────────────────────────────────────────────────────

/// The comparison between the structure an instrument declares (§20.3 ties every
/// item to a construct) and the structure its answers show.
public struct ConstructFit: Sendable, Equatable {
    public struct ConstructRow: Sendable, Equatable, Identifiable {
        public let constructID: String
        /// The factor most of this construct's items landed on, if there is one.
        public let factor: Int?
        public let itemsDeclared: Int
        public let itemsOnFactor: Int
        public var id: String { constructID }
        /// Every declared item landed on the same factor and nothing else did.
        public var isClean: Bool { factor != nil && itemsOnFactor == itemsDeclared }
    }

    public let constructs: [ConstructRow]
    /// Items whose factor belongs to a construct other than their declared one.
    public let misplaced: [String]
    /// Two declared constructs that came out as one factor — the items do not
    /// distinguish between them, whatever the definitions say.
    public let mergedConstructs: [[String]]
    public let retained: Int

    public var summary: String {
        // One key, not a count glued to a phrase: split across the number the
        // English reads "3/3 construct every item loads on the same factor".
        var parts = [localised("\(constructs.count { $0.isClean })/\(constructs.count) constructs have every item on one factor",
                               "How many constructs came out clean. Placeholders: the clean count and the total.")]
        if !misplaced.isEmpty {
            parts.append(localised("items loading on a different factor than declared: \(misplaced.joined(separator: ", "))",
                                   "Lists items that do not match the declared structure. Placeholder: the item names."))
        }
        for merged in mergedConstructs {
            parts.append(localised("constructs the data cannot tell apart: \(merged.joined(separator: " + "))",
                                   "Lists constructs that did not separate. Placeholder: the construct names."))
        }
        return parts.joined(separator: " · ")
    }

    /// Compares a solution with the instrument's declared item→construct map.
    ///
    /// This is the question the loading table is usually read to answer, and
    /// reading it by eye is where "the items loaded as expected" gets written
    /// about a table where two of them did not.
    public static func compare(_ solution: FactorSolution,
                               constructOfItem: [String: String]) -> ConstructFit {
        let byItem = Dictionary(solution.loadings.map { ($0.itemID, $0) },
                                uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: constructOfItem.keys.sorted()) {
            constructOfItem[$0] ?? ""
        }

        var rows: [ConstructRow] = []
        var misplaced: [String] = []
        var factorOwner: [Int: [String]] = [:]

        for (construct, items) in grouped.sorted(by: { $0.key < $1.key }) {
            let placements = items.compactMap { byItem[$0]?.primaryFactor }
            let counts = Dictionary(grouping: placements) { $0 }.mapValues(\.count)
            // Ties go to the lower factor number so the answer does not depend on
            // dictionary order — a fit report that changes between runs is worse
            // than one that is arbitrary and says so.
            let dominant = counts.max { left, right in
                left.value != right.value ? left.value < right.value : left.key > right.key
            }?.key
            rows.append(ConstructRow(constructID: construct, factor: dominant,
                                     itemsDeclared: items.count,
                                     itemsOnFactor: dominant.map { counts[$0] ?? 0 } ?? 0))
            if let dominant {
                factorOwner[dominant, default: []].append(construct)
                misplaced += items.filter { item in
                    guard let placed = byItem[item]?.primaryFactor else { return false }
                    return placed != dominant
                }
            }
        }

        let merged = factorOwner.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted {
            ($0.first ?? "") < ($1.first ?? "")
        }
        return ConstructFit(constructs: rows, misplaced: misplaced.sorted(),
                            mergedConstructs: merged, retained: solution.retained)
    }
}

// ─────────────────────────────────────────────────────────────
// McDonald's ω — the reliability coefficient that needed factor loadings
// ─────────────────────────────────────────────────────────────

/// ω from a one-factor solution, reported with what makes it interpretable.
public struct OmegaReliability: Sendable, Equatable {
    /// ω-total: the proportion of the total score's variance the common factor
    /// accounts for.
    public let omega: Double
    /// The one-factor loadings ω was computed from.
    public let loadings: [String: Double]
    /// How much of the items' variance that single factor explains. ω assumes a
    /// unidimensional scale, and this is the number that says whether that
    /// assumption held — reported because ω computed on a two-factor scale is a
    /// number with no meaning and no warning attached.
    public let varianceExplained: Double
    public let respondents: Int

    /// The same 0.70 §20.4 sets for α. ω is generally the less biased of the two
    /// when items are not equally good, which is why it is worth having; the
    /// threshold convention is shared.
    public var passes: Bool { omega >= 0.70 }

    public var summary: String {
        String(format: localised("ω %.3f · a single factor explains %.1f%% of the variance · %d respondents", "Summary of McDonald's omega. Placeholders: omega, variance explained and respondent count."),
               omega, varianceExplained * 100, respondents)
    }
}

extension Reliability {

    /// McDonald's ω for one subscale.
    ///
    /// `nil` under exactly the conditions that make it meaningless: fewer than
    /// three items, fewer respondents than items, an item nobody varied on, or a
    /// correlation matrix that cannot be factored. α is the fallback in those
    /// cases and is computed separately — the point of returning `nil` is that
    /// neither this screen nor a chapter should be able to print a number nobody
    /// can defend.
    public static func omega(scores: [[Double]], itemIDs: [String]) -> OmegaReliability? {
        guard itemIDs.count >= ExploratoryFactorAnalysis.minimumItems,
              scores.count > itemIDs.count,
              scores.allSatisfy({ $0.count == itemIDs.count }),
              let correlation = try? ExploratoryFactorAnalysis
                  .correlationMatrix(scores, itemIDs: itemIDs),
              let eigen = try? SymmetricEigen.of(correlation),
              let inverse = try? eigen.inverse() else { return nil }

        let start = itemIDs.indices.map { index in
            min(max(1 - 1 / inverse[index][index], 0),
                ExploratoryFactorAnalysis.communalityCeiling)
        }
        let extraction = ExploratoryFactorAnalysis.principalAxis(
            correlation: correlation, communalities: start, factors: 1)
        // A factor whose loadings are mostly negative is the same factor with the
        // sign the arithmetic happened to pick; ω would come out identical, but
        // the loadings shown beside it would all read as reversed items.
        let sign = extraction.loadings.reduce(0) { $0 + $1[0] } < 0 ? -1.0 : 1.0
        let values = extraction.loadings.map { $0[0] * sign }
        guard values.allSatisfy({ $0.isFinite }) else { return nil }

        let sum = values.reduce(0, +)
        let uniqueness = values.reduce(0) { $0 + (1 - $1 * $1) }
        let denominator = sum * sum + uniqueness
        guard denominator > 0 else { return nil }

        let explained = values.reduce(0) { $0 + $1 * $1 } / Double(itemIDs.count)
        return OmegaReliability(
            omega: sum * sum / denominator,
            loadings: Dictionary(zip(itemIDs, values), uniquingKeysWith: { first, _ in first }),
            varianceExplained: explained, respondents: scores.count)
    }
}
