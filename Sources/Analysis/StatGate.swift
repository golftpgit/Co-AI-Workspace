import Foundation

// ─────────────────────────────────────────────────────────────
// Statistical Verification Gate (ARCHITECTURE §12.3, P6.6).
//
// §12.3 calls this a PostToolUse hook of the Analyst's: every statistical test
// gets its assumptions checked automatically, **before** the result reaches the
// supervisor's context. The shape that makes that true is not a checker you can
// call afterwards — it is that **the only way to get a test result out of this
// module is to get the assumption report with it**. `StatResult` has no
// initialiser that produces one without the other, and the tests are not
// exposed separately.
//
// The rule when a check fails is §12.3's: not "failed", but *this is the wrong
// test* — a structured warning, a named alternative, and a trip back to the
// Analysis Plan for approval, because changing the method is a change of
// methodology and not a retry (P6.7 owns the plan; this module owns the
// verdict).
//
// Three deliberate refusals:
//
//  • **An assumption we cannot check is not an assumption that passed.**
//    Proportional hazards needs a fitted Cox model, which this module does not
//    have, so it is reported as unchecked and the result is not called clean.
//  • **No silent n.** Shapiro–Wilk below n = 3, a chi-square with an empty
//    row — these come back as "could not be checked", never as a p-value.
//  • **The numbers travel with the verdict.** "ข้อมูลไม่ปกติ" with no W and no
//    p is something a reader has to take on trust, and §2.5's whole point is
//    that they should not have to.
// ─────────────────────────────────────────────────────────────

public enum StatisticalTest: String, Sendable, Codable, CaseIterable {
    case studentT
    case welchT
    case pairedT
    case oneWayANOVA
    case chiSquare
    case linearRegression
    case logisticRegression
    case survival
    // The non-parametric alternatives §12.3 asks the gate to propose. Runnable,
    // not just nameable: a gate that suggests a test the system cannot run
    // leaves the user exactly where they were.
    case mannWhitney
    case wilcoxonSignedRank
    case kruskalWallis
    case fisherExact
    /// §12.6.1's count models (P19.4). The negative binomial is listed as its
    /// own test rather than a mode of the Poisson because the gate proposes it
    /// *by name* when dispersion fails, and a proposal has to be runnable.
    case poissonRegression
    case negativeBinomialRegression

    public var label: String {
        switch self {
        case .studentT: "t-test สองกลุ่ม (Student)"
        case .welchT: "t-test สองกลุ่ม (Welch)"
        case .pairedT: "paired t-test"
        case .oneWayANOVA: "ANOVA ทางเดียว"
        case .chiSquare: "ไคสแควร์"
        case .linearRegression: "การถดถอยเชิงเส้น"
        case .logisticRegression: "การถดถอยโลจิสติก"
        case .survival: "การวิเคราะห์การรอดชีพ"
        case .poissonRegression: "การถดถอยปัวซง (ข้อมูลนับ)"
        case .negativeBinomialRegression: "การถดถอย negative binomial (ข้อมูลนับที่กระจายเกิน)"
        case .mannWhitney: "Mann–Whitney U"
        case .wilcoxonSignedRank: "Wilcoxon signed-rank"
        case .kruskalWallis: "Kruskal–Wallis"
        case .fisherExact: "Fisher's exact"
        }
    }

    /// Whether the test assumes a distribution. The rank tests do not, which is
    /// why they are what the gate proposes.
    public var isParametric: Bool {
        switch self {
        case .mannWhitney, .wilcoxonSignedRank, .kruskalWallis, .fisherExact: false
        default: true
        }
    }
}

/// One assumption, and what happened when it was checked.
public struct AssumptionCheck: Sendable, Equatable, Identifiable {
    public let name: String
    /// False when the check could not be run at all — reported apart from
    /// "passed", because they are not the same thing.
    public let wasChecked: Bool
    public let passed: Bool
    public let statistic: Double?
    public let pValue: Double?
    /// What was measured and what it means, with the numbers in it.
    public let detail: String

    public var id: String { name }

    /// Something a person has to look at: a failure, or a check that could not
    /// be made.
    public var isWarning: Bool { !passed || !wasChecked }
}

public struct StatResult: Sendable {
    public let test: StatisticalTest
    public let statistic: Double
    public let pValue: Double
    public let degreesOfFreedom: Double?
    /// The estimate, where the test has one (mean difference, F, coefficients).
    public let summary: String
    public let assumptions: [AssumptionCheck]
    /// Tests to run instead, when an assumption did not hold.
    public let alternatives: [StatisticalTest]

    public var warnings: [AssumptionCheck] { assumptions.filter(\.isWarning) }

    /// The one thing callers should branch on: whether this result may be
    /// treated as an answer.
    public var isClean: Bool { warnings.isEmpty }

