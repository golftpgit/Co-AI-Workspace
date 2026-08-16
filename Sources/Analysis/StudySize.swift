import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// How many, and how well two methods agree (§12.6.1, P19.6).
//
// Two questions that belong together because both are asked *before* anybody
// analyses anything, and both are usually asked too late:
//
//  • **How many participants?** A study too small to detect the effect it was
//    designed around does not produce "no effect" — it produces nothing, at
//    the same cost in people's time and consent. §19.12's closing gate asks for
//    benefit; G2 should have asked for this.
//  • **Do the two ways of measuring agree?** A correlation between an old
//    device and a new one says they move together, which is not the question.
//    Bland–Altman asks the question that matters: how far apart are they, and
//    is that far enough to change what somebody would do.
// ─────────────────────────────────────────────────────────────

public struct SampleSize: Sendable, Equatable {
    /// Per group, rounded up: a fractional participant is not a participant,
    /// and rounding down is how a study ends up under-powered by design.
    public let perGroup: Int
    public let total: Int
    public let power: Double
    public let alpha: Double
    /// What the number was computed *for*. Kept with it because a sample size
    /// without its assumed effect is a number nobody can check or defend to an
    /// ethics committee.
    public let assumption: String
}

public enum StudySize {

    /// Two independent means. `difference` is the smallest difference worth
    /// detecting — not the one somebody hopes for.
    public static func twoMeans(difference: Double,
                                standardDeviation: Double,
                                power: Double = 0.8,
                                alpha: Double = 0.05) throws -> SampleSize {
        guard difference != 0 else {
            throw StatError.badShape("ผลต่างที่ต้องการตรวจจับเป็นศูนย์ — ต้องใช้ตัวอย่างไม่จำกัด")
        }
        guard standardDeviation > 0 else {
            throw StatError.badShape("ส่วนเบี่ยงเบนมาตรฐานต้องมากกว่าศูนย์")
        }
        try validate(power: power, alpha: alpha)

        let zAlpha = Statistics.normalQuantile(1 - alpha / 2)
        let zBeta = Statistics.normalQuantile(power)
        let n = 2 * (zAlpha + zBeta) * (zAlpha + zBeta)
            * standardDeviation * standardDeviation / (difference * difference)
        let perGroup = Int(n.rounded(.up))
        return SampleSize(
            perGroup: perGroup, total: perGroup * 2, power: power, alpha: alpha,
            assumption: String(format: "ตรวจจับผลต่าง %.4g เมื่อ SD = %.4g",
                               difference, standardDeviation))
    }

    /// Two independent proportions — the shape most trials in this field take.
    public static func twoProportions(_ first: Double, _ second: Double,
                                      power: Double = 0.8,
                                      alpha: Double = 0.05) throws -> SampleSize {
        guard first > 0, first < 1, second > 0, second < 1 else {
            throw StatError.badShape("สัดส่วนต้องอยู่ระหว่าง 0 ถึง 1")
        }
        guard first != second else {
            throw StatError.badShape("สองสัดส่วนเท่ากัน — ไม่มีผลต่างให้ตรวจจับ")
        }
        try validate(power: power, alpha: alpha)

        let zAlpha = Statistics.normalQuantile(1 - alpha / 2)
        let zBeta = Statistics.normalQuantile(power)
        let pooled = (first + second) / 2
        let numerator = zAlpha * (2 * pooled * (1 - pooled)).squareRoot()
            + zBeta * (first * (1 - first) + second * (1 - second)).squareRoot()
        let n = numerator * numerator / ((first - second) * (first - second))
        let perGroup = Int(n.rounded(.up))
        return SampleSize(
            perGroup: perGroup, total: perGroup * 2, power: power, alpha: alpha,
            assumption: String(format: "ตรวจจับความต่างระหว่าง %.3g กับ %.3g", first, second))
    }

