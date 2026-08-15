import Foundation

// ─────────────────────────────────────────────────────────────
// What a diagnostic test is worth (ARCHITECTURE §12.6.1, P19.2).
//
// **The thing this module exists to stop**: a test with 90% sensitivity and 90%
// specificity, applied where 1% of people have the disease, is right about a
// positive result **8% of the time**. Sensitivity and specificity are
// properties of the test; predictive values are properties of the test *and the
// population it is used in*, and reading the first pair as if it were the
// second is the most consequential arithmetic error in clinical medicine.
//
// So `predictiveValues` cannot be called without a prevalence — there is no
// default and no overload that omits it — and it hands back the prevalence it
// used, so a screen showing a PPV has the number it is conditional on and
// cannot print one without the other.
// ─────────────────────────────────────────────────────────────

/// A test's own properties, from a study where the truth was known for
/// everybody.
public struct DiagnosticTable: Sendable, Equatable {
    public let truePositives: Int
    public let falseNegatives: Int
    public let falsePositives: Int
    public let trueNegatives: Int

    public init(truePositives: Int, falseNegatives: Int,
                falsePositives: Int, trueNegatives: Int) {
        self.truePositives = truePositives
        self.falseNegatives = falseNegatives
        self.falsePositives = falsePositives
        self.trueNegatives = trueNegatives
    }

    public var diseased: Int { truePositives + falseNegatives }
    public var well: Int { falsePositives + trueNegatives }

    /// The prevalence **in the study sample**, which is very often not the
    /// prevalence where the test will be used: case–control designs choose it,
    /// and screening studies enrich it. Offered as a starting point and named
    /// so it cannot be mistaken for the population's.
    public var samplePrevalence: Double {
        Double(diseased) / Double(diseased + well)
    }
}

public struct PredictiveValues: Sendable, Equatable {
    /// Probability that someone with a positive result has the disease.
    public let positive: Double
    /// Probability that someone with a negative result does not.
    public let negative: Double
    /// The prevalence these were computed at. Carried with them because a
    /// predictive value without it is not a number anybody can use.
    public let atPrevalence: Double
}

public enum DiagnosticAccuracy {

    /// Sensitivity — of the people who have it, how many the test finds.
    /// Wilson interval, because a study with 50 diseased people is a small
    /// study however clean its point estimate looks.
    public static func sensitivity(_ table: DiagnosticTable) throws -> Estimate {
        guard table.diseased > 0 else {
            throw StatError.notEnoughData("ไม่มีผู้ป่วยจริงในชุดข้อมูล — คำนวณ sensitivity ไม่ได้")
        }
        return Epidemiology.wilson(successes: table.truePositives, trials: table.diseased)
    }

    /// Specificity — of the people who do not have it, how many the test clears.
    public static func specificity(_ table: DiagnosticTable) throws -> Estimate {
        guard table.well > 0 else {
            throw StatError.notEnoughData("ไม่มีคนปกติในชุดข้อมูล — คำนวณ specificity ไม่ได้")
        }
        return Epidemiology.wilson(successes: table.trueNegatives, trials: table.well)
    }

    /// Positive and negative predictive value **at a stated prevalence**.
    ///
    /// By Bayes rather than from the table's own cells, and that is the whole
    /// point: reading PPV straight off a study's 2×2 answers "in that study",
    /// which is a different question from the one being asked whenever the test
    /// is used somewhere else.
    ///
    /// - Parameter prevalence: how common the disease is **where the test will
    ///   be used**. Required. `DiagnosticTable.samplePrevalence` is available
    ///   for the study's own, but naming it forces the choice to be made.
    public static func predictiveValues(_ table: DiagnosticTable,
                                        prevalence: Double) throws -> PredictiveValues {
        guard prevalence > 0, prevalence < 1 else {
            throw StatError.badShape("ความชุกต้องอยู่ระหว่าง 0 ถึง 1 (ไม่รวมปลายทั้งสอง)")
        }
        let sensitivity = try self.sensitivity(table).value
        let specificity = try self.specificity(table).value

        let truePositiveShare = sensitivity * prevalence
        let falsePositiveShare = (1 - specificity) * (1 - prevalence)
        let trueNegativeShare = specificity * (1 - prevalence)
        let falseNegativeShare = (1 - sensitivity) * prevalence

        guard truePositiveShare + falsePositiveShare > 0,
              trueNegativeShare + falseNegativeShare > 0 else {
            throw StatError.notEnoughData("การทดสอบนี้ไม่แยกอะไรเลย — ค่าทำนายคำนวณไม่ได้")
        }
        return PredictiveValues(
            positive: truePositiveShare / (truePositiveShare + falsePositiveShare),
            negative: trueNegativeShare / (trueNegativeShare + falseNegativeShare),
            atPrevalence: prevalence)
    }