    /// §12.3: a failed assumption sends the work back to the Analysis Plan,
    /// because choosing a different test is a change of methodology.
    public var requiresPlanReapproval: Bool { !isClean && !alternatives.isEmpty }

    /// The structured warning, as one readable block. Written here so every
    /// surface — notebook, agent transcript, plan — says the same thing.
    public var report: String {
        var lines = ["\(test.label): \(summary)"]
        for assumption in assumptions {
            let mark = assumption.wasChecked ? (assumption.passed ? "✓" : "✗") : "?"
            lines.append("  \(mark) \(assumption.name) — \(assumption.detail)")
        }
        if !alternatives.isEmpty {
            lines.append("  → ข้อสมมติไม่ผ่าน เสนอให้ใช้: "
                         + alternatives.map(\.label).joined(separator: " หรือ ")
                         + " (เปลี่ยนวิธี = ต้องกลับไปอนุมัติที่ Analysis Plan)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum StatError: Error, CustomStringConvertible, Equatable {
    case notEnoughData(String)
    case badShape(String)
    /// The test is in §12.3's table and this module cannot run it (P19.0).
    ///
    /// **A refusal, not a result.** The alternative shipped for a while: a
    /// `StatResult` with `NaN` for the statistic, the summary the caller passed
    /// in, and an assumption marked unchecked. Everything about that is
    /// defensible except the shape — it is the same shape a real answer has, so
    /// it renders in the same box, gets pasted into the same manuscript, and
    /// the one field that says "this was never computed" is an assumption row
    /// most people skim past. A method §12.4 pre-registered and nothing ever
    /// calculated must fail loudly at the point of use.
    case notImplemented(test: StatisticalTest, plannedIn: String)

    public var description: String {
        switch self {
        case .notEnoughData(let message): "ข้อมูลไม่พอสำหรับการทดสอบนี้: \(message)"
        case .badShape(let message): "รูปร่างข้อมูลไม่ถูกต้อง: \(message)"
        case .notImplemented(let test, let planned):
            "ระบบยังคำนวณ \(test.rawValue) เองไม่ได้ (แผน \(planned)) — "
                + "จึงไม่มีผลให้รายงาน · ถ้าจำเป็นต้องใช้ตอนนี้ ต้องคำนวณจากเครื่องมือภายนอก "
                + "แล้วบันทึกที่มาไว้ อย่าอ้างว่าเป็นผลของระบบนี้"
        }
    }
}

public enum StatGate {

    /// The significance level every check below is judged at. One number, in
    /// one place: a gate whose thresholds differ per call is a gate whose
    /// verdicts cannot be compared.
    public static let alpha = 0.05

    // MARK: - two groups

    /// Two independent groups. Welch by default — equal variances are an
    /// assumption, and Welch is the test that does not need it.
    public static func twoSample(_ a: [Double], _ b: [Double],
                                 assumingEqualVariance: Bool = false) throws -> StatResult {
        guard a.count >= 2, b.count >= 2 else {
            throw StatError.notEnoughData("ต้องมีอย่างน้อยกลุ่มละ 2 ค่า")
        }
        let meanA = Statistics.mean(a), meanB = Statistics.mean(b)
        let varianceA = Statistics.variance(a), varianceB = Statistics.variance(b)
        let nA = Double(a.count), nB = Double(b.count)

        let t: Double
        let df: Double
        if assumingEqualVariance {
            let pooled = ((nA - 1) * varianceA + (nB - 1) * varianceB) / (nA + nB - 2)
            t = (meanA - meanB) / (pooled * (1 / nA + 1 / nB)).squareRoot()
            df = nA + nB - 2
        } else {
            let se = (varianceA / nA + varianceB / nB).squareRoot()
            t = (meanA - meanB) / se
            // Welch–Satterthwaite.
            let numerator = pow(varianceA / nA + varianceB / nB, 2)
            let denominator = pow(varianceA / nA, 2) / (nA - 1) + pow(varianceB / nB, 2) / (nB - 1)
            df = numerator / denominator
        }
        let p = Statistics.tTestPValue(t: t, degreesOfFreedom: df)

        var assumptions = [normality(of: a, named: "กลุ่ม 1"), normality(of: b, named: "กลุ่ม 2")]
        if assumingEqualVariance { assumptions.append(equalVariance([a, b])) }

        return StatResult(
            test: assumingEqualVariance ? .studentT : .welchT,
            statistic: t, pValue: p, degreesOfFreedom: df,
            summary: String(format: "ค่าเฉลี่ย %.4g เทียบ %.4g (ต่างกัน %.4g) · t = %.4f · p = %.4g",
                            meanA, meanB, meanA - meanB, t, p),
            assumptions: assumptions,
            alternatives: assumptions.contains(where: \.isWarning) ? [.mannWhitney] : [])
    }

    /// Paired measurements — the same subjects before and after.
    public static func paired(_ before: [Double], _ after: [Double]) throws -> StatResult {
        guard before.count == after.count else {
            throw StatError.badShape("ข้อมูลจับคู่ต้องมีจำนวนเท่ากัน")
        }
        guard before.count >= 2 else { throw StatError.notEnoughData("ต้องมีอย่างน้อย 2 คู่") }
        let differences = zip(after, before).map { $0 - $1 }
        let n = Double(differences.count)
        let meanDifference = Statistics.mean(differences)
        let se = Statistics.standardDeviation(differences) / n.squareRoot()
        let t = meanDifference / se
        let df = n - 1
        let p = Statistics.tTestPValue(t: t, degreesOfFreedom: df)
        // The assumption is about the *differences*, not about either column —
        // a detail that is wrong in a lot of published analyses.
        let assumption = normality(of: differences, named: "ผลต่างรายคู่")
        return StatResult(
            test: .pairedT, statistic: t, pValue: p, degreesOfFreedom: df,
            summary: String(format: "ผลต่างเฉลี่ย %.4g · t = %.4f · p = %.4g",
                            meanDifference, t, p),
            assumptions: [assumption],
            alternatives: assumption.isWarning ? [.wilcoxonSignedRank] : [])
    }

    // MARK: - several groups

    public static func oneWayANOVA(_ groups: [[Double]]) throws -> StatResult {
        guard groups.count >= 2, groups.allSatisfy({ $0.count >= 2 }) else {
            throw StatError.notEnoughData("ต้องมีอย่างน้อย 2 กลุ่ม กลุ่มละ 2 ค่า")
        }
        let all = groups.flatMap { $0 }
        let grandMean = Statistics.mean(all)
        let betweenSS = groups.reduce(0.0) { total, group in
            let difference = Statistics.mean(group) - grandMean
            return total + Double(group.count) * difference * difference
        }
        let withinSS = groups.reduce(0.0) { total, group in
            let average = Statistics.mean(group)
            return total + group.reduce(0) { $0 + ($1 - average) * ($1 - average) }
        }
        let d1 = Double(groups.count - 1)
        let d2 = Double(all.count - groups.count)
        let f = (betweenSS / d1) / (withinSS / d2)
        let p = Statistics.fTestPValue(f: f, d1: d1, d2: d2)

        var assumptions = groups.enumerated().map {
            normality(of: $0.element, named: "กลุ่ม \($0.offset + 1)")
        }
        assumptions.append(equalVariance(groups))

        return StatResult(
            test: .oneWayANOVA, statistic: f, pValue: p, degreesOfFreedom: d1,
            summary: String(format: "F(%.0f, %.0f) = %.4f · p = %.4g", d1, d2, f, p),
            assumptions: assumptions,
            alternatives: assumptions.contains(where: \.isWarning) ? [.kruskalWallis] : [])
    }

    // MARK: - counts

    /// Chi-square test of independence over a contingency table.
    public static func chiSquare(_ table: [[Int]]) throws -> StatResult {
        guard table.count >= 2, let width = table.first?.count, width >= 2,
              table.allSatisfy({ $0.count == width }) else {
            throw StatError.badShape("ตารางต้องมีอย่างน้อย 2×2 และทุกแถวยาวเท่ากัน")
        }
        let rowTotals = table.map { $0.reduce(0, +) }
        let columnTotals = (0..<width).map { column in table.reduce(0) { $0 + $1[column] } }
        let total = rowTotals.reduce(0, +)
        guard total > 0 else { throw StatError.notEnoughData("ตารางว่าง") }

        var chiSquare = 0.0
        var expected: [Double] = []
        for (rowIndex, row) in table.enumerated() {
            for column in 0..<width {
                let e = Double(rowTotals[rowIndex]) * Double(columnTotals[column]) / Double(total)
                expected.append(e)
                guard e > 0 else { continue }
                let difference = Double(row[column]) - e
                chiSquare += difference * difference / e
            }
        }
        let df = Double((table.count - 1) * (width - 1))
        let p = Statistics.chiSquarePValue(chiSquare, degreesOfFreedom: df)

        // §12.3's assumption for this test, and the reason Fisher's exact
        // exists: the chi-square approximation falls apart in small cells.
        let smallest = expected.min() ?? 0
        let below5 = expected.filter { $0 < 5 }.count
        let assumption = AssumptionCheck(
            name: "จำนวนที่คาดหวังในแต่ละช่อง ≥ 5",
            wasChecked: true,
            passed: below5 == 0,
            statistic: smallest,
            pValue: nil,
            detail: below5 == 0
                ? String(format: "ช่องที่น้อยที่สุดคาดหวัง %.2f", smallest)
                : String(format: "%d ช่องมีค่าคาดหวังต่ำกว่า 5 (น้อยสุด %.2f) — "
                         + "การประมาณด้วยไคสแควร์เชื่อถือไม่ได้ที่จำนวนเท่านี้", below5, smallest))

        let isTwoByTwo = table.count == 2 && width == 2
        return StatResult(
            test: .chiSquare, statistic: chiSquare, pValue: p, degreesOfFreedom: df,
            summary: String(format: "χ²(%.0f) = %.4f · p = %.4g", df, chiSquare, p),
            assumptions: [assumption],
            alternatives: assumption.isWarning && isTwoByTwo ? [.fisherExact] : [])
    }

    /// Fisher's exact test for a 2×2 table — the answer when the expected
    /// counts are too small for chi-square. Two-sided by the usual convention:
    /// every table at least as unlikely as the observed one.
    public static func fisherExact(_ table: [[Int]]) throws -> StatResult {
        guard table.count == 2, table[0].count == 2, table[1].count == 2 else {
            throw StatError.badShape("Fisher's exact ที่นี่รองรับเฉพาะตาราง 2×2")
        }
        let a = table[0][0], b = table[0][1], c = table[1][0], d = table[1][1]
        let rowOne = a + b, rowTwo = c + d, columnOne = a + c, total = a + b + c + d
        guard total > 0 else { throw StatError.notEnoughData("ตารางว่าง") }

        func logFactorial(_ n: Int) -> Double { lgamma(Double(n) + 1) }
        func probability(_ x: Int) -> Double {
            let y = columnOne - x
            guard x >= 0, y >= 0, rowOne - x >= 0, rowTwo - y >= 0 else { return 0 }
            return exp(logFactorial(rowOne) + logFactorial(rowTwo)
                       + logFactorial(columnOne) + logFactorial(total - columnOne)
                       - logFactorial(total) - logFactorial(x) - logFactorial(rowOne - x)
                       - logFactorial(y) - logFactorial(rowTwo - y))
        }
        let observed = probability(a)
        var p = 0.0
        for x in max(0, columnOne - rowTwo)...min(columnOne, rowOne) {
            let candidate = probability(x)
            if candidate <= observed * (1 + 1e-7) { p += candidate }
        }
        let oddsRatio = Double(a * d) / Double(max(b * c, 1))
        return StatResult(
            test: .fisherExact, statistic: oddsRatio, pValue: min(1, p), degreesOfFreedom: nil,
            summary: String(format: "odds ratio ≈ %.4g · p = %.4g (สองทาง)", oddsRatio, min(1, p)),
            // Exact by construction: there is no large-sample approximation
            // here to be wrong about.
            assumptions: [AssumptionCheck(name: "ไม่มีข้อสมมติเรื่องขนาดตัวอย่าง",
                                          wasChecked: true, passed: true,
                                          statistic: nil, pValue: nil,
                                          detail: "คำนวณความน่าจะเป็นตรงจากตาราง ไม่ใช่การประมาณ")],
            alternatives: [])
    }

    // MARK: - the non-parametric alternatives

    /// Mann–Whitney U, normal approximation with a tie correction. The gate's
    /// answer to a t-test on data that is not normal.
    public static func mannWhitney(_ a: [Double], _ b: [Double]) throws -> StatResult {
        guard a.count >= 2, b.count >= 2 else {
            throw StatError.notEnoughData("ต้องมีอย่างน้อยกลุ่มละ 2 ค่า")
        }
        let combined = a + b
        let ranks = Statistics.ranks(combined)
        let rankSumA = ranks.prefix(a.count).reduce(0, +)
        let nA = Double(a.count), nB = Double(b.count), n = nA + nB
        let u = rankSumA - nA * (nA + 1) / 2
        let mean = nA * nB / 2
        let ties = Statistics.tieBlocks(combined)
            .reduce(0.0) { $0 + Double($1 * $1 * $1 - $1) }
        let variance = nA * nB / 12 * ((n + 1) - ties / (n * (n - 1)))
        let z = (u - mean - (u > mean ? 0.5 : -0.5)) / variance.squareRoot()
        let p = 2 * (1 - Statistics.normalCDF(abs(z)))
        return StatResult(
            test: .mannWhitney, statistic: u, pValue: min(1, p), degreesOfFreedom: nil,
            summary: String(format: "U = %.1f · z = %.4f · p = %.4g (ประมาณด้วยปกติ แก้ค่าซ้ำแล้ว)",
                            u, z, min(1, p)),
            assumptions: [AssumptionCheck(
                name: "ไม่ต้องการการแจกแจงปกติ",
                wasChecked: true, passed: true, statistic: nil, pValue: nil,
                detail: "ทดสอบจากอันดับ จึงไม่ขึ้นกับรูปร่างการแจกแจง")],
            alternatives: [])
    }

    public static func wilcoxonSignedRank(_ before: [Double], _ after: [Double]) throws -> StatResult {
        guard before.count == after.count else {
            throw StatError.badShape("ข้อมูลจับคู่ต้องมีจำนวนเท่ากัน")
        }
        // Zero differences carry no information about direction and are
        // dropped, which is the standard treatment and changes n.
        let differences = zip(after, before).map { $0 - $1 }.filter { $0 != 0 }
        guard differences.count >= 2 else {
            throw StatError.notEnoughData("ต้องมีคู่ที่ค่าต่างกันอย่างน้อย 2 คู่")
        }
        let ranks = Statistics.ranks(differences.map { abs($0) })
        let positive = zip(differences, ranks).reduce(0.0) { $0 + ($1.0 > 0 ? $1.1 : 0) }
        let n = Double(differences.count)
        let mean = n * (n + 1) / 4
        let variance = n * (n + 1) * (2 * n + 1) / 24
        let z = (positive - mean) / variance.squareRoot()
        let p = 2 * (1 - Statistics.normalCDF(abs(z)))
        return StatResult(
            test: .wilcoxonSignedRank, statistic: positive, pValue: min(1, p),
            degreesOfFreedom: nil,
            summary: String(format: "W⁺ = %.1f · z = %.4f · p = %.4g (ใช้ %d คู่ที่ต่างกัน)",
                            positive, z, min(1, p), differences.count),
            assumptions: [AssumptionCheck(
                name: "ไม่ต้องการการแจกแจงปกติ",
                wasChecked: true, passed: true, statistic: nil, pValue: nil,
                detail: "ทดสอบจากอันดับของผลต่าง")],
            alternatives: [])
    }

    public static func kruskalWallis(_ groups: [[Double]]) throws -> StatResult {
        guard groups.count >= 2, groups.allSatisfy({ !$0.isEmpty }) else {
            throw StatError.notEnoughData("ต้องมีอย่างน้อย 2 กลุ่มที่ไม่ว่าง")
        }
        let combined = groups.flatMap { $0 }
        let ranks = Statistics.ranks(combined)
        let n = Double(combined.count)
        var offset = 0
        var sum = 0.0
        for group in groups {
            let slice = ranks[offset..<(offset + group.count)]
            let rankSum = slice.reduce(0, +)
            sum += rankSum * rankSum / Double(group.count)
            offset += group.count
        }
        var h = 12 / (n * (n + 1)) * sum - 3 * (n + 1)
        let ties = Statistics.tieBlocks(combined).reduce(0.0) { $0 + Double($1 * $1 * $1 - $1) }
        if ties > 0 { h /= 1 - ties / (n * n * n - n) }
        let df = Double(groups.count - 1)
        let p = Statistics.chiSquarePValue(h, degreesOfFreedom: df)
        return StatResult(
            test: .kruskalWallis, statistic: h, pValue: p, degreesOfFreedom: df,
            summary: String(format: "H(%.0f) = %.4f · p = %.4g", df, h, p),
            assumptions: [AssumptionCheck(
                name: "ไม่ต้องการการแจกแจงปกติ",
                wasChecked: true, passed: true, statistic: nil, pValue: nil,
                detail: "ทดสอบจากอันดับรวมทุกกลุ่ม")],
            alternatives: [])
    }

    // MARK: - regression

    /// Linear regression, with §12.3's three checks: multicollinearity,
    /// linearity, and the residual distribution.
    public static func linearRegression(y: [Double], predictors: [[Double]],
                                        names: [String] = []) throws -> StatResult {
        guard let fit = Statistics.leastSquares(y: y, predictors: predictors) else {
            throw StatError.notEnoughData("จำนวนแถวต้องมากกว่าจำนวนตัวแปร และตัวแปรต้องไม่ซ้ำกันพอดี")
        }
        let labels = names.count == predictors.count
            ? names : (1...max(predictors.count, 1)).map { "x\($0)" }

        var assumptions: [AssumptionCheck] = []
        assumptions.append(multicollinearity(predictors, names: labels))
        assumptions.append(linearity(fit))
        assumptions.append(normality(of: fit.residuals, named: "ส่วนเหลือ (residual)"))

        let terms = zip(labels, fit.coefficients.dropFirst()).map { name, value in
            String(format: "%@ = %.4g", name, value)
        }.joined(separator: " · ")
        return StatResult(
            test: .linearRegression,
            statistic: fit.rSquared,
            // The reported p is for the model's slope terms as a whole
            // (F-test), not for any one coefficient.
            pValue: modelPValue(fit, predictorCount: predictors.count),
            degreesOfFreedom: Double(fit.degreesOfFreedom),
            summary: String(format: "R² = %.4f · ค่าคงที่ %.4g · %@",
                            fit.rSquared, fit.coefficients[0], terms),
            assumptions: assumptions,
            // A curved relationship is not fixed by a different test — it is
            // fixed by a different model, which is a plan-level decision.
            alternatives: [])
    }

    /// Logistic regression. §12.3 lists multicollinearity for it too; what it
    /// does *not* get here is a linearity-of-the-logit check, and that is said
    /// out loud rather than left out.
    public static func logisticRegression(y: [Double], predictors: [[Double]],
                                          names: [String] = []) throws -> StatResult {
        guard let fit = Statistics.logistic(y: y, predictors: predictors) else {
            throw StatError.badShape("ผลลัพธ์ต้องเป็น 0/1 และแถวต้องมากกว่าจำนวนตัวแปร")
        }
        let labels = names.count == predictors.count
            ? names : (1...max(predictors.count, 1)).map { "x\($0)" }

        var assumptions = [multicollinearity(predictors, names: labels)]
        assumptions.append(AssumptionCheck(
            name: "ไม่มีการแยกกลุ่มสมบูรณ์ (separation)",
            wasChecked: true,
            passed: !fit.separated,
            statistic: nil, pValue: nil,
            detail: fit.separated
                ? "ตัวแปรบางตัวทำนายผลลัพธ์ได้สมบูรณ์ ค่าสัมประสิทธิ์จึงวิ่งไปไม่สิ้นสุด "
                  + "— ตัวเลขที่ได้ไม่ใช่ขนาดของผล"
                : "ค่าประมาณลู่เข้าใน \(fit.iterations) รอบ"))
        assumptions.append(AssumptionCheck(
            name: "ความเป็นเส้นตรงของ logit",
            wasChecked: false, passed: false, statistic: nil, pValue: nil,
            detail: "โมดูลนี้ยังตรวจไม่ได้ — ต้องดูด้วยวิธี Box–Tidwell หรือกราฟก่อนเชื่อผล"))

        // Wald test per coefficient: z = β/SE, from the same inverse the fit
        // already produced. Reported per predictor rather than as one number —
        // a model-level p-value would say nothing about which variable did the
        // work. Meaningless under separation, and said so above.
        let terms = zip(labels, zip(fit.coefficients.dropFirst(),
                                    fit.standardErrors.dropFirst()))
            .map { name, estimate in
                let (coefficient, error) = estimate
                guard error.isFinite, error > 0 else {
                    return String(format: "%@: OR = %.4g (คำนวณ p ไม่ได้)", name, exp(coefficient))
                }
                let z = coefficient / error
                let p = 2 * (1 - Statistics.normalCDF(abs(z)))
                return String(format: "%@: OR = %.4g (95%% CI %.4g–%.4g) · p = %.4g",
                              name, exp(coefficient),
                              exp(coefficient - 1.96 * error), exp(coefficient + 1.96 * error), p)
            }
            .joined(separator: " · ")
        let leading = Array(zip(fit.coefficients.dropFirst(), fit.standardErrors.dropFirst())).first
        let leadingZ = leading.flatMap { $1.isFinite && $1 > 0 ? $0 / $1 : nil }
        return StatResult(
            test: .logisticRegression,
            statistic: fit.coefficients.dropFirst().first ?? .nan,
            pValue: leadingZ.map { 2 * (1 - Statistics.normalCDF(abs($0))) } ?? .nan,
            degreesOfFreedom: nil,
            summary: terms,
            assumptions: assumptions,
            alternatives: [])
    }

    /// Counts against predictors, with the assumption Poisson makes checked
    /// and the alternative offered by name (P19.4).
    ///
    /// The failure this exists for is quiet: overdispersed counts still produce
    /// a believable coefficient, and only the standard error is wrong — too
    /// small, which turns a null effect into a finding. So the check runs every
    /// time, and when it fails the gate proposes a model it can actually run
    /// rather than a suggestion the user has to take elsewhere (§12.3).
    public static func countRegression(_ counts: [Double],
                                       predictors: [[Double]],
                                       names: [String] = []) throws -> StatResult {
        let fit = try CountModels.poisson(counts: counts, predictors: predictors)
        let dispersion = CountModels.overdispersion(counts: counts, predictors: predictors,
                                                    fit: fit)
        let terms = zip(fit.coefficients.dropFirst(), fit.standardErrors.dropFirst())
            .enumerated()
            .map { index, pair in
                let name = index < names.count ? names[index] : "x\(index + 1)"
                return String(format: "%@: rate ratio %.4f (SE ของ log = %.4f)",
                              name, exp(pair.0), pair.1)
            }
            .joined(separator: " · ")

        let leading = Array(zip(fit.coefficients.dropFirst(),
                                fit.standardErrors.dropFirst())).first
        let z = leading.flatMap { $1 > 0 ? $0 / $1 : nil }
        return StatResult(
            test: .poissonRegression,
            statistic: fit.coefficients.dropFirst().first ?? .nan,
            pValue: z.map { 2 * (1 - Statistics.normalCDF(abs($0))) } ?? .nan,
            degreesOfFreedom: nil,
            summary: terms,
            assumptions: [dispersion],
            // Named only when it is the answer: a gate that always lists every
            // other test teaches people to ignore the list.
            alternatives: dispersion.passed ? [] : [.negativeBinomialRegression])
    }

    /// Two survival curves compared, with the assumption the comparison rests
    /// on checked (P19.3).
    ///
    /// **This used to refuse, and before that it lied.** The first version
    /// returned a `StatResult` carrying `NaN` and whatever summary the caller
    /// passed in — a claim wearing a result's clothes. P19.0 made it throw. It
    /// now computes, and the throw stays for the case that has not been built:
    /// `StatError.notImplemented` is still the answer for anything in §12.3's
    /// table that this module cannot do.
    ///
    /// The log-rank test is the answer; the Cox fit is run alongside it to get
    /// the hazard ratio a paper reports and to make the proportional-hazards
    /// check possible at all — a comparison whose assumption was never tested
    /// is the thing §12.3 exists to stop.
    public static func survival(_ a: [SurvivalObservation],
                                _ b: [SurvivalObservation]) throws -> StatResult {
        let test = try Survival.logRank(a, b)
        let all = a + b
        let group = [Double](repeating: 0, count: a.count)
            + [Double](repeating: 1, count: b.count)

        // A Cox fit that will not converge does not stop the comparison: the
        // log-rank result stands on its own, and the assumption is then
        // reported as unchecked rather than as passed.
        guard let fit = try? Survival.cox(all, covariates: [group]) else {
            return StatResult(
                test: .survival, statistic: test.statistic, pValue: test.pValue,
                degreesOfFreedom: 1, summary: test.summary,
                assumptions: [AssumptionCheck(
                    name: "proportional hazards", wasChecked: false, passed: false,
                    statistic: nil, pValue: nil,
                    detail: "โมเดล Cox ไม่ลู่เข้า จึงยังตรวจสมมติฐานไม่ได้ — ไม่ใช่ว่าผ่าน")],
                alternatives: [])
        }
        let hazard = fit.hazardRatios[0]
        let interval = fit.confidenceIntervals[0]
        return StatResult(
            test: .survival,
            statistic: test.statistic,
            pValue: test.pValue,
            degreesOfFreedom: 1,
            summary: test.summary + String(format: " · HR = %.3f (95%% CI %.3f–%.3f)",
                                           hazard, interval.lower, interval.upper),
            assumptions: [Survival.proportionalHazards(all, covariates: [group], fit: fit)],
            // No alternative *test* to offer: when proportional hazards fails
            // the answer is to report by period or to let the coefficient vary
            // with time, and neither is another row in this enum. The
            // assumption's own detail says so, which is where a reader looks.
            alternatives: [])
    }

    // MARK: - the checks themselves

    static func normality(of values: [Double], named name: String) -> AssumptionCheck {
        guard let test = Statistics.shapiroWilk(values) else {
            return AssumptionCheck(
                name: "การแจกแจงปกติของ\(name)",
                wasChecked: false, passed: false, statistic: nil, pValue: nil,
                detail: values.count < 3
                    ? "มีเพียง \(values.count) ค่า — น้อยเกินกว่าจะทดสอบได้"
                    : "ทดสอบไม่ได้ (ค่าทั้งหมดเท่ากัน หรือ n เกิน 5000)")
        }
        let passed = test.pValue >= alpha
        return AssumptionCheck(
            name: "การแจกแจงปกติของ\(name)",
            wasChecked: true, passed: passed,
            statistic: test.w, pValue: test.pValue,
            detail: String(format: passed
                           ? "Shapiro–Wilk W = %.4f, p = %.4g — ไม่พบหลักฐานว่าไม่ปกติ"
                           : "Shapiro–Wilk W = %.4f, p = %.4g — ข้อมูลไม่เข้ากับการแจกแจงปกติ",
                           test.w, test.pValue))
    }

    /// Levene's test in the Brown–Forsythe form (deviations from the median),
    /// which is the version that survives non-normal data — and non-normal data
    /// is exactly the situation this is being asked about.
    static func equalVariance(_ groups: [[Double]]) -> AssumptionCheck {
        let sizes = groups.map(\.count)
        guard groups.count >= 2, sizes.allSatisfy({ $0 >= 2 }) else {
            return AssumptionCheck(name: "ความแปรปรวนเท่ากันระหว่างกลุ่ม",
                                   wasChecked: false, passed: false,
                                   statistic: nil, pValue: nil,
                                   detail: "ต้องมีอย่างน้อยกลุ่มละ 2 ค่า")
        }
        let deviations = groups.map { group -> [Double] in
            let median = Statistics.median(group)
            return group.map { abs($0 - median) }
        }
        let all = deviations.flatMap { $0 }
        let grandMean = Statistics.mean(all)
        let between = deviations.reduce(0.0) { total, group in
            let difference = Statistics.mean(group) - grandMean
            return total + Double(group.count) * difference * difference
        }
        let within = deviations.reduce(0.0) { total, group in
            let average = Statistics.mean(group)
            return total + group.reduce(0) { $0 + ($1 - average) * ($1 - average) }
        }
        let d1 = Double(groups.count - 1)
        let d2 = Double(all.count - groups.count)
        guard within > 0, d2 > 0 else {
            return AssumptionCheck(name: "ความแปรปรวนเท่ากันระหว่างกลุ่ม",
                                   wasChecked: false, passed: false,
                                   statistic: nil, pValue: nil,
                                   detail: "ค่าภายในกลุ่มไม่กระจายเลย ทดสอบไม่ได้")
        }
        let w = (between / d1) / (within / d2)
        let p = Statistics.fTestPValue(f: w, d1: d1, d2: d2)
        let passed = p >= alpha
        let spread = groups.map { String(format: "%.4g", Statistics.variance($0)) }
            .joined(separator: ", ")
        return AssumptionCheck(
            name: "ความแปรปรวนเท่ากันระหว่างกลุ่ม",
            wasChecked: true, passed: passed, statistic: w, pValue: p,
            detail: String(format: "Levene (Brown–Forsythe) W = %.4f, p = %.4g · ความแปรปรวนรายกลุ่ม: %@",
                           w, p, spread)
                + (passed ? "" : " — ใช้ Welch แทน Student หรือเปลี่ยนไปใช้วิธีอันดับ"))
    }

    static func multicollinearity(_ predictors: [[Double]], names: [String]) -> AssumptionCheck {
        guard predictors.count > 1 else {
            return AssumptionCheck(name: "ไม่มี multicollinearity",
                                   wasChecked: true, passed: true, statistic: nil, pValue: nil,
                                   detail: "มีตัวแปรต้นเดียว จึงไม่มีอะไรให้ซ้ำซ้อน")
        }
        let factors = Statistics.varianceInflationFactors(predictors)
        let worst = factors.max() ?? 1
        // VIF > 10 is the conventional line; above it the coefficient of a
        // predictor is mostly telling you about the other predictors.
        let passed = worst <= 10
        let listed = zip(names, factors).map { String(format: "%@ VIF = %.2f", $0, $1) }
            .joined(separator: " · ")
        return AssumptionCheck(
            name: "ไม่มี multicollinearity",
            wasChecked: true, passed: passed, statistic: worst, pValue: nil,
            detail: listed + (passed ? "" : " — VIF เกิน 10 แปลว่าตัวแปรอธิบายกันเอง "
                              + "ค่าสัมประสิทธิ์แต่ละตัวจึงตีความแยกไม่ได้"))
    }

    /// Curvature, by Tukey's idea: if the relationship is really a line, the
    /// squared fitted values have nothing left to explain in the residuals.
    static func linearity(_ fit: Statistics.RegressionFit) -> AssumptionCheck {
        let squares = fit.fitted.map { $0 * $0 }
        guard let extra = Statistics.leastSquares(y: fit.residuals, predictors: [squares]),
              extra.standardErrors.count > 1, extra.standardErrors[1] > 0 else {
            return AssumptionCheck(name: "ความสัมพันธ์เป็นเส้นตรง",
                                   wasChecked: false, passed: false,
                                   statistic: nil, pValue: nil,
                                   detail: "ตรวจไม่ได้กับข้อมูลชุดนี้")
        }
        let t = extra.coefficients[1] / extra.standardErrors[1]
        let p = Statistics.tTestPValue(t: t, degreesOfFreedom: Double(extra.degreesOfFreedom))
        let passed = p >= alpha
        return AssumptionCheck(
            name: "ความสัมพันธ์เป็นเส้นตรง",
            wasChecked: true, passed: passed, statistic: t, pValue: p,
            detail: String(format: "Tukey non-additivity t = %.4f, p = %.4g", t, p)
                + (passed ? " — ไม่พบความโค้งที่เหลืออยู่"
                          : " — ยังมีความโค้งเหลืออยู่ในส่วนเหลือ โมเดลเส้นตรงยังไม่พอ"))
    }

    /// The F-test for "does this model explain anything at all".
    private static func modelPValue(_ fit: Statistics.RegressionFit,
                                    predictorCount: Int) -> Double {
        let d1 = Double(predictorCount)
        let d2 = Double(fit.degreesOfFreedom)
        guard d1 > 0, d2 > 0, fit.rSquared.isFinite, fit.rSquared < 1 else { return .nan }
        let f = (fit.rSquared / d1) / ((1 - fit.rSquared) / d2)
        return Statistics.fTestPValue(f: f, d1: d1, d2: d2)
    }
}
