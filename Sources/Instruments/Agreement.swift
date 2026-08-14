import Foundation

// ─────────────────────────────────────────────────────────────
// Do two people who looked at the same thing agree? (ARCHITECTURE §20.4, P11.3)
//
// Two different questions with two different answers, and picking the wrong one
// is a common way for a methods section to say something untrue:
//
//  • **κ** is for categories. Two coders read the same interview and label a
//    passage "ภาระงาน" or "ความสัมพันธ์ในทีม"; κ asks how much of their agreement
//    is more than chance would give. This is what P11.8's intercoder reliability
//    needs.
//  • **ICC** is for numbers. Several raters score the same targets on a scale,
//    and ICC asks how much of the variation is between the targets rather than
//    between the raters.
//
// Percent agreement is reported alongside κ on purpose. κ alone is famously
// unstable when one category dominates — two coders can agree on 95% of passages
// and score κ ≈ 0 — and a reader who sees both numbers can tell that is what
// happened. A number that misleads on its own is not made honest by being
// correct.
//
// Checked against the published worked examples: Shrout & Fleiss (1979) for all
// six ICC forms, and the standard 2×2 for Cohen's κ.
// ─────────────────────────────────────────────────────────────

public struct CategoryAgreement: Sendable, Equatable {
    /// Cohen's κ, or Fleiss' κ when there were more than two raters.
    public let kappa: Double
    /// The proportion the raters simply agreed on, before chance is taken out.
    /// Reported beside κ because the two disagreeing is the signal that one
    /// category is swamping the others.
    public let observedAgreement: Double
    public let expectedAgreement: Double
    public let subjects: Int
    public let raters: Int

    /// Landis & Koch's labels, which is what a Thai thesis committee will expect
    /// to see quoted. They are conventions, not thresholds anything enforces —
    /// which is why this returns words rather than a pass/fail.
    public var interpretation: String {
        switch kappa {
        case ..<0.0: "แย่กว่าการเดา"
        case ..<0.20: "ต่ำมาก (slight)"
        case ..<0.40: "พอมี (fair)"
        case ..<0.60: "ปานกลาง (moderate)"
        case ..<0.80: "ดี (substantial)"
        default: "ดีมาก (almost perfect)"
        }
    }

    public var summary: String {
        String(format: "κ %.2f · ตรงกันจริง %.0f%% · %d หน่วย · %d ผู้ลงรหัส · %@",
               kappa, observedAgreement * 100, subjects, raters, interpretation)
    }
}

public enum AgreementError: Error, CustomStringConvertible, Equatable {
    case mismatchedLengths(Int, Int)
    case notEnoughData
    case unequalRaterCounts

    public var description: String {
        switch self {
        case .mismatchedLengths(let first, let second):
            "ผู้ลงรหัสสองคนลงไม่เท่ากัน (\(first) กับ \(second) หน่วย) — "
                + "κ เทียบได้เฉพาะหน่วยที่ทั้งคู่ดูเหมือนกัน"
        case .notEnoughData:
            "ข้อมูลน้อยเกินกว่าจะคำนวณความสอดคล้อง"
        case .unequalRaterCounts:
            "จำนวนผู้ลงรหัสต่อหน่วยไม่เท่ากัน — Fleiss' κ ตั้งอยู่บนสมมติฐานว่าทุกหน่วยถูกลงรหัสเท่ากัน"
        }
    }
}

public enum Agreement {

    /// Cohen's κ for two coders labelling the same units.
    ///
    /// `nil` is not accepted for a label: a unit one coder left unlabelled is a
    /// unit they did not code, and quietly treating that as a category of its own
    /// inflates agreement.
    public static func cohensKappa(_ first: [String], _ second: [String]) throws
        -> CategoryAgreement {
        guard first.count == second.count else {
            throw AgreementError.mismatchedLengths(first.count, second.count)
        }
        guard !first.isEmpty else { throw AgreementError.notEnoughData }

        let total = Double(first.count)
        let agreed = zip(first, second).count { $0 == $1 }
        let observed = Double(agreed) / total

        let categories = Set(first).union(second)
        var expected = 0.0
        for category in categories {
            let firstShare = Double(first.count { $0 == category }) / total
            let secondShare = Double(second.count { $0 == category }) / total
            expected += firstShare * secondShare
        }

        return CategoryAgreement(kappa: Self.kappa(observed: observed, expected: expected),
                                 observedAgreement: observed,
                                 expectedAgreement: expected,
                                 subjects: first.count, raters: 2)
    }

