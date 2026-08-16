import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// Counting things that happen (ARCHITECTURE §12.6.1, P19.4).
//
// Admissions per ward, infections per thousand patient-days, visits per month:
// counts are not continuous and their variance is not free to be anything, so a
// linear model on them produces intervals that are wrong in a direction nobody
// notices — too narrow.
//
// **The whole point of this file is the failure it detects.** Poisson regression
// assumes the variance equals the mean. Real counts almost never oblige: wards
// differ, patients cluster, some weeks are bad. When variance exceeds the mean,
// a Poisson fit still returns a perfectly reasonable-looking coefficient with a
// standard error that is **too small** — so a null effect crosses into
// significance and nothing about the output looks wrong. Overdispersion is
// therefore checked every time, not offered as an option, and the negative
// binomial that handles it is a real alternative the system can run rather than
// a name in a warning.
// ─────────────────────────────────────────────────────────────

public struct CountFit: Sendable, Equatable {
    /// Intercept first, then one per predictor, on the log scale.
    public let coefficients: [Double]
    public let standardErrors: [Double]
    /// `exp(coefficient)` — the rate ratio a paper reports: how the rate
    /// multiplies for a one-unit change.
    public var rateRatios: [Double] { coefficients.map(exp) }
    /// The negative binomial's dispersion. `nil` for a Poisson fit, where the
    /// model *assumes* there is none — which is the assumption being checked.
    public let theta: Double?
    public let iterations: Int
}

public enum CountModels {

    /// Poisson regression with a log link, by iteratively reweighted least
    /// squares.
    public static func poisson(counts: [Double],
                               predictors: [[Double]],
                               maximumIterations: Int = 50) throws -> CountFit {
        try fit(counts: counts, predictors: predictors, theta: nil,
                maximumIterations: maximumIterations)
    }

    /// Negative binomial regression: the same model with one extra parameter
    /// for the spread the Poisson assumed away.
    ///
    /// - Parameter theta: the dispersion. Estimated by moments from a Poisson
    ///   fit when not given — the estimate a person can check by hand, rather
    ///   than a profile likelihood whose failure to converge would be one more
    ///   thing to explain.
    public static func negativeBinomial(counts: [Double],
                                        predictors: [[Double]],
                                        theta: Double? = nil) throws -> CountFit {
        let dispersion = try theta ?? estimateTheta(counts: counts, predictors: predictors)
        return try fit(counts: counts, predictors: predictors, theta: dispersion)
    }

    /// Whether the counts are more spread out than a Poisson model allows.
    ///
    /// Pearson χ² against its degrees of freedom. A ratio near 1 is what the
    /// model assumes; well above it means the intervals from a Poisson fit are
    /// too narrow, and "too narrow" is how a null effect becomes a finding.
    public static func overdispersion(counts: [Double],
                                      predictors: [[Double]],
                                      fit: CountFit) -> AssumptionCheck {
        let expected = predicted(predictors: predictors, coefficients: fit.coefficients)
        let degreesOfFreedom = Double(counts.count - fit.coefficients.count)
        guard degreesOfFreedom > 0 else {
            return AssumptionCheck(
                name: "equidispersion (variance = mean)",
                wasChecked: false, passed: false, statistic: nil, pValue: nil,
                detail: "ข้อมูลน้อยเกินกว่าจำนวนพารามิเตอร์ — ตรวจการกระจายเกินไม่ได้")
        }
        var pearson = 0.0
        for (index, count) in counts.enumerated() where expected[index] > 0 {
            pearson += (count - expected[index]) * (count - expected[index]) / expected[index]
        }
        let ratio = pearson / degreesOfFreedom
        let pValue = Statistics.chiSquarePValue(pearson, degreesOfFreedom: degreesOfFreedom)
        let passed = pValue >= StatGate.alpha
        return AssumptionCheck(
            name: "equidispersion (variance = mean)",
            wasChecked: true,
            passed: passed,
            statistic: ratio,
            pValue: pValue,
            detail: passed
                ? String(format: "Pearson χ²/df = %.2f — ความแปรปรวนใกล้เคียงค่าเฉลี่ยตามที่ Poisson สมมติ",
                         ratio)
                : String(format: "Pearson χ²/df = %.2f (p = %.4f) — **ข้อมูลกระจายเกินกว่าที่ Poisson รับได้** "
                         + "ช่วงความเชื่อมั่นจาก Poisson จะแคบเกินจริง และผลที่ไม่จริงจะดูมีนัยสำคัญ "
                         + "· ใช้ negative binomial แทน",
                         ratio, pValue))
    }

