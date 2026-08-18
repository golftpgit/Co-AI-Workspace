import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// The chapters of Bland's *An Introduction to Medical Statistics* the gate
// could not answer: correlation and agreement (11–12, 20), paired and ordered
// cross-tabulations (13), and multiplicity (22).
//
// Expected values are either arithmetic anybody can redo from the numbers
// printed here, or computed with a separate implementation of the same formula
// outside this codebase.
// ─────────────────────────────────────────────────────────────

private func isClose(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-4) -> Bool {
    abs(actual - expected) <= tolerance
}

@Suite("Correlation and agreement (Bland ch. 11–12, 20)")
struct CorrelationTests {

    private let height = [1.52, 1.60, 1.65, 1.70, 1.75, 1.80, 1.85, 1.90]
    private let weight = [48.0, 55.0, 58.0, 65.0, 70.0, 78.0, 84.0, 92.0]

    @Test("Pearson r comes with an interval that cannot run past 1")
    func pearsonHasFisherInterval() throws {
        let r = try Reliability.correlation(height, weight)
        // Checked against the same formula computed outside this codebase.
        #expect(isClose(r.coefficient, 0.992083, 1e-5))
        // Fisher's z is why: a symmetric interval around 0.997 would reach
        // past 1, which is not a correlation.
        #expect(r.upper < 1.0)
        #expect(r.lower > 0.9)
        #expect(r.pValue < 0.001)
    }

    /// The mistake Bland's chapter 20 exists for.
    @Test("a perfect correlation says out loud that it is not agreement")
    func correlationIsNotAgreement() throws {
        let doubled = height.map { $0 * 2 }
        let r = try Reliability.correlation(height, doubled)
        #expect(isClose(r.coefficient, 1.0, 1e-9))
        #expect(r.summary.contains("correlation is not agreement"))
        #expect(r.summary.contains("Bland–Altman"))
    }

    /// Spearman is Pearson on the ranks, which is why a monotone but bent
    /// relationship is 1.0 for one and less for the other.
    @Test("Spearman answers rank order, not shape")
    func spearmanUsesRanks() throws {
        let x = [1.0, 2, 3, 4, 5, 6]
        let curved = x.map { $0 * $0 * $0 }
        #expect(isClose(try Reliability.correlation(x, curved, kind: .spearman).coefficient, 1.0, 1e-9))
        #expect(try Reliability.correlation(x, curved).coefficient < 1.0)
    }

    @Test("too few pairs, or a column with one value, is refused")
    func correlationRefusals() {
        #expect(throws: StatError.self) {
            _ = try Reliability.correlation([1, 2, 3], [1, 2, 3])
        }
        #expect(throws: StatError.self) {
            _ = try Reliability.correlation([1, 1, 1, 1], [1, 2, 3, 4])
        }
        #expect(throws: StatError.self) {
            _ = try Reliability.correlation([1, 2, 3, 4], [1, 2, 3])
        }
    }

    /// Raw agreement flatters every rare condition: two raters who both call
    /// almost everything negative agree most of the time by chance.
    @Test("kappa takes the chance agreement out")
    func kappaRemovesChance() throws {
        // 90 both-negative, 2 both-positive, 4 + 4 disagreements.
        let a = Array(repeating: 0, count: 94) + Array(repeating: 1, count: 6)
        var b = Array(repeating: 0, count: 90) + Array(repeating: 1, count: 4)
        b += Array(repeating: 0, count: 4) + Array(repeating: 1, count: 2)

        let k = try Reliability.kappa(a, b)
        #expect(k.observedAgreement > 0.9, "raw agreement is high, as it always is here")
        #expect(k.value < k.observedAgreement, "chance agreement was not removed")
        #expect(k.interpretation.contains("chance alone would have produced"))
    }

    @Test("weighted kappa treats a near miss as a near miss")
    func weightedKappaUsesDistance() throws {
        // Ratings on a 1–3 scale where the disagreements are all one step.
        let a = [1, 1, 2, 2, 3, 3, 1, 2, 3, 2]
        let b = [1, 2, 2, 3, 3, 2, 1, 2, 3, 3]
        let plain = try Reliability.kappa(a, b)
        let weighted = try Reliability.kappa(a, b, ordered: true)
        #expect(weighted.value > plain.value)
        #expect(weighted.weighted)
        #expect(weighted.interpretation.contains("weighted"))
    }

    @Test("one category, or ratings of different lengths, is refused")
    func kappaRefusals() {
        #expect(throws: StatError.self) { _ = try Reliability.kappa([1, 1, 1], [1, 1, 1]) }
        #expect(throws: StatError.self) { _ = try Reliability.kappa([1, 2], [1]) }
    }
}

@Suite("Paired and ordered tables (Bland ch. 13)")
struct PairedCategoricalTests {

    /// The pairs that did not change carry no information about change, and a
    /// plain χ² would count them.
    @Test("McNemar uses only the pairs that changed")
    func mcNemarUsesDiscordantPairs() throws {
        let result = try PairedCategorical.mcNemar(bothPositive: 100, changedOneWay: 30,
                                                   changedOtherWay: 12, bothNegative: 200)
        // (|30 − 12| − 1)² / 42 = 289/42 = 6.881
        #expect(isClose(result.statistic, 6.8810, 1e-3))
        #expect(result.pValue < 0.01)
        #expect(result.exact == false)
        #expect(result.summary.contains("did not change are not counted"))
    }

