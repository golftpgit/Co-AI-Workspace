import Foundation
import CLapack

// ─────────────────────────────────────────────────────────────
// Linear algebra from the operating system (ARCHITECTURE §20.4, P11.3).
//
// EFA needs an eigen-decomposition, and an eigen-decomposition written by hand
// is the kind of code that is *nearly* right for years: Jacobi rotations
// converge on small well-behaved matrices and lose accuracy exactly where a
// correlation matrix gets interesting — near-singular, one variable almost a
// combination of the others. Accelerate ships LAPACK on every Mac this app runs
// on, so §4's "OS-native before writing our own" answers the question.
//
// Everything downstream is derived from this one call: the determinant is the
// product of the eigenvalues, the inverse is `V Λ⁻¹ Vᵀ`, and both come out of
// the same decomposition rather than a second routine that could disagree with
// the first about whether a matrix is singular.
// ─────────────────────────────────────────────────────────────

public enum LinearAlgebraError: Error, CustomStringConvertible, Equatable {
    case notSquare(rows: Int, columns: Int)
    case empty
    case notSymmetric(row: Int, column: Int)
    case didNotConverge(info: Int)
    /// The matrix has an eigenvalue at (numerically) zero: some variable is a
    /// linear combination of the others, so there is no inverse and no honest
    /// determinant.
    case singular(smallestEigenvalue: Double)

    public var description: String {
        switch self {
        case .notSquare(let rows, let columns):
            "เมทริกซ์ต้องเป็นจัตุรัส (ได้ \(rows)×\(columns))"
        case .empty:
            "เมทริกซ์ว่าง"
        case .notSymmetric(let row, let column):
            "เมทริกซ์ไม่สมมาตรที่ตำแหน่ง (\(row), \(column)) — "
                + "เมทริกซ์สหสัมพันธ์ที่ไม่สมมาตรแปลว่าคำนวณมาผิดตั้งแต่ต้น"
        case .didNotConverge(let info):
            "การแยกค่าลักษณะเฉพาะไม่ลู่เข้า (LAPACK info = \(info))"
        case .singular(let smallest):
            String(format: "เมทริกซ์เอกฐาน (ค่าลักษณะเฉพาะต่ำสุด %.2e) — ", smallest)
                + "มีตัวแปรที่เป็นผลรวมเชิงเส้นของตัวอื่น เช่น ข้อที่ถามซ้ำกัน "
                + "หรือคะแนนรวมที่ใส่มาเป็นข้ออีกข้อหนึ่ง"
        }
    }
}

/// The decomposition of a real symmetric matrix, eigenvalues **descending**.
public struct SymmetricEigen: Sendable, Equatable {
    /// Descending, which is the order every scree plot and every factor-retention
    /// rule is written in. LAPACK returns ascending; the reversal happens once,
    /// here, rather than at each of the four call sites that would forget.
    public let values: [Double]
    /// `vectors[j]` is the unit eigenvector belonging to `values[j]`.
    public let vectors: [[Double]]

    public var order: Int { values.count }

    /// The product of the eigenvalues. For a correlation matrix this is the
    /// determinant Bartlett's test of sphericity takes the log of.
    public var determinant: Double { values.reduce(1, *) }

    /// `V Λ⁻¹ Vᵀ`, from the decomposition already computed.
    ///
    /// `tolerance` is what counts as zero. The default is LAPACK's usual
    /// `n · ε · λmax`: a matrix whose smallest eigenvalue is below that has a
    /// variable that adds nothing, and inverting it produces enormous numbers
    /// that look like findings.
    public func inverse(tolerance: Double? = nil) throws -> [[Double]] {
        guard let largest = values.first else { throw LinearAlgebraError.empty }
        let limit = tolerance ?? Double(order) * .ulpOfOne * max(abs(largest), 1)
        guard let smallest = values.last, smallest > limit else {
            throw LinearAlgebraError.singular(smallestEigenvalue: values.last ?? 0)
        }
        var result = [[Double]](repeating: [Double](repeating: 0, count: order), count: order)
        for k in 0..<order {
            let vector = vectors[k]
            let weight = 1 / values[k]
            for row in 0..<order {
                let scaled = weight * vector[row]
                for column in row..<order {
                    result[row][column] += scaled * vector[column]
                }
            }
        }
        // Filled upper-triangle first: the inverse of a symmetric matrix is
        // symmetric, and computing both halves separately is how the two drift
        // apart by a few ulps and make an equality test flaky.
        for row in 0..<order {
            for column in 0..<row { result[row][column] = result[column][row] }
        }
        return result
    }

    /// Decomposes `matrix`, which must be square and symmetric.
    ///
    /// Symmetry is checked rather than assumed: LAPACK reads only the upper
    /// triangle, so a matrix that is asymmetric because of a bug upstream would
    /// decompose happily and answer a question nobody asked.
    public static func of(_ matrix: [[Double]],
                          symmetryTolerance: Double = 1e-9) throws -> SymmetricEigen {
        let n = matrix.count
        guard n > 0 else { throw LinearAlgebraError.empty }
        for (index, row) in matrix.enumerated() where row.count != n {
            throw LinearAlgebraError.notSquare(rows: n, columns: matrix[index].count)
        }
        for row in 0..<n {
            for column in (row + 1)..<n where abs(matrix[row][column] - matrix[column][row])
                > symmetryTolerance {
                throw LinearAlgebraError.notSymmetric(row: row, column: column)
            }
        }

        var flat = [Double](repeating: 0, count: n * n)
        for row in 0..<n {
            for column in 0..<n { flat[row * n + column] = matrix[row][column] }
        }
        var ascending = [Double](repeating: 0, count: n)
        var columns = [Double](repeating: 0, count: n * n)
        let info = coai_symmetric_eigen(&flat, Int32(n), &ascending, &columns)
        guard info == 0 else { throw LinearAlgebraError.didNotConverge(info: Int(info)) }

        var values: [Double] = []
        var vectors: [[Double]] = []
        values.reserveCapacity(n)
        vectors.reserveCapacity(n)
        for index in stride(from: n - 1, through: 0, by: -1) {
            values.append(ascending[index])
            var vector = Array(columns[(index * n)..<((index + 1) * n)])
            // LAPACK's sign convention is arbitrary; a loading table that flips
            // sign between two runs of the same data is a table nobody trusts.
            // Fixing the largest component positive makes it deterministic.
            if let extreme = vector.max(by: { abs($0) < abs($1) }), extreme < 0 {
                vector = vector.map { -$0 }
            }
            vectors.append(vector)
        }
        return SymmetricEigen(values: values, vectors: vectors)
    }
}
