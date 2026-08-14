import Testing
import Foundation
import StatKit
@testable import Instruments

// P11.3's construct-validity half, checked the way risk R12 asks for: against
// numbers this project did not produce.
//
//  • The closed-form cases use an equicorrelation matrix `(1−ρ)I + ρJ`, whose
//    eigenvalues, determinant, KMO and one-factor loadings are all algebra —
//    no arithmetic of ours appears in the expected values.
//  • The end-to-end case is a fixed 40 × 6 dataset run through an independent
//    implementation written in Python first (Jacobi eigen, same algorithms,
//    different language). Those numbers are pasted below and the Swift has to
//    reproduce them; if only one of the two is wrong, this test says so.

private func equicorrelation(_ p: Int, _ rho: Double) -> [[Double]] {
    (0..<p).map { row in (0..<p).map { column in row == column ? 1 : rho } }
}

private func itemNames(_ count: Int) -> [String] {
    (0..<count).map { "item\($0)" }
}

/// The dataset the Python reference was run on — Likert answers, two planted
/// factors (items 0–2 and items 3–5).
private let reference: [[Double]] = [
    [3, 3, 4, 1, 2, 2], [2, 2, 2, 3, 3, 3], [3, 3, 3, 4, 2, 4], [4, 5, 5, 3, 3, 2],
    [4, 3, 5, 3, 3, 4], [2, 3, 4, 2, 4, 4], [3, 5, 4, 5, 4, 4], [3, 3, 4, 2, 3, 2],
    [2, 1, 2, 2, 1, 2], [3, 3, 3, 3, 2, 2], [4, 3, 4, 3, 4, 3], [4, 3, 4, 1, 1, 2],
    [3, 3, 5, 4, 3, 3], [3, 3, 4, 3, 2, 3], [2, 3, 3, 2, 3, 2], [3, 4, 3, 4, 5, 4],
    [3, 2, 2, 1, 1, 2], [4, 5, 4, 4, 4, 4], [2, 1, 1, 2, 1, 2], [2, 2, 2, 3, 4, 3],
    [5, 3, 4, 2, 2, 3], [4, 4, 4, 2, 3, 3], [4, 3, 4, 3, 5, 4], [3, 3, 3, 1, 2, 2],
    [2, 1, 2, 3, 2, 4], [4, 4, 5, 4, 4, 5], [1, 1, 2, 2, 2, 3], [2, 3, 1, 4, 3, 5],
    [2, 2, 2, 3, 4, 4], [3, 3, 2, 3, 4, 3], [3, 3, 3, 2, 2, 2], [2, 2, 3, 3, 2, 3],
    [2, 1, 2, 4, 3, 4], [4, 4, 5, 3, 2, 3], [2, 3, 3, 3, 3, 3], [4, 3, 3, 4, 4, 4],
    [3, 3, 3, 4, 4, 3], [3, 2, 3, 4, 3, 3], [5, 5, 5, 3, 4, 3], [3, 3, 3, 3, 4, 4],
]

@Suite("EFA against closed forms")
struct FactorClosedFormTests {

    @Test("KMO on an equicorrelation matrix is its algebraic value")
    func kmoClosedForm() throws {
        let p = 5
        let rho = 0.4
        let matrix = equicorrelation(p, rho)
        let eigen = try SymmetricEigen.of(matrix)
        let adequacy = ExploratoryFactorAnalysis.samplingAdequacy(
            correlation: matrix, inverse: try eigen.inverse(), eigen: eigen,
            itemIDs: itemNames(p), respondents: 200)

        // Every partial correlation is ρ / (1 + (p−2)ρ), so KMO reduces to
        // k² / (k² + 1) with k = 1 + (p−2)ρ.
        let k = 1 + Double(p - 2) * rho
        #expect(abs(adequacy.kmo - k * k / (k * k + 1)) < 1e-12)
        // Every item is interchangeable, so every MSA equals the overall figure.
        for value in adequacy.perItem.values {
            #expect(abs(value - adequacy.kmo) < 1e-12)
        }
        #expect(adequacy.kmoLabel.contains("meritorious"))
    }

