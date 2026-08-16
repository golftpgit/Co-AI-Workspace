import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// The arithmetic the Statistical Verification Gate stands on
// (ARCHITECTURE §12.3, P6.6).
//
// Written here rather than shelled out to scipy for one reason: the gate runs
// on every statistical result *before* it reaches the supervisor's context, so
// it has to work on a machine with no Python, no network and no packages. A
// check that is only available when a dependency happens to be installed is a
// check that will be missing exactly when someone is in a hurry.
//
// Everything below is a published algorithm, cited where it is not obvious.
// Nothing here is approximate on purpose: where an approximation is used (the
// normal approximations for the rank tests, Royston's polynomial fit for
// Shapiro–Wilk), it is named at the call site, because a p-value nobody can
// trace is worse than no p-value.
// ─────────────────────────────────────────────────────────────

public enum Statistics {

    // MARK: - descriptive

    public static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    /// Sample variance, denominator n−1.
    public static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return .nan }
        let m = mean(values)
        return values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)
    }

    public static func standardDeviation(_ values: [Double]) -> Double {
        sqrt(variance(values))
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    // MARK: - distributions
    //
    // The tails moved to `StatKit.Distributions` when P11.3 gave them a second
    // caller on the far side of M15's dependency wall (Bartlett's test needs a
    // chi-square tail, and Instruments cannot import Analysis). The names stay
    // here because this is where the gate and every test reach for them; there
    // is one implementation, and it is not this file.

    public static func normalCDF(_ x: Double) -> Double {
        Distributions.normalCDF(x)
    }

    /// The inverse normal CDF — needed for Shapiro–Wilk's expected order
    /// statistics.
    public static func normalQuantile(_ p: Double) -> Double {
        Distributions.normalQuantile(p)
    }

    /// Two-sided p-value for Student's t.
    public static func tTestPValue(t: Double, degreesOfFreedom: Double) -> Double {
        Distributions.tTestPValue(t: t, degreesOfFreedom: degreesOfFreedom)
    }

    /// The two-sided t multiplier for an interval.
    public static func tQuantile(_ p: Double, degreesOfFreedom: Double) -> Double {
        Distributions.tQuantile(p, degreesOfFreedom: degreesOfFreedom)
    }

    /// Upper-tail p-value for an F statistic.
    public static func fTestPValue(f: Double, d1: Double, d2: Double) -> Double {
        Distributions.fTestPValue(f: f, d1: d1, d2: d2)
    }

    /// Upper-tail p-value for a chi-square statistic.
    public static func chiSquarePValue(_ x: Double, degreesOfFreedom: Double) -> Double {
        Distributions.chiSquarePValue(x, degreesOfFreedom: degreesOfFreedom)
    }

    /// I_x(a, b) — the regularised incomplete beta.
    static func regularizedIncompleteBeta(_ x: Double, _ a: Double, _ b: Double) -> Double {
        Distributions.regularizedIncompleteBeta(x, a, b)
    }

    /// P(a, x) — the regularised lower incomplete gamma.
    static func regularizedIncompleteGamma(_ a: Double, _ x: Double) -> Double {
        Distributions.regularizedIncompleteGamma(a, x)
    }

    // MARK: - normality

    public struct ShapiroWilk: Sendable, Equatable {
        public let w: Double
        public let pValue: Double
    }

    /// Shapiro–Wilk, Royston's AS R94.
    ///
    /// The standard normality test for the sample sizes clinical research
    /// actually produces (n < 50 is the common case, and it is exactly where
    /// eyeballing a histogram fails). Returns nil below n = 3, where normality
    /// is not a question that can be asked.
    public static func shapiroWilk(_ values: [Double]) -> ShapiroWilk? {
        let n = values.count
        guard n >= 3, n <= 5000 else { return nil }
        let x = values.sorted()
        let nd = Double(n)

        // Expected values of the standard normal order statistics, normalised.
        var m = (1...n).map { normalQuantile((Double($0) - 0.375) / (nd + 0.25)) }
        let ssumm = m.reduce(0) { $0 + $1 * $1 }
        var a = m.map { $0 / ssumm.squareRoot() }

        if n > 5 {
            let u = 1 / nd.squareRoot()
            let an = -2.706056 * pow(u, 5) + 4.434685 * pow(u, 4) - 2.071190 * pow(u, 3)
                - 0.147981 * u * u + 0.221157 * u + m[n - 1] / ssumm.squareRoot()
            let an1 = -3.582633 * pow(u, 5) + 5.682633 * pow(u, 4) - 1.752461 * pow(u, 3)
                - 0.293762 * u * u + 0.042981 * u + m[n - 2] / ssumm.squareRoot()
            let phi = (ssumm - 2 * m[n - 1] * m[n - 1] - 2 * m[n - 2] * m[n - 2])
                / (1 - 2 * an * an - 2 * an1 * an1)
            a = m.map { $0 / phi.squareRoot() }
            a[n - 1] = an; a[0] = -an
            a[n - 2] = an1; a[1] = -an1
        } else if n > 3 {
            let u = 1 / nd.squareRoot()
            let an = -2.706056 * pow(u, 5) + 4.434685 * pow(u, 4) - 2.071190 * pow(u, 3)
                - 0.147981 * u * u + 0.221157 * u + m[n - 1] / ssumm.squareRoot()
            let phi = (ssumm - 2 * m[n - 1] * m[n - 1]) / (1 - 2 * an * an)
            a = m.map { $0 / phi.squareRoot() }
            a[n - 1] = an; a[0] = -an
        } else {
            a = [-0.5.squareRoot(), 0, 0.5.squareRoot()]
        }
        m = a

        let average = mean(x)
        let ss = x.reduce(0) { $0 + ($1 - average) * ($1 - average) }
        guard ss > 0 else { return nil }
        let numerator = zip(m, x).reduce(0) { $0 + $1.0 * $1.1 }
        let w = min(numerator * numerator / ss, 1)

        // Royston's normalising transform, then the normal tail.
        let p: Double
        if n == 3 {
            // Exact for n = 3.
            let pi6 = 1.909859, stqr = 1.047198
            p = max(0, min(1, pi6 * (asin(w.squareRoot()) - stqr)))
        } else if n <= 11 {
            let gamma = -2.273 + 0.459 * nd
            let value = -log(gamma - log1p(-w))
            let mu = 0.5440 - 0.39978 * nd + 0.025054 * nd * nd - 0.0006714 * nd * nd * nd
            let sigma = exp(1.3822 - 0.77857 * nd + 0.062767 * nd * nd
                            - 0.0020322 * nd * nd * nd)
            p = 1 - normalCDF((value - mu) / sigma)
        } else {
            let u = log(nd)
            let value = log1p(-w)
            let mu = -1.5861 - 0.31082 * u - 0.083751 * u * u + 0.0038915 * u * u * u
            let sigma = exp(-0.4803 - 0.082676 * u + 0.0030302 * u * u)
            p = 1 - normalCDF((value - mu) / sigma)
        }
        return ShapiroWilk(w: w, pValue: max(0, min(1, p)))
    }

    // MARK: - ranks

    /// Midranks, so ties share their average rank — the correction every rank
    /// test below depends on.
    public static func ranks(_ values: [Double]) -> [Double] {
        let ordered = values.enumerated().sorted { $0.element < $1.element }
        var result = [Double](repeating: 0, count: values.count)
        var index = 0
        while index < ordered.count {
            var end = index
            while end + 1 < ordered.count, ordered[end + 1].element == ordered[index].element {
                end += 1
            }
            let rank = Double(index + end + 2) / 2       // 1-based midrank
            for position in index...end { result[ordered[position].offset] = rank }
            index = end + 1
        }
        return result
    }

    /// Group sizes of the tied blocks, for the tie corrections.
    static func tieBlocks(_ values: [Double]) -> [Int] {
        var blocks: [Int] = []
        let sorted = values.sorted()
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[index] { end += 1 }
            blocks.append(end - index + 1)
            index = end + 1
        }
        return blocks
    }

    // MARK: - linear algebra

    /// Solves `matrix · x = vector` by Gauss–Jordan with partial pivoting, and
    /// hands back the inverse too — the standard errors need it.
    static func solve(_ matrix: [[Double]], _ vector: [Double]) -> (solution: [Double],
                                                                   inverse: [[Double]])? {
        let n = vector.count
        guard matrix.count == n else { return nil }
        var a = matrix
        var b = vector
        var inverse = (0..<n).map { row in (0..<n).map { $0 == row ? 1.0 : 0.0 } }

        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-12 else { return nil }   // singular
            a.swapAt(column, pivot); b.swapAt(column, pivot); inverse.swapAt(column, pivot)

            let divisor = a[column][column]
            for index in 0..<n { a[column][index] /= divisor; inverse[column][index] /= divisor }
            b[column] /= divisor

            for row in 0..<n where row != column {
                let factor = a[row][column]
                guard factor != 0 else { continue }
                for index in 0..<n {
                    a[row][index] -= factor * a[column][index]
                    inverse[row][index] -= factor * inverse[column][index]
                }
                b[row] -= factor * b[column]
            }
        }
        return (b, inverse)
    }

    // MARK: - regression

    public struct RegressionFit: Sendable {
        /// Intercept first, then one per predictor.
        public let coefficients: [Double]
        public let standardErrors: [Double]
        public let fitted: [Double]
        public let residuals: [Double]
        public let rSquared: Double
        public let degreesOfFreedom: Int
    }

    /// Ordinary least squares with an intercept.
    public static func leastSquares(y: [Double], predictors: [[Double]]) -> RegressionFit? {
        let n = y.count
        let k = predictors.count
        guard n > k + 1, predictors.allSatisfy({ $0.count == n }) else { return nil }

        let design = (0..<n).map { row in [1.0] + predictors.map { $0[row] } }
        let width = k + 1
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)
        var xty = [Double](repeating: 0, count: width)
        for row in 0..<n {
            for i in 0..<width {
                xty[i] += design[row][i] * y[row]
                for j in 0..<width { xtx[i][j] += design[row][i] * design[row][j] }
            }
        }
        guard let solved = solve(xtx, xty) else { return nil }
        let beta = solved.solution
        let fitted = (0..<n).map { row in
            (0..<width).reduce(0) { $0 + beta[$1] * design[row][$1] }
        }
        let residuals = zip(y, fitted).map { $0 - $1 }
        let average = mean(y)
        let totalSS = y.reduce(0) { $0 + ($1 - average) * ($1 - average) }
        let residualSS = residuals.reduce(0) { $0 + $1 * $1 }
        let df = n - width
        let sigmaSquared = residualSS / Double(df)
        let errors = (0..<width).map { (sigmaSquared * solved.inverse[$0][$0]).squareRoot() }
        return RegressionFit(coefficients: beta,
                             standardErrors: errors,
                             fitted: fitted,
                             residuals: residuals,
                             rSquared: totalSS > 0 ? 1 - residualSS / totalSS : .nan,
                             degreesOfFreedom: df)
    }

    /// Variance inflation factors, one per predictor: how much of each
    /// predictor is already explained by the others.
    public static func varianceInflationFactors(_ predictors: [[Double]]) -> [Double] {
        guard predictors.count > 1 else { return predictors.map { _ in 1 } }
        return predictors.indices.map { index in
            var others = predictors
            let target = others.remove(at: index)
            guard let fit = leastSquares(y: target, predictors: others),
                  fit.rSquared.isFinite, fit.rSquared < 1 else {
                // Perfectly explained by the others: the model cannot separate
                // them at all, which is the extreme this number measures.
                return .infinity
            }
            return 1 / (1 - fit.rSquared)
        }
    }

    public struct LogisticFit: Sendable {
        public let coefficients: [Double]
        public let standardErrors: [Double]
        public let fitted: [Double]
        public let iterations: Int
        public let converged: Bool
        /// True when some predictor separates the outcome perfectly — the fit
        /// then runs away to infinity and its p-values mean nothing.
        public let separated: Bool
    }

    /// Logistic regression by iteratively reweighted least squares.
    public static func logistic(y: [Double], predictors: [[Double]],
                                maximumIterations: Int = 40) -> LogisticFit? {
        let n = y.count
        let width = predictors.count + 1
        guard n > width, predictors.allSatisfy({ $0.count == n }),
              y.allSatisfy({ $0 == 0 || $0 == 1 }) else { return nil }

        let design = (0..<n).map { row in [1.0] + predictors.map { $0[row] } }
        var beta = [Double](repeating: 0, count: width)
        var converged = false
        var iterations = 0
        var inverse = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)

        for step in 1...maximumIterations {
            iterations = step
            let eta = design.map { row in zip(row, beta).reduce(0) { $0 + $1.0 * $1.1 } }
            let p = eta.map { 1 / (1 + exp(-$0)) }
            var xwx = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)
            var score = [Double](repeating: 0, count: width)
            for row in 0..<n {
                let weight = max(p[row] * (1 - p[row]), 1e-10)
                for i in 0..<width {
                    score[i] += design[row][i] * (y[row] - p[row])
                    for j in 0..<width { xwx[i][j] += design[row][i] * design[row][j] * weight }
                }
            }
            guard let solved = solve(xwx, score) else { return nil }
            inverse = solved.inverse
            let increment = solved.solution
            for index in 0..<width { beta[index] += increment[index] }
            if increment.allSatisfy({ abs($0) < 1e-8 }) { converged = true; break }
        }

        let eta = design.map { row in zip(row, beta).reduce(0) { $0 + $1.0 * $1.1 } }
        let fitted = eta.map { 1 / (1 + exp(-$0)) }
        // Fitted probabilities pinned at 0 or 1 are what separation looks like
        // from here, and it is why a coefficient of 40 is not a strong effect.
        let separated = !converged || fitted.contains { $0 < 1e-6 || $0 > 1 - 1e-6 }
        let errors = (0..<width).map { inverse[$0][$0] > 0 ? inverse[$0][$0].squareRoot() : .nan }
        return LogisticFit(coefficients: beta, standardErrors: errors, fitted: fitted,
                           iterations: iterations, converged: converged, separated: separated)
    }
}
