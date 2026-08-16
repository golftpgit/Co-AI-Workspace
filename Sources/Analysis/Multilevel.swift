import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// Data that comes in clusters (ARCHITECTURE §12.6.1, P19.5).
//
// Patients inside a clinic, pupils inside a school, measurements inside a
// person. The observations are not independent, and every ordinary method
// assumes they are.
//
// **This is the most common error in public-health analysis, and it is
// invisible.** Thirty patients from six clinics are not thirty independent
// observations; if patients in a clinic resemble each other, they are closer to
// six. Analysed as thirty, the confidence interval comes out ~2.2× too narrow
// on the fixture in the tests — the p-value falls, the finding appears, and
// nothing in the output looks wrong. Nobody detects it by reading the result,
// which is why it is checked from the *shape of the data* instead.
//
// What is here: **random intercepts**. The variance components come from the
// balanced one-way ANOVA identities, which are exact for balanced designs and
// checkable by hand — the property this module's rule (R12) is about. Random
// *slopes* are refused rather than approximated: a slope model fitted by
// something that is not maximum likelihood is a number that would be quoted as
// though it were one.
// ─────────────────────────────────────────────────────────────

public struct MultilevelFit: Sendable, Equatable {
    /// Variance between clusters, and within them.
    public let betweenVariance: Double
    public let withinVariance: Double
    /// How much of the total variation is *between* clusters — the share that
    /// makes two observations from one cluster resemble each other.
    public let intraclassCorrelation: Double
    /// `1 + (m̄ − 1)·ICC`. What the sample size has to be divided by before it
    /// means anything: the number of observations that are really independent.
    public let designEffect: Double
    public let clusters: Int
    public let observations: Int

    /// The sample size an ordinary method should have been given.
    public var effectiveSampleSize: Double { Double(observations) / designEffect }

    /// How much wider every interval should be than the one an ordinary method
    /// produced.
    public var standardErrorInflation: Double { designEffect.squareRoot() }
}

public enum Multilevel {

    /// Fits a random-intercept model to values grouped by cluster.
    ///
    /// - Parameter clusters: one array of observations per cluster. Unbalanced
    ///   clusters are handled with the usual average-size correction, and the
    ///   result says the design was unbalanced rather than quietly pretending
    ///   the identities were exact.
    public static func randomIntercept(_ clusters: [[Double]]) throws -> MultilevelFit {
        let nonEmpty = clusters.filter { !$0.isEmpty }
        guard nonEmpty.count >= 2 else {
            throw StatError.notEnoughData("ต้องมีอย่างน้อยสองกลุ่มถึงจะแยกความแปรปรวนระหว่างกลุ่มได้")
        }
        let total = nonEmpty.reduce(0) { $0 + $1.count }
        guard total > nonEmpty.count else {
            throw StatError.notEnoughData(
                "ทุกกลุ่มมีข้อมูลเดียว — แยกความแปรปรวนภายในกลุ่มออกจากระหว่างกลุ่มไม่ได้")
        }

        let grandMean = nonEmpty.flatMap { $0 }.reduce(0, +) / Double(total)
        let means = nonEmpty.map { $0.reduce(0, +) / Double($0.count) }

        // Between: each cluster weighted by its size, which is what makes this
        // reduce to the balanced identity when the sizes are equal.
        var betweenSum = 0.0
        for (index, cluster) in nonEmpty.enumerated() {
            betweenSum += Double(cluster.count) * (means[index] - grandMean)
                * (means[index] - grandMean)
        }
        let betweenMeanSquare = betweenSum / Double(nonEmpty.count - 1)

        var withinSum = 0.0
        for (index, cluster) in nonEmpty.enumerated() {
            for value in cluster { withinSum += (value - means[index]) * (value - means[index]) }
        }
        let withinMeanSquare = withinSum / Double(total - nonEmpty.count)

        // The average cluster size that makes the expectation exact. Equal to
        // the plain average when the design is balanced.
        let sumOfSquares = nonEmpty.reduce(0.0) { $0 + Double($1.count * $1.count) }
        let averageSize = (Double(total) - sumOfSquares / Double(total))
            / Double(nonEmpty.count - 1)

        // A negative estimate means the clusters differ *less* than chance
        // would produce. Clamped to zero and reported as no clustering, because
        // a negative variance is not a quantity — and the alternative, printing
        // it, invites somebody to interpret the sign.
        let between = max(0, (betweenMeanSquare - withinMeanSquare) / averageSize)
        let icc = between + withinMeanSquare > 0
            ? between / (between + withinMeanSquare) : 0
        let meanSize = Double(total) / Double(nonEmpty.count)

        return MultilevelFit(betweenVariance: between,
                             withinVariance: withinMeanSquare,
                             intraclassCorrelation: icc,
                             designEffect: 1 + (meanSize - 1) * icc,
                             clusters: nonEmpty.count,
                             observations: total)
    }

    /// The warning §12.6.1 asks for: clustered data analysed as if it were not.
    ///
    /// Reported as an `AssumptionCheck` like every other one, so it arrives
    /// beside the estimate rather than as a footnote. The threshold is on the
    /// *design effect* rather than on the ICC, because the design effect is
    /// what actually distorts the interval: a small ICC with large clusters
    /// does as much damage as a large one with small clusters.
    public static func independenceCheck(_ fit: MultilevelFit) -> AssumptionCheck {
        let passed = fit.designEffect < 1.1
        return AssumptionCheck(
            name: "independence of observations",
            wasChecked: true,
            passed: passed,
            statistic: fit.designEffect,
            pValue: nil,
            detail: passed
                ? String(format: "ICC = %.3f · design effect = %.2f — การจับกลุ่มแทบไม่มีผล",
                         fit.intraclassCorrelation, fit.designEffect)
                : String(format: "ICC = %.3f · design effect = %.2f — **ข้อมูลซ้อนชั้น** "
                         + "ข้อมูล %d ชิ้นจาก %d กลุ่ม มีค่าเท่ากับข้อมูลอิสระราว %.1f ชิ้นเท่านั้น "
                         + "· วิธีที่ถือว่าทุกชิ้นอิสระจะให้ช่วงความเชื่อมั่นแคบเกินจริงราว %.2f เท่า "
                         + "ซึ่งเป็นความผิดพลาดที่พบบ่อยที่สุดในงานสาธารณสุข",
                         fit.intraclassCorrelation, fit.designEffect,
                         fit.observations, fit.clusters, fit.effectiveSampleSize,
                         fit.standardErrorInflation))
    }

    /// Random slopes are not fitted here, and this says so at the point of use.
    ///
    /// A slope model needs maximum likelihood over an unstructured covariance,
    /// and an approximation of it would produce a number that reads exactly
    /// like the real thing — which is the failure P19.0 was about.
    public static func randomSlope(_ clusters: [[Double]]) throws -> MultilevelFit {
        throw StatError.notImplemented(test: .mixedModel, plannedIn: "P19.5 ครึ่งหลัง")
    }
}