    @Test("Bartlett's χ² is the published formula applied to the exact determinant")
    func bartlettClosedForm() throws {
        let p = 5
        let rho = 0.4
        let n = 200.0
        let matrix = equicorrelation(p, rho)
        let eigen = try SymmetricEigen.of(matrix)
        let adequacy = ExploratoryFactorAnalysis.samplingAdequacy(
            correlation: matrix, inverse: try eigen.inverse(), eigen: eigen,
            itemIDs: itemNames(p), respondents: Int(n))

        let determinant = pow(1 - rho, Double(p - 1)) * (1 + Double(p - 1) * rho)
        let expected = -(n - 1 - (2 * Double(p) + 5) / 6) * log(determinant)
        #expect(abs(adequacy.bartlettChiSquare - expected) < 1e-9)
        #expect(adequacy.bartlettDegreesOfFreedom == 10)
        #expect(adequacy.bartlettPValue < 0.001)
        #expect(adequacy.isFactorable)
    }

    @Test("an identity correlation matrix is not factorable, and says which check failed")
    func nothingToFactor() throws {
        let p = 4
        let matrix = equicorrelation(p, 0)
        let eigen = try SymmetricEigen.of(matrix)
        let adequacy = ExploratoryFactorAnalysis.samplingAdequacy(
            correlation: matrix, inverse: try eigen.inverse(), eigen: eigen,
            itemIDs: itemNames(p), respondents: 150)
        #expect(adequacy.kmo == 0)
        #expect(adequacy.bartlettChiSquare == 0)
        #expect(!adequacy.isFactorable)
        #expect(adequacy.summary.contains("รับไม่ได้"))
    }

    @Test("principal axis recovers the loading a one-factor structure was built from")
    func principalAxisClosedForm() {
        // r = λ² for every pair, so λ = √0.36 = 0.6 exactly.
        let rho = 0.36
        let extraction = ExploratoryFactorAnalysis.principalAxis(
            correlation: equicorrelation(6, rho), communalities: [Double](repeating: 0.3, count: 6),
            factors: 1)
        #expect(extraction.converged)
        for row in extraction.loadings {
            #expect(abs(abs(row[0]) - rho.squareRoot()) < 1e-6)
        }
    }

    @Test("varimax rotates a mixed-up simple structure back to simple")
    func varimaxRecovery() {
        let planted: [[Double]] = [[0.8, 0], [0.8, 0], [0.7, 0],
                                   [0, 0.8], [0, 0.8], [0, 0.7]]
        let angle = 30.0 * .pi / 180
        let mixed = planted.map { row in
            [row[0] * cos(angle) - row[1] * sin(angle),
             row[0] * sin(angle) + row[1] * cos(angle)]
        }
        let recovered = ExploratoryFactorAnalysis.orderByVariance(
            ExploratoryFactorAnalysis.varimax(mixed), factors: 2)
        for (index, row) in recovered.enumerated() {
            #expect(abs(row[0] - planted[index][0]) < 1e-6)
            #expect(abs(row[1] - planted[index][1]) < 1e-6)
        }
    }
}

@Suite("EFA against an independent implementation")
struct FactorReferenceTests {

    @Test("every reported number matches the Python reference on the same data")
    func matchesReference() throws {
        let solution = try ExploratoryFactorAnalysis.analyse(
            scores: reference, itemIDs: itemNames(6), rule: .fixed(2))

        // Eigenvalues of the unreduced correlation matrix.
        let expectedEigen = [2.857873, 1.893020, 0.432094, 0.343380, 0.262818, 0.210815]
        for (found, expected) in zip(solution.eigenvalues, expectedEigen) {
            #expect(abs(found - expected) < 1e-5)
        }

        #expect(abs(solution.adequacy.kmo - 0.718420) < 1e-5)
        let expectedMSA = [0.745827, 0.718170, 0.741031, 0.700418, 0.760729, 0.641008]
        for (index, expected) in expectedMSA.enumerated() {
            #expect(abs((solution.adequacy.perItem["item\(index)"] ?? 0) - expected) < 1e-5)
        }
        #expect(abs(solution.adequacy.bartlettChiSquare - 112.581355) < 1e-4)
        #expect(solution.adequacy.bartlettDegreesOfFreedom == 15)

        let expectedLoadings = [[0.826993, 0.020806], [0.830674, 0.262984],
                                [0.864408, 0.027952], [0.057128, 0.818001],
                                [0.256715, 0.714637], [-0.023365, 0.833262]]
        for (index, row) in solution.loadings.enumerated() {
            #expect(abs(row.loadings[0] - expectedLoadings[index][0]) < 1e-5)
            #expect(abs(row.loadings[1] - expectedLoadings[index][1]) < 1e-5)
        }
        let expectedCommunalities = [0.684351, 0.759181, 0.747983,
                                     0.672388, 0.576608, 0.694872]
        for (index, row) in solution.loadings.enumerated() {
            #expect(abs(row.communality - expectedCommunalities[index]) < 1e-5)
        }
        #expect(abs(solution.varianceExplained[0] - 0.365142) < 1e-5)
        #expect(abs(solution.varianceExplained[1] - 0.324089) < 1e-5)
        #expect(solution.converged)
    }