    /// Below 25 discordant pairs the χ² approximation is poor, and choosing
    /// the exact test is the data's job rather than the caller's.
    @Test("few changed pairs switch to the exact test without being asked")
    func smallSamplesGoExact() throws {
        let result = try PairedCategorical.mcNemar(bothPositive: 5, changedOneWay: 8,
                                                   changedOtherWay: 1, bothNegative: 6)
        #expect(result.exact)
        // Two-sided binomial, 1 of 9 at p = 0.5: 2 × (9+1)/512 = 0.0391.
        #expect(isClose(result.pValue, 0.0391, 1e-3))
    }

    @Test("no pair changed is refused rather than answered")
    func nothingChanged() {
        #expect(throws: StatError.self) {
            _ = try PairedCategorical.mcNemar(bothPositive: 10, changedOneWay: 0,
                                              changedOtherWay: 0, bothNegative: 10)
        }
    }

    /// A plain χ² would give the same answer with the columns shuffled.
    @Test("the trend test follows the order of the groups")
    func trendUsesOrdering() throws {
        let doses = [(cases: 5, total: 100), (cases: 12, total: 100),
                     (cases: 20, total: 100), (cases: 31, total: 100)]
        let rising = try PairedCategorical.trend(doses)
        #expect(rising.pValue < 0.001)
        #expect(rising.proportions == [0.05, 0.12, 0.20, 0.31])

        // Same four proportions, no ordering to them: the trend statistic
        // collapses while a χ² would report the same difference as before.
        let shuffled = [(cases: 5, total: 100), (cases: 31, total: 100),
                        (cases: 12, total: 100), (cases: 20, total: 100)]
        #expect(try PairedCategorical.trend(shuffled).statistic < rising.statistic)
    }

    @Test("real doses can be given as scores, because they are not equal steps")
    func unequalScores() throws {
        let groups = [(cases: 5, total: 100), (cases: 12, total: 100), (cases: 60, total: 100)]
        let equal = try PairedCategorical.trend(groups)
        let real = try PairedCategorical.trend(groups, scores: [10, 20, 100])
        #expect(equal.statistic != real.statistic)
    }

    @Test("fewer than three groups, or no cases at all, is refused")
    func trendRefusals() {
        #expect(throws: StatError.self) {
            _ = try PairedCategorical.trend([(cases: 1, total: 10), (cases: 2, total: 10)])
        }
        #expect(throws: StatError.self) {
            _ = try PairedCategorical.trend([(cases: 0, total: 10), (cases: 0, total: 10),
                                             (cases: 0, total: 10)])
        }
    }
}

@Suite("Testing more than one thing (Bland ch. 22)")
struct MultiplicityTests {

    private let tests = [("อาการปวด", 0.01), ("การนอน", 0.04), ("ความวิตกกังวล", 0.03),
                         ("คุณภาพชีวิต", 0.20), ("ค่าใช้จ่าย", 0.60)]

    @Test("Bonferroni multiplies by how many tests there were")
    func bonferroni() throws {
        let report = try MultipleComparisons.adjust(tests, method: .bonferroni)
        #expect(isClose(report.comparisons[0].adjusted, 0.05))
        #expect(isClose(report.comparisons[1].adjusted, 0.20))
        #expect(report.survivors.count == 1)
    }

    /// Holm controls the same thing as Bonferroni and is never worse, which is
    /// the reason it is the default.
    @Test("Holm keeps at least what Bonferroni keeps")
    func holmIsNeverWorse() throws {
        let holm = try MultipleComparisons.adjust(tests, method: .holm)
        let bonferroni = try MultipleComparisons.adjust(tests, method: .bonferroni)
        for (a, b) in zip(holm.comparisons, bonferroni.comparisons) {
            #expect(a.adjusted <= b.adjusted + 1e-12)
        }
        #expect(holm.survivors.count >= bonferroni.survivors.count)
    }

    /// Without the running maximum a later test can come out more significant
    /// than an earlier smaller one, which is not a thing.
    @Test("adjusted values never decrease as the raw ones increase")
    func monotone() throws {
        for method in MultiplicityReport.Method.allCases {
            let report = try MultipleComparisons.adjust(tests, method: method)
            let sorted = report.comparisons.sorted { $0.raw < $1.raw }
            for pair in zip(sorted, sorted.dropFirst()) {
                #expect(pair.0.adjusted <= pair.1.adjusted + 1e-12,
                        "\(method) produced a non-monotone adjustment")
            }
        }
    }

    /// The number a reader cannot recover from a list of p-values, and the one
    /// that decides what they mean.
    @Test("the report says how many tests were run and what was lost")
    func summaryNamesTheCount() throws {
        let report = try MultipleComparisons.adjust(tests, method: .holm)
        #expect(report.summary.contains("5"))
        #expect(report.summary.contains("did not survive the correction"))
    }

    @Test("FDR keeps more than Holm, and says it controls something different")
    func fdrIsALooserPromise() throws {
        let fdr = try MultipleComparisons.adjust(tests, method: .benjaminiHochberg)
        let holm = try MultipleComparisons.adjust(tests, method: .holm)
        #expect(fdr.survivors.count >= holm.survivors.count)
        #expect(fdr.method.controls.contains("the **share**"))
        #expect(holm.method.controls.contains("the chance of **any**"))
    }

    @Test("an empty set, or a p outside 0…1, is refused")
    func multiplicityRefusals() {
        #expect(throws: StatError.self) { _ = try MultipleComparisons.adjust([]) }
        #expect(throws: StatError.self) {
            _ = try MultipleComparisons.adjust([("x", 1.4)])
        }
    }
}
