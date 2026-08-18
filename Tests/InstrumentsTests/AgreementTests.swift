import Testing
import Foundation
@testable import Instruments

// ─────────────────────────────────────────────────────────────
// κ and ICC (ARCHITECTURE §20.4, P11.3, risk R12).
//
// R12 is "statistics we wrote ourselves that are quietly wrong", and the answer
// the plan gives is: every figure checked against a worked example somebody else
// published. So these tests are not "does it return a number" — every expected
// value here comes from outside this codebase:
//
//   • all six ICC forms against Shrout & Fleiss (1979), table 2;
//   • Cohen's κ against the standard 2×2 that can be done on paper;
//   • Fleiss' κ against a matrix small enough to check by hand.
//
// Plus the cases where the arithmetic is defined and the *meaning* is not, which
// is where a self-written statistic actually goes wrong.
// ─────────────────────────────────────────────────────────────

@Suite("Agreement between raters")
struct AgreementTests {

    /// Shrout & Fleiss (1979), table 2. The canonical worked example: six
    /// targets, four judges.
    private let shroutFleiss: [[Double]] = [
        [9, 2, 5, 8],
        [6, 1, 3, 2],
        [8, 4, 6, 8],
        [7, 1, 2, 6],
        [10, 5, 6, 9],
        [6, 2, 4, 7],
    ]

    @Test("all six ICC forms match the published worked example")
    func iccMatchesShroutAndFleiss() throws {
        let icc = try #require(Reliability.icc(shroutFleiss))

        // The published figures, to two decimals as they are printed in the
        // paper. If any of these drift, the change was not a refactor.
        #expect(abs(icc.oneWayRandomSingle - 0.17) < 0.005)
        #expect(abs(icc.twoWayRandomSingle - 0.29) < 0.005)
        #expect(abs(icc.twoWayMixedSingle - 0.71) < 0.005)
        #expect(abs(icc.oneWayRandomAverage - 0.44) < 0.005)
        #expect(abs(icc.twoWayRandomAverage - 0.62) < 0.005)
        #expect(abs(icc.twoWayMixedAverage - 0.91) < 0.005)
        #expect(icc.targets == 6)
        #expect(icc.raters == 4)
    }

    @Test("consistency and absolute agreement are different questions")
    func raterBiasSeparatesTheForms() throws {
        // Two raters who rank identically and are two points apart. The one who
        // only cares about ranking should be delighted; the one who cares
        // whether the scores mean the same thing should not — and a study that
        // reports "the ICC" without saying which has said nothing.
        let biased: [[Double]] = [[1, 3], [2, 4], [3, 5], [4, 6], [5, 7]]
        let icc = try #require(Reliability.icc(biased))
        #expect(icc.twoWayMixedSingle > 0.95)
        #expect(icc.twoWayRandomSingle < icc.twoWayMixedSingle)
    }

    @Test("a design too small to support a figure returns nothing rather than one")
    func thinDesignsRefuse() {
        // One rater is not a reliability study; neither is one target. A number
        // produced here would be quoted in a thesis.
        #expect(Reliability.icc([[1], [2], [3]]) == nil)
        #expect(Reliability.icc([[1, 2]]) == nil)
        #expect(Reliability.icc([]) == nil)
        // Ragged rows are a data-entry mistake, not a design.
        #expect(Reliability.icc([[1, 2], [3]]) == nil)
        // Every target scored identically: no between-target variance, so the
        // ratio is undefined rather than perfect.
        #expect(Reliability.icc([[4, 4], [4, 4], [4, 4]]) == nil)
    }