    /// Fleiss' κ, for three or more coders — the shape a real qualitative study
    /// has once a supervisor joins the two students.
    ///
    /// `codings` is one row per unit, holding each coder's label for it.
    public static func fleissKappa(_ codings: [[String]]) throws -> CategoryAgreement {
        guard let raters = codings.first?.count, raters >= 2 else {
            throw AgreementError.notEnoughData
        }
        guard codings.allSatisfy({ $0.count == raters }) else {
            throw AgreementError.unequalRaterCounts
        }
        let subjects = codings.count
        guard subjects >= 1 else { throw AgreementError.notEnoughData }

        let categories = Array(Set(codings.flatMap { $0 })).sorted()
        let n = Double(raters)

        // How often each category was chosen at all — the chance baseline.
        var proportions: [Double] = []
        for category in categories {
            let chosen = codings.reduce(0) { running, row in
                running + row.count { $0 == category }
            }
            proportions.append(Double(chosen) / (Double(subjects) * n))
        }

        // How much the raters agreed within each unit.
        var perSubject: [Double] = []
        for row in codings {
            let counts = categories.map { category in Double(row.count { $0 == category }) }
            let sumOfSquares = counts.reduce(0) { $0 + $1 * $1 }
            perSubject.append((sumOfSquares - n) / (n * (n - 1)))
        }

        let observed = perSubject.reduce(0, +) / Double(subjects)
        let expected = proportions.reduce(0) { $0 + $1 * $1 }
        return CategoryAgreement(kappa: Self.kappa(observed: observed, expected: expected),
                                 observedAgreement: observed,
                                 expectedAgreement: expected,
                                 subjects: subjects, raters: raters)
    }

    /// Perfect expected agreement means everybody used one category for
    /// everything. κ is undefined there — 0/0 — and reporting 0 would say "no
    /// better than chance" about coders who never disagreed. It is 1 when they
    /// agreed on everything and 0 when they did not.
    private static func kappa(observed: Double, expected: Double) -> Double {
        guard expected < 1 else { return observed >= 1 ? 1 : 0 }
        return (observed - expected) / (1 - expected)
    }
}

// ─────────────────────────────────────────────────────────────
// ICC
// ─────────────────────────────────────────────────────────────

/// The six forms of Shrout & Fleiss (1979). All six, because choosing between
/// them is a design decision a researcher has to make and defend, and a library
/// that returns "the ICC" has made it for them silently.
public struct IntraclassCorrelation: Sendable, Equatable {
    /// One-way random: each target rated by a *different* set of raters.
    public let oneWayRandomSingle: Double
    public let oneWayRandomAverage: Double
    /// Two-way random, absolute agreement: the same raters, drawn from a
    /// population — the usual choice for inter-rater reliability, and the one
    /// that punishes raters who are consistent but systematically higher.
    public let twoWayRandomSingle: Double
    public let twoWayRandomAverage: Double
    /// Two-way mixed, consistency: these raters and no others, and only the
    /// ranking matters.
    public let twoWayMixedSingle: Double
    public let twoWayMixedAverage: Double

    public let targets: Int
    public let raters: Int

    /// Koo & Li's convention, quoted as words for the same reason as κ's.
    public static func interpretation(_ value: Double) -> String {
        switch value {
        case ..<0.50: "ต่ำ (poor)"
        case ..<0.75: "พอใช้ (moderate)"
        case ..<0.90: "ดี (good)"
        default: "ดีมาก (excellent)"
        }
    }

    public var summary: String {
        String(format: "ICC(2,1) %.2f · ICC(2,k) %.2f · %d หน่วย × %d ผู้ประเมิน · %@",
               twoWayRandomSingle, twoWayRandomAverage, targets, raters,
               Self.interpretation(twoWayRandomSingle))
    }
}

extension Reliability {

    /// ICC from a targets × raters matrix — every rater scores every target.
    ///
    /// `nil` rather than a number when the design cannot support one: two
    /// targets or one rater is not a reliability study, and an ICC computed from
    /// it is a figure that will be quoted.
    public static func icc(_ scores: [[Double]]) -> IntraclassCorrelation? {
        guard let raters = scores.first?.count, raters >= 2,
              scores.count >= 2,
              scores.allSatisfy({ $0.count == raters }) else { return nil }

        let n = Double(scores.count)
        let k = Double(raters)
        let all = scores.flatMap { $0 }
        let grand = all.reduce(0, +) / Double(all.count)

        let rowMeans = scores.map { $0.reduce(0, +) / k }
        let columnMeans = (0..<raters).map { column in
            scores.reduce(0) { $0 + $1[column] } / n
        }

        // The three sums of squares the six forms are built from.
        let betweenTargets = k * rowMeans.reduce(0) { $0 + ($1 - grand) * ($1 - grand) }
        let betweenRaters = n * columnMeans.reduce(0) { $0 + ($1 - grand) * ($1 - grand) }
        let total = all.reduce(0) { $0 + ($1 - grand) * ($1 - grand) }
        let residual = total - betweenTargets - betweenRaters
        let withinTargets = total - betweenTargets

        let msTargets = betweenTargets / (n - 1)
        let msRaters = betweenRaters / (k - 1)
        let msResidual = residual / ((n - 1) * (k - 1))
        let msWithin = withinTargets / (n * (k - 1))

        guard msTargets > 0 else { return nil }

        return IntraclassCorrelation(
            oneWayRandomSingle: (msTargets - msWithin) / (msTargets + (k - 1) * msWithin),
            oneWayRandomAverage: (msTargets - msWithin) / msTargets,
            twoWayRandomSingle: (msTargets - msResidual)
                / (msTargets + (k - 1) * msResidual + k * (msRaters - msResidual) / n),
            twoWayRandomAverage: (msTargets - msResidual)
                / (msTargets + (msRaters - msResidual) / n),
            twoWayMixedSingle: (msTargets - msResidual) / (msTargets + (k - 1) * msResidual),
            twoWayMixedAverage: (msTargets - msResidual) / msTargets,
            targets: scores.count, raters: raters)
    }
}