    /// Moment estimator for the dispersion, from a Poisson fit's residuals.
    public static func estimateTheta(counts: [Double],
                                     predictors: [[Double]]) throws -> Double {
        let poissonFit = try poisson(counts: counts, predictors: predictors)
        let expected = predicted(predictors: predictors, coefficients: poissonFit.coefficients)
        var numerator = 0.0, denominator = 0.0
        for (index, count) in counts.enumerated() {
            numerator += (count - expected[index]) * (count - expected[index]) - expected[index]
            denominator += expected[index] * expected[index]
        }
        guard numerator > 0 else {
            // Underdispersed or exactly Poisson: there is no extra spread to
            // model, and a negative binomial fitted here would be a Poisson
            // with a wasted parameter. Said rather than silently returning a
            // huge theta that means the same thing obscurely.
            throw StatError.notEnoughData(
                "ข้อมูลไม่ได้กระจายเกิน — negative binomial ไม่มีอะไรจะอธิบายเพิ่มจาก Poisson")
        }
        return denominator / numerator
    }

    // MARK: -

    /// One IRLS loop for both models: the negative binomial differs only in the
    /// weight, `μ / (1 + μ/θ)` against Poisson's `μ`. Written once so the two
    /// cannot drift into disagreeing about the link function.
    private static func fit(counts: [Double],
                            predictors: [[Double]],
                            theta: Double?,
                            maximumIterations: Int = 50) throws -> CountFit {
        guard !counts.isEmpty else { throw StatError.notEnoughData("ไม่มีข้อมูล") }
        guard counts.allSatisfy({ $0 >= 0 && $0 == $0.rounded() }) else {
            throw StatError.badShape("โมเดลนับต้องการจำนวนนับที่ไม่ติดลบและเป็นจำนวนเต็ม")
        }
        guard predictors.allSatisfy({ $0.count == counts.count }) else {
            throw StatError.badShape("จำนวนค่าตัวแปรต้นไม่เท่ากับจำนวนการสังเกต")
        }
        guard counts.contains(where: { $0 > 0 }) else {
            throw StatError.notEnoughData("ไม่มีเหตุการณ์เกิดขึ้นเลย")
        }

        // Design matrix with the intercept in column zero.
        let rows = counts.count
        let columns = predictors.count + 1
        guard rows > columns else {
            throw StatError.notEnoughData("จำนวนการสังเกตต้องมากกว่าจำนวนพารามิเตอร์")
        }
        let design: [[Double]] = (0..<rows).map { row in
            [1.0] + predictors.map { $0[row] }
        }

        var beta = [Double](repeating: 0, count: columns)
        var information = [[Double]](repeating: [Double](repeating: 0, count: columns),
                                     count: columns)
        var iterations = 0

        for step in 1...maximumIterations {
            iterations = step
            var score = [Double](repeating: 0, count: columns)
            information = [[Double]](repeating: [Double](repeating: 0, count: columns),
                                     count: columns)

            for row in 0..<rows {
                let linear = (0..<columns).reduce(0) { $0 + beta[$1] * design[row][$1] }
                let mean = exp(min(linear, 700))          // guard the exponent
                let weight = theta.map { mean / (1 + mean / $0) } ?? mean
                let residual = theta.map { (counts[row] - mean) / (1 + mean / $0) }
                    ?? (counts[row] - mean)
                for j in 0..<columns {
                    score[j] += design[row][j] * residual
                    for k in 0..<columns {
                        information[j][k] += design[row][j] * design[row][k] * weight
                    }
                }
            }
            guard let delta = solve(information, score) else {
                throw StatError.notEnoughData("ประมาณค่าไม่ลู่เข้า — ตัวแปรต้นอาจซ้อนกันสมบูรณ์")
            }
            for j in 0..<columns { beta[j] += delta[j] }
            if delta.allSatisfy({ abs($0) < 1e-10 }) { break }
        }

        guard let covariance = invert(information) else {
            throw StatError.notEnoughData("เมทริกซ์ข้อมูลกลับด้านไม่ได้")
        }
        return CountFit(coefficients: beta,
                        standardErrors: (0..<columns).map { covariance[$0][$0].squareRoot() },
                        theta: theta,
                        iterations: iterations)
    }

    static func predicted(predictors: [[Double]], coefficients: [Double]) -> [Double] {
        let rows = predictors.first?.count ?? 0
        return (0..<rows).map { row in
            var linear = coefficients[0]
            for (index, predictor) in predictors.enumerated() {
                linear += coefficients[index + 1] * predictor[row]
            }
            return exp(min(linear, 700))
        }
    }

    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        guard let inverse = invert(matrix) else { return nil }
        return (0..<vector.count).map { row in
            (0..<vector.count).reduce(0) { $0 + inverse[row][$1] * vector[$1] }
        }
    }

    private static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        var work = matrix
        var inverse = (0..<n).map { row in (0..<n).map { $0 == row ? 1.0 : 0.0 } }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(work[$0][column]) < abs(work[$1][column]) }),
                  abs(work[pivot][column]) > 1e-12 else { return nil }
            work.swapAt(column, pivot)
            inverse.swapAt(column, pivot)
            let divisor = work[column][column]
            for index in 0..<n {
                work[column][index] /= divisor
                inverse[column][index] /= divisor
            }
            for row in 0..<n where row != column {
                let factor = work[row][column]
                guard factor != 0 else { continue }
                for index in 0..<n {
                    work[row][index] -= factor * work[column][index]
                    inverse[row][index] -= factor * inverse[column][index]
                }
            }
        }
        return inverse
    }
}