    @Test("Cohen's κ matches the textbook 2×2")
    func cohenMatchesTheWorkedExample() throws {
        // a = 20 both yes, b = 5 first only, c = 10 second only, d = 15 both no.
        // Po = 0.70, Pe = 0.50, κ = 0.40 — all three checkable on paper.
        var first: [String] = [], second: [String] = []
        func add(_ times: Int, _ one: String, _ two: String) {
            for _ in 0..<times { first.append(one); second.append(two) }
        }
        add(20, "yes", "yes")
        add(5, "yes", "no")
        add(10, "no", "yes")
        add(15, "no", "no")

        let agreement = try Agreement.cohensKappa(first, second)
        #expect(abs(agreement.kappa - 0.40) < 0.0001)
        #expect(abs(agreement.observedAgreement - 0.70) < 0.0001)
        #expect(abs(agreement.expectedAgreement - 0.50) < 0.0001)
        // κ = 0.40 sits exactly on Landis & Koch's fair/moderate boundary
        // (0.21–0.40 fair, 0.41–0.60 moderate), so the label is checked with a
        // value that is not on a boundary rather than with this one.
        #expect(try Agreement.cohensKappa(["a", "a", "a", "b", "b", "b", "a", "b"],
                                          ["a", "a", "a", "b", "b", "a", "b", "b"])
            .interpretation.contains("moderate"))
    }

    @Test("κ near zero on high agreement is reported honestly, not hidden")
    func skewedCategoriesAreVisible() throws {
        // The failure κ is famous for: two coders label 98 of 100 passages the
        // same way because almost everything is one category. Agreement is 96%
        // and κ is near nothing.
        var first = Array(repeating: "ภาระงาน", count: 98)
        var second = Array(repeating: "ภาระงาน", count: 98)
        first.append(contentsOf: ["ทีม", "ภาระงาน"])
        second.append(contentsOf: ["ภาระงาน", "ทีม"])

        let agreement = try Agreement.cohensKappa(first, second)
        #expect(agreement.observedAgreement > 0.95)
        #expect(agreement.kappa < 0.1)
        // Both numbers are in the summary, which is the whole point: a reader
        // who sees only κ concludes the coders were incompetent, and a reader
        // who sees only agreement concludes they were excellent.
        #expect(agreement.summary.contains("observed agreement"))
        #expect(agreement.summary.contains("κ"))
    }

    @Test("coders who agreed on everything score 1, whichever way they did it")
    func perfectAgreementIsOne() throws {
        #expect(try Agreement.cohensKappa(["a", "b", "a"], ["a", "b", "a"]).kappa == 1)
        // Everybody used one category for everything: expected agreement is 1
        // and κ is 0/0. Reporting 0 would say "no better than chance" about
        // coders who never disagreed.
        #expect(try Agreement.cohensKappa(["a", "a"], ["a", "a"]).kappa == 1)
    }

    @Test("two coders who never agree score below zero")
    func systematicDisagreementIsNegative() throws {
        let agreement = try Agreement.cohensKappa(["a", "b", "a", "b"],
                                                  ["b", "a", "b", "a"])
        #expect(agreement.kappa < 0)
        #expect(agreement.interpretation.contains("worse than guessing"))
    }

    @Test("coders who looked at different numbers of units cannot be compared")
    func mismatchedCodingsAreRefused() {
        #expect(throws: AgreementError.self) {
            _ = try Agreement.cohensKappa(["a", "b"], ["a"])
        }
        #expect(throws: AgreementError.self) {
            _ = try Agreement.cohensKappa([], [])
        }
    }

    @Test("Fleiss' κ handles the third coder a supervisor adds")
    func fleissMatchesAHandComputedMatrix() throws {
        // Six passages, three coders, two codes. Computed by hand:
        // p = [0.5, 0.5], P̄ = 0.7778, Pe = 0.5, κ = 0.5556.
        let codings = [
            ["ทีม", "ทีม", "ทีม"],
            ["ภาระงาน", "ภาระงาน", "ภาระงาน"],
            ["ภาระงาน", "ภาระงาน", "ทีม"],
            ["ภาระงาน", "ทีม", "ทีม"],
            ["ภาระงาน", "ภาระงาน", "ภาระงาน"],
            ["ทีม", "ทีม", "ทีม"],
        ]
        let agreement = try Agreement.fleissKappa(codings)
        #expect(abs(agreement.kappa - 0.5556) < 0.0005)
        #expect(abs(agreement.observedAgreement - 0.7778) < 0.0005)
        #expect(agreement.raters == 3)
        #expect(agreement.subjects == 6)
    }

    @Test("a unit one coder skipped is a hole in the design, not a category")
    func unequalRaterCountsAreRefused() {
        #expect(throws: AgreementError.unequalRaterCounts) {
            _ = try Agreement.fleissKappa([["a", "b", "a"], ["a", "b"]])
        }
    }
}
