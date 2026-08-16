import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// Correlation and agreement (Bland, *An Introduction to Medical Statistics*,
// ch. 11–12 and ch. 20).
//
// Two things this file is careful about, because both are places medical
// papers go wrong and both are one line of code away from each other:
//
//  • **Correlation is not agreement.** Two instruments that read exactly twice
//    each other's value correlate at r = 1.0 and agree about nothing. Bland's
//    chapter 20 exists because of that mistake, and `Reliability.blandAltman`
//    is what answers agreement for continuous measurements. `correlation`
//    here says so in its own summary rather than leaving the reader to
//    remember.
//  • **Agreement between raters is not the proportion they matched.** Two
//    raters who both call 95% of cases negative agree 90% of the time by
//    chance alone, so raw agreement flatters every rare condition. κ is that
//    number minus the chance part.
// ─────────────────────────────────────────────────────────────

public struct Correlation: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case pearson, spearman

        public var label: String {
            switch self {
            case .pearson: "Pearson r"
            case .spearman: "Spearman ρ"
            }
        }
    }

    public let kind: Kind
    public let coefficient: Double
    public let lower: Double
    public let upper: Double
    public let pValue: Double
    public let n: Int

    /// What the number does and does not say.
    public var summary: String {
        String(format: "%@ = %.3f (95%% CI %.3f ถึง %.3f, n = %d, p = %.4f)",
               kind.label, coefficient, lower, upper, n, pValue)
            + " — **ความสัมพันธ์ไม่ใช่ความสอดคล้อง**: เครื่องมือสองชิ้นที่อ่านค่าเป็นสองเท่าของกันและกันเป๊ะ ๆ "
            + "ได้ r = 1.00 และไม่ตรงกันสักค่าเดียว ถ้าคำถามคือ 'วัดแทนกันได้ไหม' ให้ใช้ Bland–Altman"
    }
}

public struct Kappa: Sendable, Equatable {
    public let value: Double
    public let observedAgreement: Double
    public let expectedAgreement: Double
    public let lower: Double
    public let upper: Double
    public let categories: Int
    /// Whether the ratings were treated as ordered (weighted κ).
    public let weighted: Bool

    /// Landis & Koch's wording, which is a convention rather than a law — said
    /// as a convention so nobody quotes it as a threshold.
    public var interpretation: String {
        let band = switch value {
        case ..<0: "แย่กว่าการเดา"
        case ..<0.21: "เกือบไม่ตรงกันเลย"
        case ..<0.41: "ตรงกันน้อย"
        case ..<0.61: "ตรงกันปานกลาง"
        case ..<0.81: "ตรงกันดี"
        default: "ตรงกันดีมาก"
        }
        return String(format: "κ%@ = %.3f (95%% CI %.3f ถึง %.3f) — %@",
                      weighted ? " ถ่วงน้ำหนัก" : "", value, lower, upper, band)
            + " · ตรงกันดิบ \(String(format: "%.1f%%", observedAgreement * 100)) "
            + "ซึ่ง \(String(format: "%.1f%%", expectedAgreement * 100)) เป็นการตรงกันที่คาดได้จากความบังเอิญ"
    }
}

public enum Reliability {