    /// The other direction: given the sample somebody actually has, what can
    /// the study see?
    ///
    /// The honest question when a study is already designed around whoever is
    /// available — and the number that decides whether running it is worth
    /// anybody's time.
    public static func power(perGroup: Int, difference: Double,
                             standardDeviation: Double,
                             alpha: Double = 0.05) throws -> Double {
        guard perGroup > 1 else { throw StatError.notEnoughData("ต้องมีอย่างน้อยสองคนต่อกลุ่ม") }
        guard standardDeviation > 0 else {
            throw StatError.badShape("ส่วนเบี่ยงเบนมาตรฐานต้องมากกว่าศูนย์")
        }
        let zAlpha = Statistics.normalQuantile(1 - alpha / 2)
        let standardError = standardDeviation * (2 / Double(perGroup)).squareRoot()
        return Statistics.normalCDF(abs(difference) / standardError - zAlpha)
    }

    private static func validate(power: Double, alpha: Double) throws {
        guard power > 0.5, power < 1 else {
            throw StatError.badShape("power ต้องอยู่ระหว่าง 0.5 ถึง 1 (ปกติ 0.80 หรือ 0.90)")
        }
        guard alpha > 0, alpha < 1 else {
            throw StatError.badShape("alpha ต้องอยู่ระหว่าง 0 ถึง 1")
        }
    }
}

// ─────────────────────────────────────────────────────────────

public struct BlandAltman: Sendable, Equatable {
    /// Mean difference: how far the two methods sit apart on average, and in
    /// which direction.
    public let bias: Double
    public let biasInterval: (lower: Double, upper: Double)
    public let standardDeviation: Double
    /// Where 95% of individual differences fall. **This is the answer**, not
    /// the bias: two methods can agree perfectly on average and disagree by
    /// twenty units on any given patient.
    public let limitsOfAgreement: (lower: Double, upper: Double)
    /// Each limit is itself estimated, and on a small study the uncertainty is
    /// large enough to change a decision about whether the methods are
    /// interchangeable.
    public let lowerLimitInterval: (lower: Double, upper: Double)
    public let upperLimitInterval: (lower: Double, upper: Double)
    public let pairs: Int

    public static func == (a: BlandAltman, b: BlandAltman) -> Bool {
        a.bias == b.bias && a.standardDeviation == b.standardDeviation && a.pairs == b.pairs
    }

    /// Whether the limits fall inside a difference somebody has decided is
    /// clinically unimportant. **The clinical limit is an argument, not a
    /// statistic** — it has to be supplied, because no amount of arithmetic
    /// decides how much disagreement matters.
    public func isInterchangeable(withinClinicalLimit limit: Double) -> Bool {
        abs(limitsOfAgreement.lower) <= limit && abs(limitsOfAgreement.upper) <= limit
    }
}

public enum MethodAgreement {

    /// Bland–Altman for two methods measured on the same subjects.
    ///
    /// Not a correlation: a correlation between an old device and a new one
    /// answers "do they move together", and two thermometers reading five
    /// degrees apart move together perfectly. The question is how far apart
    /// they are on one patient, which is what the limits of agreement say.
    public static func blandAltman(_ first: [Double], _ second: [Double]) throws -> BlandAltman {
        guard first.count == second.count else {
            throw StatError.badShape("ต้องเป็นการวัดคู่กันบนคนเดียวกัน — จำนวนไม่เท่ากัน")
        }
        guard first.count >= 3 else {
            throw StatError.notEnoughData("ต้องมีอย่างน้อยสามคู่")
        }
        let differences = zip(first, second).map(-)
        let n = Double(differences.count)
        let bias = differences.reduce(0, +) / n
        let variance = differences.reduce(0) { $0 + ($1 - bias) * ($1 - bias) } / (n - 1)
        let standardDeviation = variance.squareRoot()

        // Student's t, because the studies that need this are small — a normal
        // quantile here would give limits that are too tight on exactly the
        // studies whose limits matter most.
        let t = Statistics.tQuantile(0.975, degreesOfFreedom: n - 1)
        let biasError = standardDeviation / n.squareRoot()
        let limitError = (3 * variance / n).squareRoot()
        let lower = bias - 1.96 * standardDeviation
        let upper = bias + 1.96 * standardDeviation

        return BlandAltman(
            bias: bias,
            biasInterval: (bias - t * biasError, bias + t * biasError),
            standardDeviation: standardDeviation,
            limitsOfAgreement: (lower, upper),
            lowerLimitInterval: (lower - t * limitError, lower + t * limitError),
            upperLimitInterval: (upper - t * limitError, upper + t * limitError),
            pairs: differences.count)
    }
}
