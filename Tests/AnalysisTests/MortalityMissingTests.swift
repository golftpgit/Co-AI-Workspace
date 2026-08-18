import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// The last two chapters of Bland the gate could not answer: what is not there
// (ch. 19) and mortality statistics (ch. 21).
// ─────────────────────────────────────────────────────────────

private func isClose(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-3) -> Bool {
    abs(actual - expected) <= tolerance
}

@Suite("What is not there (Bland ch. 19)")
struct MissingDataTests {

    private let columns: [(name: String, values: [Double?])] = [
        ("อายุ", [40, 52, 61, 45, nil, 58, 49, 66]),
        ("คะแนนความเครียด", [12, nil, 18, 9, 14, nil, 11, 20]),
        ("ชั่วโมงนอน", [7, 6, nil, 8, 5, 7, 6, 6]),
    ]

    /// The number that surprises people: dropping incomplete rows removes far
    /// more of the sample than any single column's gap suggests.
    @Test("complete-case analysis loses more than the worst column")
    func completeCasesLoseMost() throws {
        let report = try MissingData.describe(columns)
        #expect(report.totalRows == 8)
        // Rows 1, 2, 4 and 5 each lose something; four rows survive.
        #expect(report.completeRows == 4)
        let worst = try #require(report.columns.max { $0.share < $1.share })
        #expect(worst.missing == 2)
        // Half the sample gone, from columns that are individually 12–25% missing.
        #expect(report.completeShare == 0.5)
        #expect(report.summary.contains("throws away 4 people"))
    }

    @Test("columns of different lengths, or no columns at all, is refused")
    func describeRefusals() {
        #expect(throws: StatError.self) { _ = try MissingData.describe([]) }
        #expect(throws: StatError.self) {
            _ = try MissingData.describe([("a", [1, nil]), ("b", [1, 2, 3])])
        }
    }

    /// MCAR cannot be proved from the data — the reason somebody dropped out is
    /// usually not in the file — but the opposite can often be seen.
    @Test("missingness related to another variable is reported as not random")
    func relatedMissingnessIsFound() throws {
        // The people missing an outcome are systematically older.
        let outcome: [Double?] = [10, 12, 11, 13, nil, nil, nil, nil, 9, 14]
        let age: [Double?] = [40, 42, 39, 41, 71, 75, 69, 73, 38, 44]
        let signal = try MissingData.signal(missingIn: ("ผลลัพธ์", outcome),
                                            comparedWith: ("อายุ", age))
        #expect(signal.missingCount == 4)
        #expect(signal.meanWhenMissing > signal.meanWhenPresent)
        #expect(signal.looksRelated)
        #expect(signal.summary.contains("the missingness is not random"))
    }

    /// A negative result here is the one people over-read, so the sentence
    /// says what it does not mean.
    @Test("no difference found does not claim the missingness was random")
    func absenceOfEvidenceIsSaidPlainly() throws {
        let outcome: [Double?] = [10, 12, nil, 13, 11, nil, 12, 10]
        let age: [Double?] = [40, 42, 41, 39, 43, 40, 44, 41]
        let signal = try MissingData.signal(missingIn: ("ผลลัพธ์", outcome),
                                            comparedWith: ("อายุ", age))
        #expect(signal.looksRelated == false)
        #expect(signal.summary.contains("does not mean the missingness is random"))
        #expect(signal.summary.contains("MCAR"))
    }

    @Test("too few rows on either side is refused rather than tested")
    func signalNeedsBothSides() {
        let outcome: [Double?] = [1, 2, 3, nil]
        let other: [Double?] = [1, 2, 3, 4]
        #expect(throws: StatError.self) {
            _ = try MissingData.signal(missingIn: ("x", outcome), comparedWith: ("y", other))
        }
    }

    /// Nothing here fills a gap, and that is the point.
    @Test("no function in this file returns imputed values")
    func nothingIsImputed() throws {
        let report = try MissingData.describe(columns)
        // The report counts; it does not hand back a completed dataset.
        #expect(report.columns.map(\.name) == ["อายุ", "คะแนนความเครียด", "ชั่วโมงนอน"])
        #expect(report.columns.reduce(0) { $0 + $1.missing } == 4)
    }
}

