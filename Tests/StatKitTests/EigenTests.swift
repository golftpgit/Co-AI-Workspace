import Testing
import Foundation
@testable import StatKit

// Checked against matrices whose answers are known without computing them
// (risk R12: "a statistic written here is wrong quietly"). An equicorrelation
// matrix `(1−ρ)I + ρJ` has eigenvalue `1 + (p−1)ρ` once and `1 − ρ` the other
// p−1 times, and determinant `(1−ρ)^(p−1)(1 + (p−1)ρ)` — no arithmetic of ours
// is involved in the expected values, which is the point.

private func equicorrelation(_ p: Int, _ rho: Double) -> [[Double]] {
    (0..<p).map { row in (0..<p).map { column in row == column ? 1 : rho } }
}

@Suite("symmetric eigen-decomposition")
struct EigenTests {

    @Test("eigenvalues of an equicorrelation matrix are the published closed form")
    func equicorrelationEigenvalues() throws {
        let rho = 0.4
        let p = 5
        let eigen = try SymmetricEigen.of(equicorrelation(p, rho))

        #expect(eigen.order == p)
        #expect(abs(eigen.values[0] - (1 + Double(p - 1) * rho)) < 1e-12)
        for index in 1..<p {
            #expect(abs(eigen.values[index] - (1 - rho)) < 1e-12)
        }
        let determinant = pow(1 - rho, Double(p - 1)) * (1 + Double(p - 1) * rho)
        #expect(abs(eigen.determinant - determinant) < 1e-12)
    }

    @Test("the leading eigenvector of an equicorrelation matrix is the equal-weight one")
    func equicorrelationEigenvector() throws {
        let eigen = try SymmetricEigen.of(equicorrelation(4, 0.6))
        let expected = 1.0 / 2.0   // 1/√4
        for weight in eigen.vectors[0] {
            #expect(abs(abs(weight) - expected) < 1e-12)
        }
    }

    @Test("a diagonal matrix decomposes to itself, sorted")
    func diagonal() throws {
        let eigen = try SymmetricEigen.of([[2, 0, 0], [0, 7, 0], [0, 0, 5]])
        #expect(eigen.values.map { ($0 * 1e9).rounded() / 1e9 } == [7, 5, 2])
    }

    @Test("the inverse is the actual inverse")
    func inverse() throws {
        let matrix = [[1.0, 0.3, 0.2], [0.3, 1.0, 0.5], [0.2, 0.5, 1.0]]
        let inverse = try SymmetricEigen.of(matrix).inverse()
        for row in 0..<3 {
            for column in 0..<3 {
                let product = (0..<3).reduce(0.0) { $0 + matrix[row][$1] * inverse[$1][column] }
                #expect(abs(product - (row == column ? 1 : 0)) < 1e-12)
            }
        }
    }

    @Test("the inverse is symmetric to the last bit, not merely nearly")
    func inverseIsExactlySymmetric() throws {
        let inverse = try SymmetricEigen.of([[1.0, 0.7, 0.1],
                                             [0.7, 1.0, 0.4],
                                             [0.1, 0.4, 1.0]]).inverse()
        #expect(inverse[0][1] == inverse[1][0])
        #expect(inverse[0][2] == inverse[2][0])
        #expect(inverse[1][2] == inverse[2][1])
    }

    @Test("a singular matrix is refused rather than inverted into large numbers")
    func singular() throws {
        // Third variable is the first one exactly: ρ = 1 between them.
        let eigen = try SymmetricEigen.of([[1.0, 0.5, 1.0],
                                           [0.5, 1.0, 0.5],
                                           [1.0, 0.5, 1.0]])
        #expect(throws: LinearAlgebraError.self) { try eigen.inverse() }
    }

    @Test("an asymmetric matrix is refused, not silently read on one side")
    func asymmetric() {
        #expect(throws: LinearAlgebraError.self) {
            try SymmetricEigen.of([[1.0, 0.5], [0.9, 1.0]])
        }
    }

    @Test("a ragged matrix is refused")
    func ragged() {
        #expect(throws: LinearAlgebraError.self) {
            try SymmetricEigen.of([[1.0, 0.5], [0.5]])
        }
    }

    @Test("the sign convention is stable, so a loading table does not flip between runs")
    func deterministicSigns() throws {
        let matrix = equicorrelation(6, 0.35)
        let first = try SymmetricEigen.of(matrix)
        let second = try SymmetricEigen.of(matrix)
        #expect(first.vectors == second.vectors)
        // Largest component positive, by construction.
        for vector in first.vectors {
            let extreme = vector.max(by: { abs($0) < abs($1) }) ?? 0
            #expect(extreme > 0)
        }
    }
}

@Suite("distribution tails")
struct DistributionTests {

    @Test("chi-square tails match the values printed in every statistics table")
    func chiSquareTable() {
        // The 5% critical values for 1–5 df, from the published table. A tail
        // computed at the critical value has to come back to .05.
        let critical: [Double: Double] = [1: 3.841, 2: 5.991, 3: 7.815, 4: 9.488, 5: 11.070]
        for (df, x) in critical {
            let p = Distributions.chiSquarePValue(x, degreesOfFreedom: df)
            #expect(abs(p - 0.05) < 5e-4, "df \(df) gave p = \(p)")
        }
    }

    @Test("the normal CDF matches its published quantiles")
    func normal() {
        #expect(abs(Distributions.normalCDF(1.959963985) - 0.975) < 1e-9)
        #expect(abs(Distributions.normalCDF(0) - 0.5) < 1e-15)
        #expect(abs(Distributions.normalQuantile(0.975) - 1.959963985) < 1e-7)
    }

    @Test("nonsense arguments give NaN rather than a number somebody would quote")
    func refusals() {
        #expect(Distributions.chiSquarePValue(5, degreesOfFreedom: 0).isNaN)
        #expect(Distributions.chiSquarePValue(-1, degreesOfFreedom: 3).isNaN)
    }
}