    /// Likelihood ratios — how much a result moves the odds, and the pair that
    /// does *not* depend on prevalence, which is what makes them portable
    /// between settings in a way PPV never is.
    public static func likelihoodRatios(_ table: DiagnosticTable) throws
        -> (positive: Double, negative: Double) {
        let sensitivity = try self.sensitivity(table).value
        let specificity = try self.specificity(table).value
        guard specificity < 1 else {
            throw StatError.notEnoughData(
                "specificity เป็น 1 พอดี — LR+ เป็นอนันต์ ซึ่งเป็นผลของขนาดตัวอย่าง ไม่ใช่ของการทดสอบ")
        }
        guard specificity > 0 else {
            throw StatError.notEnoughData("specificity เป็นศูนย์ — LR− คำนวณไม่ได้")
        }
        return (positive: sensitivity / (1 - specificity),
                negative: (1 - sensitivity) / specificity)
    }

    // MARK: - ROC

    /// Area under the ROC curve, with the Hanley–McNeil interval.
    ///
    /// Computed as the Mann–Whitney statistic — the probability that a randomly
    /// chosen diseased person scores above a randomly chosen well one — because
    /// that is what the area *is*, and computing it that way needs no threshold
    /// grid and no interpolation between points that were never observed. Ties
    /// count a half, which is what a test that cannot separate two people has
    /// earned.
    ///
    /// - Parameters:
    ///   - scores: the test's output, higher meaning more likely diseased.
    ///   - labels: true for diseased.
    public static func areaUnderROC(scores: [Double], labels: [Bool]) throws -> Estimate {
        guard scores.count == labels.count else {
            throw StatError.badShape("จำนวนคะแนนกับป้ายกำกับไม่เท่ากัน")
        }
        let positives = zip(scores, labels).filter { $0.1 }.map(\.0)
        let negatives = zip(scores, labels).filter { !$0.1 }.map(\.0)
        guard !positives.isEmpty, !negatives.isEmpty else {
            throw StatError.notEnoughData("ต้องมีทั้งกลุ่มที่เป็นโรคและไม่เป็นโรค")
        }

        var wins = 0.0
        for positive in positives {
            for negative in negatives {
                if positive > negative { wins += 1 } else if positive == negative { wins += 0.5 }
            }
        }
        let n1 = Double(positives.count), n2 = Double(negatives.count)
        let area = wins / (n1 * n2)

        // Hanley–McNeil: the variance of an area, which depends on the area
        // itself as well as on the two group sizes.
        let q1 = area / (2 - area)
        let q2 = 2 * area * area / (1 + area)
        let variance = (area * (1 - area)
                        + (n1 - 1) * (q1 - area * area)
                        + (n2 - 1) * (q2 - area * area)) / (n1 * n2)
        let halfWidth = Epidemiology.z95 * variance.squareRoot()
        // Clamped, because an area cannot exceed 1 and a normal interval on a
        // small sample can. Clamping is honest here in a way it would not be
        // for a ratio: the parameter genuinely lives in [0, 1].
        return Estimate(value: area,
                        lower: max(0, area - halfWidth),
                        upper: min(1, area + halfWidth),
                        method: "Hanley–McNeil 95% CI (พื้นที่ = Mann–Whitney)")
    }
}
