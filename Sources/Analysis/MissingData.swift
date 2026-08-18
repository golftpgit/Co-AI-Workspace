import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// What is not there (Bland, ch. 19).
//
// Every other file here takes `[Double]` — by which point the missing values
// are already gone, dropped by whoever built the array, and nothing downstream
// can tell a variable that was complete from one where a third of the sample
// walked out of the study. That is the exact shape of the problem chapter 19
// is about: the analysis looks the same either way and means something
// different.
//
// So this describes the holes and **does not fill them**. Imputation is a
// modelling decision with its own assumptions, and a library that quietly
// filled gaps would produce confident numbers out of absent data — the one
// thing §12.3's gate exists to prevent. What it can do is the part that is
// always safe and almost never done: say how much is missing, where, and
// whether the missingness looks related to something else in the data.
//
// The last of those is the useful one. "Missing completely at random" cannot
// be proved from the data — the reason somebody dropped out is usually not in
// the file — but the *opposite* often can be seen: if the people missing an
// outcome differ in the variables you do have, the gap is not random and
// analysing the complete cases answers a question about a different sample.
// ─────────────────────────────────────────────────────────────

public struct MissingnessReport: Sendable, Equatable {
    public struct Column: Sendable, Equatable, Identifiable {
        public let name: String
        public let present: Int
        public let missing: Int
        public var id: String { name }
        public var total: Int { present + missing }
        public var share: Double { total == 0 ? 0 : Double(missing) / Double(total) }
    }

    /// Rows with nothing missing — the sample a "complete case" analysis would
    /// actually run on.
    public let completeRows: Int
    public let totalRows: Int
    public let columns: [Column]

    public var completeShare: Double {
        totalRows == 0 ? 0 : Double(completeRows) / Double(totalRows)
    }

    /// The sentence a methods section needs, with the number that surprises
    /// people in it: dropping incomplete rows across several variables removes
    /// far more of the sample than any single column's gap suggests.
    public var summary: String {
        let worst = columns.max { $0.share < $1.share }
        var text = localised("\(completeRows) of \(totalRows) rows are complete on every variable ", "Summary of how much data is missing. Placeholders: complete rows and total rows.")
            + String(format: "(%.1f%%)", completeShare * 100)
        if let worst, worst.missing > 0 {
            text += localised(" · the variable missing most is \(worst.name) ", "Names the worst-affected variable. Placeholder: its name.")
                + String(format: "(%.1f%%)", worst.share * 100)
        }
        if completeShare < 1 {
            text += localised(" · **a complete-case analysis throws away ", "Warns how many people a complete-case analysis drops.")
                + localised("\(totalRows - completeRows) people** — more than any single variable is missing ", "Continues the complete-case warning. Placeholder: the number of people dropped.")
                + localised("because each row is missing something different", "Ends the complete-case warning.")
        }
        return text
    }
}

/// Whether the people missing one variable differ in another.
public struct MissingnessSignal: Sendable, Equatable {
    public let missingIn: String
    public let comparedWith: String
    public let meanWhenPresent: Double
    public let meanWhenMissing: Double
    public let pValue: Double
    public let missingCount: Int

    public var looksRelated: Bool { pValue < 0.05 }

    public var summary: String {
        let base = String(format: localised("those missing %@ (%d people) have a mean %@ of %.3f ", "Compares people with and without a missing value. Placeholders: the missing variable, how many people, the compared variable and its mean.")
                          + localised("against %.3f for those not missing it (p = %.4f)", "Ends the comparison. Placeholders: the other mean and the p-value."),
                          missingIn, missingCount, comparedWith,
                          meanWhenMissing, meanWhenPresent, pValue)
        return looksRelated
            ? base + localised(" — **the missingness is not random**: a complete-case analysis ", "Verdict when missingness is related to another variable.")
                   + localised("therefore answers a question about a different group of people than the one being studied", "Ends the verdict that missingness is not random.")
            : base + localised(" — no difference was found, **which does not mean the missingness is random**: ", "Verdict when no relationship to missingness is found.")
                   + localised("the reason people are missing is usually not in the file, so data can never prove MCAR — only the opposite", "Ends the verdict that no relationship to missingness was found.")
    }
}

public enum MissingData {

    /// Counts the holes. `nil` is missing; everything else is present.
    public static func describe(_ columns: [(name: String, values: [Double?])]) throws
        -> MissingnessReport {
        guard !columns.isEmpty else {
            throw StatError.notEnoughData(localised("there are no variables to check", "Why the missingness check cannot run."))
        }
        let rows = columns[0].values.count
        guard columns.allSatisfy({ $0.values.count == rows }) else {
            throw StatError.badShape(localised("every variable must have the same number of rows", "Why the missingness check cannot run."))
        }

        let described = columns.map { column in
            MissingnessReport.Column(
                name: column.name,
                present: column.values.count { $0 != nil },
                missing: column.values.count { $0 == nil })
        }
        let complete = (0..<rows).count { row in
            columns.allSatisfy { $0.values[row] != nil }
        }
        return MissingnessReport(completeRows: complete, totalRows: rows, columns: described)
    }

    /// Whether the rows missing `missingIn` differ in `comparedWith`.
    ///
    /// A Welch t-test, because the two groups have no reason to share a
    /// variance and usually differ in size by a lot.
    public static func signal(missingIn: (name: String, values: [Double?]),
                              comparedWith other: (name: String, values: [Double?])) throws
        -> MissingnessSignal {
        guard missingIn.values.count == other.values.count else {
            throw StatError.badShape(localised("both variables must have the same number of rows", "Why the missingness check cannot run."))
        }
        var whenPresent: [Double] = [], whenMissing: [Double] = []
        for index in missingIn.values.indices {
            guard let value = other.values[index] else { continue }
            if missingIn.values[index] == nil { whenMissing.append(value) }
            else { whenPresent.append(value) }
        }
        guard whenMissing.count >= 2, whenPresent.count >= 2 else {
            throw StatError.notEnoughData(
                localised("at least two rows are needed both where the value is missing and where it is present ", "Why the missingness comparison cannot run.")
                    + localised("for a comparison — there are \(whenMissing.count) and \(whenPresent.count)", "Ends the reason the missingness comparison cannot run. Placeholders: the two group sizes."))
        }
        let result = try StatGate.twoSample(whenPresent, whenMissing, assumingEqualVariance: false)
        return MissingnessSignal(missingIn: missingIn.name, comparedWith: other.name,
                                 meanWhenPresent: Statistics.mean(whenPresent),
                                 meanWhenMissing: Statistics.mean(whenMissing),
                                 pValue: result.pValue, missingCount: whenMissing.count)
    }
}