    @Test("ω matches the reference, on the subscale the reference ran it on")
    func omegaMatchesReference() throws {
        let subscale = reference.map { Array($0[0..<3]) }
        let omega = try #require(Reliability.omega(scores: subscale, itemIDs: itemNames(3)))
        #expect(abs(omega.omega - 0.880931) < 1e-5)
        let expected = [0.837074, 0.819178, 0.873606]
        for (index, value) in expected.enumerated() {
            #expect(abs((omega.loadings["item\(index)"] ?? 0) - value) < 1e-5)
        }
        #expect(omega.passes)
    }

    @Test("the planted two-factor structure is what comes out")
    func plantedStructure() throws {
        let solution = try ExploratoryFactorAnalysis.analyse(
            scores: reference, itemIDs: itemNames(6))
        #expect(solution.retained == 2)
        #expect(solution.kaiserSuggests == 2)
        #expect(solution.parallelSuggests == 2)
        #expect(solution.items(onFactor: 0) == ["item2", "item1", "item0"])
        #expect(Set(solution.items(onFactor: 1)) == ["item3", "item4", "item5"])
        #expect(solution.unplacedItems.isEmpty)
        #expect(solution.crossLoadingItems.isEmpty)
        #expect(solution.heywoodItems.isEmpty)
    }

    @Test("the retention rules are both reported, whichever one was used")
    func bothRulesReported() throws {
        let kaiser = try ExploratoryFactorAnalysis.analyse(
            scores: reference, itemIDs: itemNames(6), rule: .kaiser)
        let parallel = try ExploratoryFactorAnalysis.analyse(
            scores: reference, itemIDs: itemNames(6), rule: .parallelAnalysis)
        #expect(kaiser.kaiserSuggests == parallel.kaiserSuggests)
        #expect(kaiser.parallelSuggests == parallel.parallelSuggests)
        #expect(kaiser.rule == .kaiser)
        #expect(parallel.rule == .parallelAnalysis)
    }

    @Test("parallel analysis gives the same answer every time it is run")
    func parallelIsDeterministic() {
        let observed = [2.857873, 1.893020, 0.432094, 0.343380, 0.262818, 0.210815]
        let first = ExploratoryFactorAnalysis.parallelAnalysisCount(
            observed: observed, respondents: 40, items: 6)
        let second = ExploratoryFactorAnalysis.parallelAnalysisCount(
            observed: observed, respondents: 40, items: 6)
        #expect(first == second)
        #expect(first == 2)
    }

    @Test("the sample-size warnings are on the result, not left to the reader")
    func warnings() throws {
        // 40 respondents is under 100, and 40 to 6 items is 6.7:1, which is not
        // under 5:1 — the two rules are separate and only the one that applies
        // is said.
        let solution = try ExploratoryFactorAnalysis.analyse(
            scores: reference, itemIDs: itemNames(6))
        #expect(solution.warnings.contains { $0.contains("ต่ำกว่า 100") })
        #expect(!solution.warnings.contains { $0.contains("5:1") })

        let thin = try ExploratoryFactorAnalysis.analyse(
            scores: Array(reference[0..<25]), itemIDs: itemNames(6), rule: .fixed(2))
        #expect(thin.warnings.contains { $0.contains("5:1") })
    }
}

