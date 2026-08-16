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
        let base = "คู่ที่เปลี่ยนจาก + เป็น −: \(changedOneWay) · จาก − เป็น +: \(changedOtherWay)"
        let test = exact
            ? String(format: "ทดสอบแบบ exact (binomial) เพราะคู่ที่เปลี่ยนมีน้อย — p = %.4f", pValue)
            : String(format: "McNemar χ² = %.3f, p = %.4f", statistic, pValue)
        return "\(base) · \(test) · **คู่ที่ไม่เปลี่ยนไม่ได้ถูกนับ** เพราะมันไม่บอกอะไรเรื่องการเปลี่ยนแปลง"
    }
}

public struct TrendResult: Sendable, Equatable {
    public let statistic: Double
    public let pValue: Double
    /// The proportions, in the order given.
    public let proportions: [Double]

    public var summary: String {
        String(format: "χ² for trend = %.3f (1 df), p = %.4f", statistic, pValue)
            + " · สัดส่วนตามลำดับ: "
            + proportions.map { String(format: "%.1f%%", $0 * 100) }.joined(separator: " → ")
            + " · **ทดสอบนี้ถามว่าสัดส่วนไล่ไปตามลำดับหรือไม่** ไม่ใช่ว่ากลุ่มไหนต่างจากกลุ่มไหน "
            + "ถ้าลำดับของกลุ่มสลับได้โดยไม่เสียความหมาย แปลว่าใช้ผิดการทดสอบ"
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
            throw StatError.badShape("จำนวนคู่ติดลบไม่ได้")
        }
        let discordant = changedOneWay + changedOtherWay
        guard discordant > 0 else {
            throw StatError.notEnoughData(
                "ไม่มีคู่ไหนเปลี่ยนเลย — ไม่มีอะไรให้ทดสอบเรื่องการเปลี่ยนแปลง")
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
            throw StatError.notEnoughData("แนวโน้มต้องมีอย่างน้อยสามกลุ่มที่เรียงลำดับได้")
        }
        guard groups.allSatisfy({ $0.total > 0 && $0.cases >= 0 && $0.cases <= $0.total }) else {
            throw StatError.badShape("จำนวนเคสต้องอยู่ระหว่าง 0 กับจำนวนทั้งหมดของกลุ่ม")
        }
        let x = scores ?? (0..<groups.count).map(Double.init)
        guard x.count == groups.count else {
            throw StatError.badShape("จำนวนคะแนนลำดับต้องเท่ากับจำนวนกลุ่ม")
        }

        let totals = groups.map { Double($0.total) }
        let cases = groups.map { Double($0.cases) }
        let n = totals.reduce(0, +)
        let r = cases.reduce(0, +)
        let overall = r / n
        guard overall > 0, overall < 1 else {
            throw StatError.notEnoughData("ทุกคนเป็นเคส หรือไม่มีใครเป็นเลย — ไม่มีแนวโน้มให้ทดสอบ")
        }

        let meanScore = zip(totals, x).reduce(0) { $0 + $1.0 * $1.1 } / n
        var numerator = 0.0, denominator = 0.0
        for index in groups.indices {
            numerator += cases[index] * (x[index] - meanScore)
            denominator += totals[index] * (x[index] - meanScore) * (x[index] - meanScore)
        }
        guard denominator > 0 else {
            throw StatError.badShape("คะแนนลำดับทุกกลุ่มเท่ากัน — ไม่มีลำดับให้ไล่")
        }
        let statistic = numerator * numerator / (overall * (1 - overall) * denominator)

        return TrendResult(statistic: statistic,
                           pValue: Statistics.chiSquarePValue(statistic, degreesOfFreedom: 1),
                           proportions: zip(cases, totals).map { $0 / $1 })
    }
}