@Suite("Mortality statistics (Bland ch. 21)")
struct MortalityTests {

    @Test("an SMR compares deaths seen with deaths the reference rates predict")
    func smrIsIndirectStandardisation() throws {
        // 6 deaths where the reference rates predict 4.
        let result = try Mortality.smr([
            (observed: 2, personTime: 1_000, referenceRate: 0.001),
            (observed: 4, personTime: 1_000, referenceRate: 0.003),
        ])
        #expect(result.observed == 6)
        #expect(isClose(result.expected, 4.0))
        #expect(isClose(result.ratio, 1.5))
        #expect(isClose(result.indexed, 150))
    }

    /// With six deaths a normal interval reaches below zero, and a negative
    /// number of deaths is not a limit.
    @Test("the interval is exact Poisson, so it never runs below zero")
    func intervalIsExact() throws {
        let result = try Mortality.smr([(observed: 6, personTime: 1_000, referenceRate: 0.004)])
        // Computed outside this codebase: χ²(0.025, 12)/2 = 2.2019 and
        // χ²(0.975, 14)/2 = 13.0595, over an expectation of 4.
        #expect(isClose(result.lower, 2.2019 / 4, 1e-3))
        #expect(isClose(result.upper, 13.0595 / 4, 1e-3))
        #expect(result.lower > 0)
        #expect(result.summary.contains("exact"))

        // Zero deaths is a real answer, not an error: the lower limit is zero
        // and the upper one is not.
        let none = try Mortality.smr([(observed: 0, personTime: 1_000, referenceRate: 0.004)])
        #expect(none.lower == 0)
        #expect(none.upper > 0)
    }

    @Test("a reference population that predicts no deaths is refused")
    func expectationOfZero() {
        #expect(throws: StatError.self) {
            _ = try Mortality.smr([(observed: 3, personTime: 1_000, referenceRate: 0)])
        }
        #expect(throws: StatError.self) { _ = try Mortality.smr([]) }
    }

    /// The point of a life table: rates become something a person can act on.
    @Test("a life table turns rates into survivors and years")
    func lifeTableBuilds() throws {
        let table = try Mortality.lifeTable([
            (age: 60, width: 10, rate: 0.01),
            (age: 70, width: 10, rate: 0.03),
            (age: 80, width: 10, rate: 0.08),
        ], radix: 100_000)

        #expect(table.rows.count == 3)
        #expect(table.rows[0].survivors == 100_000)
        // q = (10 × 0.01) / (1 + 0.5 × 10 × 0.01) = 0.0952
        #expect(isClose(table.rows[0].probabilityOfDying, 0.095238, 1e-5))
        // Survivors fall, never rise.
        #expect(table.rows[1].survivors < table.rows[0].survivors)
        #expect(table.rows[2].survivors < table.rows[1].survivors)
        // Life expectancy at 60 is longer than at 80, and both are positive.
        #expect(table.lifeExpectancyAtStart > table.rows[2].lifeExpectancy)
        #expect(table.rows[2].lifeExpectancy > 0)
    }

    @Test("a zero rate means nobody dies in that band")
    func zeroRateIsAllowed() throws {
        let table = try Mortality.lifeTable([
            (age: 0, width: 1, rate: 0),
            (age: 1, width: 10, rate: 0.001),
        ])
        #expect(table.rows[0].probabilityOfDying == 0)
        #expect(table.rows[1].survivors == table.radix)
    }

    @Test("bands out of order, or one band, is refused")
    func lifeTableRefusals() {
        #expect(throws: StatError.self) {
            _ = try Mortality.lifeTable([(age: 60, width: 10, rate: 0.01)])
        }
        #expect(throws: StatError.self) {
            _ = try Mortality.lifeTable([(age: 70, width: 10, rate: 0.03),
                                         (age: 60, width: 10, rate: 0.01)])
        }
        #expect(throws: StatError.self) {
            _ = try Mortality.lifeTable([(age: 60, width: 0, rate: 0.01),
                                         (age: 70, width: 10, rate: 0.03)])
        }
    }
}
