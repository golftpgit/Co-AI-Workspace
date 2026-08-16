import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// Pooling studies (ARCHITECTURE §12.6.1, P19.7).
//
// A meta-analysis is the most quoted number in medicine and the easiest to
// produce badly, because pooling always returns something. Three things decide
// whether the something means anything, and all three are computed here rather
// than left to the reader:
//
//  • **Which model.** Fixed effect assumes every study estimates *one* true
//    value and differs only by sampling error. Random effects allows the true
//    value to differ between studies. The choice is not a preference — it is a
//    claim about the studies, and I² is the evidence about that claim.
//  • **How much they disagree.** I² is what tells a pooled estimate from an
//    average of incompatible things.
//  • **Whether the set is complete.** A funnel plot's asymmetry is the visible
//    trace of studies that were run and never published — usually the ones that
//    found nothing. §12.6.1 asks for it to be *reported*, not drawn and left to
//    the eye, because "the funnel looks a bit lopsided" is not a finding
//    anybody can act on and everybody can dismiss.
// ─────────────────────────────────────────────────────────────

/// One study's contribution: an effect on a scale where differences are
/// symmetric — a log odds ratio, a log hazard ratio, a mean difference — and
/// its standard error.
public struct StudyEffect: Sendable, Equatable {
    public let label: String
    public let effect: Double
    public let standardError: Double

    public init(label: String, effect: Double, standardError: Double) {
        self.label = label
        self.effect = effect
        self.standardError = standardError
    }

    /// Inverse-variance weight: a study counts for what it can resolve, not for
    /// how many people it enrolled.
    var weight: Double { 1 / (standardError * standardError) }
}

public struct PooledEffect: Sendable, Equatable {
    public enum Model: String, Sendable, Equatable {
        case fixed, random
    }

    public let model: Model
    public let effect: Double
    public let standardError: Double
    public let lower: Double
    public let upper: Double
    public let pValue: Double
    /// Each study's share of the answer, in the same order it was given. On a
    /// forest plot this is the box size, and it is the thing that shows when
    /// one study is the meta-analysis.
    public let weights: [Double]
}

public struct Heterogeneity: Sendable, Equatable {
    /// Cochran's Q and its degrees of freedom.
    public let q: Double
    public let degreesOfFreedom: Int
    public let pValue: Double
    /// The share of variation that is real disagreement rather than sampling
    /// error, as a percentage.
    public let iSquared: Double
    /// Between-study variance (DerSimonian–Laird).
    public let tauSquared: Double

    /// The usual reading, said in words so a screen does not have to invent
    /// its own thresholds.
    public var interpretation: String {
        switch iSquared {
        case ..<25: "ความต่างระหว่างงานต่ำ — ค่ารวมแบบ fixed effect พออธิบายได้"
        case ..<50: "ความต่างระหว่างงานปานกลาง"
        case ..<75: "ความต่างระหว่างงานสูง — ควรใช้ random effects และอธิบายว่าต่างเพราะอะไร"
        default: "ความต่างระหว่างงานสูงมาก — **การรวมค่าอาจไม่มีความหมาย** "
            + "ค่ารวมของสิ่งที่ไม่ใช่สิ่งเดียวกันคือค่าเฉลี่ยที่ไม่มีใครวัดได้"
        }
    }
}

public struct FunnelAsymmetry: Sendable, Equatable {
    /// Egger's intercept: zero when small and large studies agree.
    public let intercept: Double
    public let standardError: Double
    public let t: Double
    public let degreesOfFreedom: Int
    public let pValue: Double

    public var isAsymmetric: Bool { pValue < 0.10 }

    /// Reported in words, because §12.6.1 asks for this to be stated rather
    /// than drawn. The 0.10 threshold is the convention for this test, and it
    /// is looser than 0.05 deliberately: the test has little power, so the
    /// usual level would mean "no evidence of asymmetry" almost always.
    public var summary: String {
        isAsymmetric
            ? String(format: "Egger's test: intercept %.3f (p = %.4f) — **funnel ไม่สมมาตร** "
                     + "งานเล็กในชุดนี้ให้ผลต่างจากงานใหญ่อย่างเป็นระบบ ซึ่งเข้าได้กับ "
                     + "publication bias (งานที่ไม่พบผลมักไม่ถูกตีพิมพ์) หรือกับคุณภาพงานเล็กที่ต่างออกไป "
                     + "· ค่ารวมน่าจะเกินจริง", intercept, pValue)
            : String(format: "Egger's test: intercept %.3f (p = %.4f) — ไม่พบความไม่สมมาตร "
                     + "· **ไม่ได้แปลว่าไม่มี** การทดสอบนี้พลังต่ำเมื่องานน้อยกว่าสิบชิ้น",
                     intercept, pValue)
    }
}

public enum MetaAnalysis {