/// The answers a real driven round of the app collected — five items, forty
/// people, posted through the served form. Kept because of what it revealed:
/// principal axis factoring took 183 passes to settle on it, so the old
/// 100-iteration cap put a "did not converge" warning on a screen whose numbers
/// were already right to three decimals. An ordinary small study is exactly the
/// case a cap has to survive.
private let driven: [[Double]] = [
    [3, 3, 1, 3, 2], [2, 3, 2, 3, 2], [4, 4, 4, 5, 4], [3, 3, 1, 4, 2],
    [4, 4, 3, 3, 4], [3, 3, 5, 3, 5], [3, 3, 3, 1, 4], [5, 5, 1, 3, 2],
    [3, 4, 2, 3, 3], [1, 2, 2, 2, 3], [2, 2, 3, 2, 3], [3, 3, 2, 4, 2],
    [4, 4, 1, 4, 2], [2, 2, 4, 1, 4], [4, 2, 3, 3, 3], [3, 3, 2, 4, 2],
    [2, 3, 2, 3, 3], [3, 3, 3, 3, 3], [3, 5, 3, 3, 3], [2, 3, 2, 3, 3],
    [3, 2, 1, 3, 3], [2, 2, 2, 1, 2], [2, 3, 3, 2, 3], [2, 2, 3, 3, 4],
    [4, 4, 2, 4, 2], [4, 3, 4, 4, 3], [4, 5, 4, 2, 4], [4, 3, 4, 2, 3],
    [2, 4, 4, 4, 2], [2, 3, 3, 2, 3], [3, 2, 3, 2, 1], [5, 4, 3, 3, 5],
    [2, 2, 3, 2, 4], [5, 5, 2, 4, 2], [3, 3, 2, 3, 2], [2, 3, 2, 2, 2],
    [3, 3, 3, 4, 3], [2, 2, 4, 1, 2], [3, 2, 3, 3, 2], [3, 3, 1, 4, 1],
]

@Suite("extraction convergence")
struct ConvergenceTests {

    @Test("an ordinary small study converges rather than warning about itself")
    func drivenDataConverges() throws {
        let solution = try ExploratoryFactorAnalysis.analyse(
            scores: driven, itemIDs: itemNames(5))
        #expect(solution.converged)
        #expect(solution.iterations > 100, "the cap this replaced was 100")
        #expect(solution.convergenceGap < 1e-7)
        #expect(!solution.warnings.contains { $0.contains("ไม่ลู่เข้า") })
    }

    @Test("stopping early is reported with the size it stopped at, not just the fact")
    func gapIsReported() {
        let correlation = try! ExploratoryFactorAnalysis.correlationMatrix(
            driven, itemIDs: itemNames(5))
        let start = [Double](repeating: 0.5, count: 5)
        let stopped = ExploratoryFactorAnalysis.principalAxis(
            correlation: correlation, communalities: start, factors: 2,
            maximumIterations: 5)
        #expect(!stopped.converged)
        #expect(stopped.iterations == 5)
        // A number a reader can judge: still moving, but by how much.
        #expect(stopped.residual > 0)
        #expect(stopped.residual < 0.1)
    }
}

@Suite("EFA refusals")
struct FactorRefusalTests {

    @Test("two items is a correlation, not a structure")
    func tooFewItems() {
        #expect(throws: FactorAnalysisError.tooFewItems(2)) {
            try ExploratoryFactorAnalysis.analyse(
                scores: [[1, 2], [2, 3], [3, 4], [4, 5]], itemIDs: ["a", "b"])
        }
    }

    @Test("fewer respondents than items is refused before it produces a table")
    func tooFewRespondents() {
        let scores = (0..<4).map { row in (0..<6).map { Double(($0 + row) % 5 + 1) } }
        #expect(throws: FactorAnalysisError.tooFewRespondents(respondents: 4, items: 6)) {
            try ExploratoryFactorAnalysis.analyse(scores: scores, itemIDs: itemNames(6))
        }
    }

    @Test("an item everybody answered the same way is named, not averaged over")
    func constantItem() {
        var scores = reference
        for index in scores.indices { scores[index][4] = 3 }
        #expect(throws: FactorAnalysisError.constantItems(["item4"])) {
            try ExploratoryFactorAnalysis.analyse(scores: scores, itemIDs: itemNames(6))
        }
    }

    @Test("a duplicated item makes the matrix singular, and that is said out loud")
    func singular() {
        // item5 is a copy of item0 — the shape a scale gets when a question is
        // pasted twice, or a total is entered as another item.
        let scores = reference.map { row -> [Double] in
            var copy = row
            copy[5] = row[0]
            return copy
        }
        #expect(throws: FactorAnalysisError.self) {
            try ExploratoryFactorAnalysis.analyse(scores: scores, itemIDs: itemNames(6))
        }
    }

    @Test("ω refuses the cases where it would mean nothing")
    func omegaRefuses() {
        #expect(Reliability.omega(scores: reference.map { Array($0[0..<2]) },
                                  itemIDs: itemNames(2)) == nil)
        #expect(Reliability.omega(scores: Array(reference[0..<2]),
                                  itemIDs: itemNames(6)) == nil)
    }
}