    /// Pearson or Spearman, with a confidence interval from Fisher's z.
    ///
    /// Spearman is Pearson on the ranks — written that way rather than as a
    /// second formula, because two implementations of one idea are two things
    /// that can disagree, and the ranking is the only part that differs.
    public static func correlation(_ x: [Double], _ y: [Double],
                                   kind: Correlation.Kind = .pearson) throws -> Correlation {
        guard x.count == y.count else {
            throw StatError.badShape("ต้องมีจำนวนค่าเท่ากันทั้งสองชุด")
        }
        guard x.count >= 4 else {
            // Fisher's z needs n − 3 in a denominator, and a correlation from
            // three points is a line through three points.
            throw StatError.notEnoughData("ต้องมีอย่างน้อย 4 คู่")
        }
        let a = kind == .spearman ? Statistics.ranks(x) : x
        let b = kind == .spearman ? Statistics.ranks(y) : y

        let meanA = Statistics.mean(a), meanB = Statistics.mean(b)
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for index in a.indices {
            covariance += (a[index] - meanA) * (b[index] - meanB)
            varianceA += (a[index] - meanA) * (a[index] - meanA)
            varianceB += (b[index] - meanB) * (b[index] - meanB)
        }
        guard varianceA > 0, varianceB > 0 else {
            throw StatError.badShape("ชุดใดชุดหนึ่งมีค่าเดียวกันทั้งหมด — หาความสัมพันธ์ไม่ได้")
        }
        let r = covariance / (varianceA * varianceB).squareRoot()
        let n = Double(a.count)

        // Fisher's z transform: the sampling distribution of r is skewed, and
        // a symmetric interval around r runs past 1 for strong correlations.
        let clamped = min(max(r, -0.999999), 0.999999)
        let z = 0.5 * log((1 + clamped) / (1 - clamped))
        let se = 1 / (n - 3).squareRoot()
        let critical = Epidemiology.z95
        let lower = tanh(z - critical * se)
        let upper = tanh(z + critical * se)

        let t = r * ((n - 2) / (1 - r * r)).squareRoot()
        let p = Statistics.tTestPValue(t: abs(t), degreesOfFreedom: n - 2)

        return Correlation(kind: kind, coefficient: r, lower: lower, upper: upper,
                           pValue: p, n: a.count)
    }

    /// Cohen's κ for two raters over the same items.
    ///
    /// - Parameter ordered: treat the categories as ordered and use linear
    ///   weights, so "mild vs moderate" counts as a smaller disagreement than
    ///   "mild vs severe". Off by default: whether categories are ordered is a
    ///   fact about the instrument, not something to assume from their names.
    public static func kappa(_ first: [Int], _ second: [Int],
                             ordered: Bool = false) throws -> Kappa {
        guard first.count == second.count else {
            throw StatError.badShape("ผู้ให้คะแนนสองคนต้องให้คะแนนรายการชุดเดียวกัน")
        }
        guard first.count >= 2 else {
            throw StatError.notEnoughData("ต้องมีอย่างน้อยสองรายการ")
        }
        let categories = Array(Set(first + second)).sorted()
        guard categories.count >= 2 else {
            throw StatError.badShape("มีหมวดเดียว — ความตรงกันไม่มีอะไรให้วัด")
        }
        let index = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1, $0) })
        let size = categories.count
        let n = Double(first.count)

        var table = Array(repeating: Array(repeating: 0.0, count: size), count: size)
        for pair in zip(first, second) {
            table[index[pair.0]!][index[pair.1]!] += 1
        }
        let rowTotals = table.map { $0.reduce(0, +) }
        let columnTotals = (0..<size).map { column in table.reduce(0) { $0 + $1[column] } }

        func weight(_ i: Int, _ j: Int) -> Double {
            guard ordered else { return i == j ? 1 : 0 }
            return 1 - Double(abs(i - j)) / Double(size - 1)
        }

        var observed = 0.0, expected = 0.0
        for i in 0..<size {
            for j in 0..<size {
                observed += weight(i, j) * table[i][j] / n
                expected += weight(i, j) * (rowTotals[i] / n) * (columnTotals[j] / n)
            }
        }
        guard expected < 1 else {
            throw StatError.badShape("ความตรงกันที่คาดจากความบังเอิญเท่ากับ 100% — κ ไม่นิยาม")
        }
        let value = (observed - expected) / (1 - expected)

        // The standard error Cohen gives for the unweighted case; used for the
        // weighted one too and said so, because a weighted κ with an
        // unweighted interval is a number whose interval is narrower than it
        // should be.
        let se = ((observed * (1 - observed)) / (n * (1 - expected) * (1 - expected))).squareRoot()
        let critical = Epidemiology.z95

        return Kappa(value: value, observedAgreement: observed, expectedAgreement: expected,
                     lower: value - critical * se, upper: value + critical * se,
                     categories: size, weighted: ordered)
    }
}