    public static func pool(_ studies: [StudyEffect],
                            model: PooledEffect.Model = .random) throws -> PooledEffect {
        guard studies.count >= 2 else {
            throw StatError.notEnoughData("การรวมค่าต้องมีอย่างน้อยสองงาน")
        }
        guard studies.allSatisfy({ $0.standardError > 0 }) else {
            throw StatError.badShape("ทุกงานต้องมี standard error มากกว่าศูนย์")
        }

        let tauSquared = model == .random ? try heterogeneity(studies).tauSquared : 0
        let weights = studies.map { 1 / ($0.standardError * $0.standardError + tauSquared) }
        let total = weights.reduce(0, +)
        let effect = zip(weights, studies).reduce(0) { $0 + $1.0 * $1.1.effect } / total
        let standardError = (1 / total).squareRoot()
        let z = Epidemiology.z95

        return PooledEffect(
            model: model,
            effect: effect,
            standardError: standardError,
            lower: effect - z * standardError,
            upper: effect + z * standardError,
            pValue: 2 * (1 - Statistics.normalCDF(abs(effect / standardError))),
            weights: weights.map { $0 / total })
    }

    /// Q, I² and τ² — the evidence about whether pooling is meaningful at all.
    public static func heterogeneity(_ studies: [StudyEffect]) throws -> Heterogeneity {
        guard studies.count >= 2 else {
            throw StatError.notEnoughData("ต้องมีอย่างน้อยสองงานถึงจะวัดความต่างระหว่างงานได้")
        }
        let weights = studies.map(\.weight)
        let total = weights.reduce(0, +)
        let fixed = zip(weights, studies).reduce(0) { $0 + $1.0 * $1.1.effect } / total
        let q = zip(weights, studies).reduce(0) {
            $0 + $1.0 * ($1.1.effect - fixed) * ($1.1.effect - fixed)
        }
        let degreesOfFreedom = studies.count - 1
        // DerSimonian–Laird, and the max(0, …) is not tidying: a negative
        // between-study variance means the studies agree more closely than
        // sampling error alone predicts, which is not a quantity — it is zero
        // disagreement plus luck.
        let c = total - weights.reduce(0) { $0 + $1 * $1 } / total
        let tauSquared = c > 0 ? max(0, (q - Double(degreesOfFreedom)) / c) : 0
        let iSquared = q > 0 ? max(0, (q - Double(degreesOfFreedom)) / q) * 100 : 0

        return Heterogeneity(
            q: q,
            degreesOfFreedom: degreesOfFreedom,
            pValue: Statistics.chiSquarePValue(q, degreesOfFreedom: Double(degreesOfFreedom)),
            iSquared: iSquared,
            tauSquared: tauSquared)
    }

    /// Egger's test for funnel asymmetry — the visible trace of the studies
    /// that are not here.
    ///
    /// Regresses each study's standard normal deviate on its precision. Under
    /// symmetry the intercept is zero: small and large studies say the same
    /// thing. An intercept away from zero means the small ones say something
    /// systematically different, which is what publication bias looks like from
    /// inside a completed meta-analysis.
    public static func funnelAsymmetry(_ studies: [StudyEffect]) throws -> FunnelAsymmetry {
        guard studies.count >= 3 else {
            throw StatError.notEnoughData(
                "Egger's test ต้องมีอย่างน้อยสามงาน — และยังพลังต่ำมากจนกว่าจะถึงสิบงาน")
        }
        let precision = studies.map { 1 / $0.standardError }
        let deviate = studies.map { $0.effect / $0.standardError }
        let n = Double(studies.count)
        let meanX = precision.reduce(0, +) / n
        let meanY = deviate.reduce(0, +) / n

        var covariance = 0.0, varianceX = 0.0
        for index in studies.indices {
            covariance += (precision[index] - meanX) * (deviate[index] - meanY)
            varianceX += (precision[index] - meanX) * (precision[index] - meanX)
        }
        guard varianceX > 0 else {
            throw StatError.notEnoughData("ทุกงานมีความแม่นยำเท่ากัน — ทดสอบความไม่สมมาตรไม่ได้")
        }
        let slope = covariance / varianceX
        let intercept = meanY - slope * meanX

        var residualSum = 0.0
        for index in studies.indices {
            let fitted = intercept + slope * precision[index]
            residualSum += (deviate[index] - fitted) * (deviate[index] - fitted)
        }
        let degreesOfFreedom = studies.count - 2
        let residualVariance = residualSum / Double(degreesOfFreedom)
        let standardError = (residualVariance * (1 / n + meanX * meanX / varianceX)).squareRoot()
        let t = intercept / standardError

        return FunnelAsymmetry(
            intercept: intercept,
            standardError: standardError,
            t: t,
            degreesOfFreedom: degreesOfFreedom,
            pValue: Statistics.tTestPValue(t: abs(t),
                                           degreesOfFreedom: Double(degreesOfFreedom)))
    }
}