@Suite("declared structure against found structure")
struct ConstructFitTests {

    private func solution() throws -> FactorSolution {
        try ExploratoryFactorAnalysis.analyse(scores: reference, itemIDs: itemNames(6))
    }

    @Test("constructs whose items all land together are reported clean")
    func clean() throws {
        let fit = ConstructFit.compare(try solution(), constructOfItem: [
            "item0": "ภาระงาน", "item1": "ภาระงาน", "item2": "ภาระงาน",
            "item3": "ทีม", "item4": "ทีม", "item5": "ทีม",
        ])
        #expect(fit.constructs.count == 2)
        #expect(fit.constructs.count { $0.isClean } == 2)
        #expect(fit.misplaced.isEmpty)
        #expect(fit.mergedConstructs.isEmpty)
    }

    @Test("an item written for the wrong construct is named")
    func misplaced() throws {
        // item5 is declared with the first three and lands with the others.
        let fit = ConstructFit.compare(try solution(), constructOfItem: [
            "item0": "ภาระงาน", "item1": "ภาระงาน", "item2": "ภาระงาน", "item5": "ภาระงาน",
            "item3": "ทีม", "item4": "ทีม",
        ])
        #expect(fit.misplaced == ["item5"])
        #expect(fit.constructs.first { $0.constructID == "ภาระงาน" }?.isClean == false)
        #expect(fit.summary.contains("item5"))
    }

    @Test("two constructs the data cannot tell apart are reported as merged")
    func merged() throws {
        // Splitting the first factor's items into two declared constructs: the
        // definitions differ, the answers do not.
        let fit = ConstructFit.compare(try solution(), constructOfItem: [
            "item0": "ก", "item1": "ก",
            "item2": "ข",
            "item3": "ค", "item4": "ค", "item5": "ค",
        ])
        #expect(fit.mergedConstructs == [["ก", "ข"]])
        #expect(fit.summary.contains("แยกไม่ออก"))
    }
}

@Suite("ω beside α")
struct OmegaTests {

    /// Data from a one-factor model with the loadings given, so α and ω have a
    /// population value to be near.
    private func generate(loadings: [Double], respondents: Int,
                          seed: UInt64) -> [[Double]] {
        var generator = SeededGenerator(seed: seed)
        return (0..<respondents).map { _ in
            let common = generator.nextNormal()
            return loadings.map { loading in
                loading * common + (1 - loading * loading).squareRoot() * generator.nextNormal()
            }
        }
    }

    @Test("α and ω agree when the items are equally good — which is α's assumption")
    func tauEquivalent() throws {
        let items = itemNames(6)
        let scores = generate(loadings: [Double](repeating: 0.7, count: 6),
                              respondents: 800, seed: 4_242)
        let alpha = try #require(Reliability.cronbach(scores: scores, itemIDs: items))
        let omega = try #require(Reliability.omega(scores: scores, itemIDs: items))
        #expect(abs(alpha.alpha - omega.omega) < 0.02)
    }

    @Test("ω exceeds α when they are not — which is why ω is worth the loadings")
    func congeneric() throws {
        let items = itemNames(6)
        let scores = generate(loadings: [0.9, 0.85, 0.8, 0.4, 0.35, 0.3],
                              respondents: 800, seed: 9_137)
        let alpha = try #require(Reliability.cronbach(scores: scores, itemIDs: items))
        let omega = try #require(Reliability.omega(scores: scores, itemIDs: items))
        #expect(omega.omega > alpha.alpha)
        #expect(omega.varianceExplained > 0.3)
    }
}
