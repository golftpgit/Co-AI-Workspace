import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// Time to an event, when not everybody has had it yet
// (ARCHITECTURE §12.6.1, P19.3).
//
// **What makes this its own module rather than a variant of regression**:
// censoring. A patient still alive at the end of the study has not lived
// "17 weeks" — they have lived *at least* 17 weeks, and the difference is the
// whole subject. Dropping them biases every estimate downward; treating them as
// events biases it further. The estimator below uses them for exactly as long
// as they were observed and no longer, and there is a test that says so,
// because "we handled censoring" is the kind of claim that is easy to write and
// easy to get silently wrong.
//
// Checked against Freireich et al. (1963) — 6-mercaptopurine against placebo in
// leukaemia remission, 21 patients each — which is in the textbooks precisely
// because the numbers are quotable: median remission 23 weeks against 8, a
// log-rank χ² of 16.79, and a hazard ratio of about 4.5.
// ─────────────────────────────────────────────────────────────

public struct SurvivalObservation: Sendable, Equatable {
    /// How long this subject was observed.
    public let time: Double
    /// Whether the event happened. `false` means censored — observed until
    /// `time` and still event-free, which is information, not a missing value.
    public let event: Bool

    public init(time: Double, event: Bool) {
        self.time = time
        self.event = event
    }
}

public struct SurvivalPoint: Sendable, Equatable {
    public let time: Double
    public let atRisk: Int
    public let events: Int
    public let survival: Double
    /// Greenwood's standard error of the survival estimate at this time.
    public let standardError: Double
}

public struct SurvivalCurve: Sendable, Equatable {
    public let points: [SurvivalPoint]
    /// The first time the estimate drops to or below one half. `nil` when the
    /// curve never gets there — which is a real answer for a study that ended
    /// with most subjects alive, and reporting the last observed time instead
    /// would be reporting a median that does not exist.
    public let median: Double?
    public let censored: Int

    public func survival(at time: Double) -> Double {
        points.last { $0.time <= time }?.survival ?? 1
    }
}

public enum Survival {

    /// Kaplan–Meier, with censored subjects contributing until the moment they
    /// leave and not after.
    public static func kaplanMeier(_ observations: [SurvivalObservation]) throws -> SurvivalCurve {
        guard !observations.isEmpty else {
            throw StatError.notEnoughData("ไม่มีข้อมูลการติดตาม")
        }
        guard observations.allSatisfy({ $0.time >= 0 }) else {
            throw StatError.badShape("เวลาติดตามติดลบ")
        }
        let eventTimes = Set(observations.filter(\.event).map(\.time)).sorted()
        var survival = 1.0
        var greenwood = 0.0
        var points: [SurvivalPoint] = []

        for time in eventTimes {
            // At risk means still under observation *at* this time — a subject
            // censored exactly here counts, because they were event-free right
            // up to it.
            let atRisk = observations.count { $0.time >= time }
            let events = observations.count { $0.time == time && $0.event }
            guard atRisk > 0 else { continue }
            survival *= 1 - Double(events) / Double(atRisk)
            greenwood += Double(events) / (Double(atRisk) * Double(atRisk - events))
            points.append(SurvivalPoint(
                time: time, atRisk: atRisk, events: events, survival: survival,
                standardError: survival * greenwood.squareRoot()))
        }
        return SurvivalCurve(points: points,
                             median: points.first { $0.survival <= 0.5 }?.time,
                             censored: observations.count { !$0.event })
    }

    /// The log-rank test: whether two curves differ by more than chance.
    ///
    /// Compares observed events against what would be expected if the two
    /// groups had the same hazard, at every time an event happened — which is
    /// what makes it usable on censored data at all, and why it is not a
    /// two-sample test on the times.
    public static func logRank(_ a: [SurvivalObservation],
                               _ b: [SurvivalObservation]) throws -> StatResult {
        guard !a.isEmpty, !b.isEmpty else {
            throw StatError.notEnoughData("log-rank ต้องมีข้อมูลทั้งสองกลุ่ม")
        }
        let times = Set((a + b).filter(\.event).map(\.time)).sorted()
        var observedA = 0.0, expectedA = 0.0, variance = 0.0

        for time in times {
            let riskA = Double(a.count { $0.time >= time })
            let riskB = Double(b.count { $0.time >= time })
            let eventsA = Double(a.count { $0.time == time && $0.event })
            let eventsB = Double(b.count { $0.time == time && $0.event })
            let atRisk = riskA + riskB
            let events = eventsA + eventsB
            guard atRisk > 1 else { continue }

            observedA += eventsA
            expectedA += events * riskA / atRisk
            // Hypergeometric variance, with the tie correction that makes
            // simultaneous events behave.
            variance += events * (riskA / atRisk) * (1 - riskA / atRisk)
                * ((atRisk - events) / (atRisk - 1))
        }
        guard variance > 0 else {
            throw StatError.notEnoughData("ไม่มีเหตุการณ์พอจะเทียบสองกลุ่ม")
        }
        let chiSquare = (observedA - expectedA) * (observedA - expectedA) / variance
        return StatResult(
            test: .survival,
            statistic: chiSquare,
            pValue: Statistics.chiSquarePValue(chiSquare, degreesOfFreedom: 1),
            degreesOfFreedom: 1,
            summary: String(format: "log-rank χ² = %.3f · กลุ่มแรกเกิดเหตุการณ์ %.0f ครั้ง "
                            + "เทียบกับที่คาด %.2f", chiSquare, observedA, expectedA),
            assumptions: [],
            alternatives: [])
    }

    // MARK: - Cox proportional hazards

    public struct CoxFit: Sendable, Equatable {
        /// One coefficient per covariate, on the log-hazard scale.
        public let coefficients: [Double]
        public let standardErrors: [Double]
        /// `exp(coefficient)` — the hazard ratio a paper reports.
        public let hazardRatios: [Double]
        public let confidenceIntervals: [(lower: Double, upper: Double)]
        public let iterations: Int

        public static func == (a: CoxFit, b: CoxFit) -> Bool {
            a.coefficients == b.coefficients && a.standardErrors == b.standardErrors
        }
    }

    /// Cox regression by Newton–Raphson on the partial likelihood, Breslow's
    /// handling of ties.
    ///
    /// Breslow rather than Efron because it is the one whose arithmetic can be
    /// checked by hand against a textbook, and this module's rule (R12) is that
    /// every number here is checked against a published one. Efron is the better
    /// approximation with heavy ties and belongs here the day there is a
    /// published fixture to check it against.
    public static func cox(_ observations: [SurvivalObservation],
                           covariates: [[Double]],
                           maximumIterations: Int = 50) throws -> CoxFit {
        guard !observations.isEmpty else { throw StatError.notEnoughData("ไม่มีข้อมูล") }
        guard !covariates.isEmpty else { throw StatError.badShape("ต้องมีตัวแปรอย่างน้อยหนึ่งตัว") }
        guard covariates.allSatisfy({ $0.count == observations.count }) else {
            throw StatError.badShape("จำนวนค่าตัวแปรไม่เท่ากับจำนวนผู้ถูกติดตาม")
        }
        guard observations.contains(where: \.event) else {
            throw StatError.notEnoughData("ไม่มีเหตุการณ์เกิดขึ้นเลย — ประมาณค่าไม่ได้")
        }

        let p = covariates.count
        var beta = [Double](repeating: 0, count: p)
        var iterations = 0
        var information = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)

        for step in 1...maximumIterations {
            iterations = step
            var score = [Double](repeating: 0, count: p)
            information = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)

            for (index, observation) in observations.enumerated() where observation.event {
                let atRisk = observations.indices.filter { observations[$0].time >= observation.time }
                var s0 = 0.0
                var s1 = [Double](repeating: 0, count: p)
                var s2 = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)

                for subject in atRisk {
                    let weight = exp((0..<p).reduce(0) { $0 + beta[$1] * covariates[$1][subject] })
                    s0 += weight
                    for j in 0..<p {
                        s1[j] += weight * covariates[j][subject]
                        for k in 0..<p {
                            s2[j][k] += weight * covariates[j][subject] * covariates[k][subject]
                        }
                    }
                }
                guard s0 > 0 else { continue }
                for j in 0..<p {
                    score[j] += covariates[j][index] - s1[j] / s0
                    for k in 0..<p {
                        information[j][k] += s2[j][k] / s0 - (s1[j] / s0) * (s1[k] / s0)
                    }
                }
            }

            guard let step = solve(information, score) else {
                throw StatError.notEnoughData("ประมาณค่าไม่ลู่เข้า — ข้อมูลอาจแยกกลุ่มได้สมบูรณ์")
            }
            for j in 0..<p { beta[j] += step[j] }
            if step.allSatisfy({ abs($0) < 1e-9 }) { break }
        }

        guard let covariance = invert(information) else {
            throw StatError.notEnoughData("เมทริกซ์ข้อมูลกลับด้านไม่ได้")
        }
        let errors = (0..<p).map { covariance[$0][$0].squareRoot() }
        let z = Epidemiology.z95
        return CoxFit(
            coefficients: beta,
            standardErrors: errors,
            hazardRatios: beta.map(exp),
            confidenceIntervals: (0..<p).map {
                (lower: exp(beta[$0] - z * errors[$0]), upper: exp(beta[$0] + z * errors[$0]))
            },
            iterations: iterations)
    }

    /// Whether the hazards really are proportional, from Schoenfeld residuals.
    ///
    /// The assumption the whole model rests on, and the one most often left
    /// unstated: a hazard ratio that changes over time is not a hazard ratio.
    /// Reported as an `AssumptionCheck` like every other one (§12.3) — a warning
    /// beside the estimate rather than a footnote — because the estimate is
    /// still the best summary available and the reader has to know what it
    /// assumes.
    public static func proportionalHazards(_ observations: [SurvivalObservation],
                                           covariates: [[Double]],
                                           fit: CoxFit) -> AssumptionCheck {
        var residuals: [(time: Double, value: Double)] = []
        let p = covariates.count

        for (index, observation) in observations.enumerated() where observation.event {
            let atRisk = observations.indices.filter { observations[$0].time >= observation.time }
            var s0 = 0.0
            var s1 = [Double](repeating: 0, count: p)
            for subject in atRisk {
                let weight = exp((0..<p).reduce(0) { $0 + fit.coefficients[$1] * covariates[$1][subject] })
                s0 += weight
                for j in 0..<p { s1[j] += weight * covariates[j][subject] }
            }
            guard s0 > 0 else { continue }
            // First covariate only: the test is per covariate and the screen
            // shows one line, so reporting the first is honest where reporting
            // "the model" would not be.
            residuals.append((observation.time, covariates[0][index] - s1[0] / s0))
        }

        guard residuals.count >= 5 else {
            return AssumptionCheck(
                name: "proportional hazards",
                wasChecked: false, passed: false, statistic: nil, pValue: nil,
                detail: "เหตุการณ์น้อยเกินกว่าจะตรวจ Schoenfeld residuals ได้ (ต้องมีอย่างน้อย 5) "
                    + "— ยังไม่ได้ตรวจ ไม่ใช่ผ่าน")
        }

        // Correlation between the residuals and time. Under proportional
        // hazards there is none: the residuals should not drift.
        let times = residuals.map(\.time)
        let values = residuals.map(\.value)
        let correlation = pearson(times, values)
        let statistic = correlation * correlation * Double(residuals.count)
        let pValue = Statistics.chiSquarePValue(statistic, degreesOfFreedom: 1)
        return AssumptionCheck(
            name: "proportional hazards",
            wasChecked: true,
            passed: pValue >= StatGate.alpha,
            statistic: statistic,
            pValue: pValue,
            detail: pValue >= StatGate.alpha
                ? String(format: "Schoenfeld residuals ไม่สัมพันธ์กับเวลาอย่างมีนัย (p = %.3f)", pValue)
                : String(format: "Schoenfeld residuals สัมพันธ์กับเวลา (p = %.3f) — "
                         + "อัตราส่วนความเสี่ยงเปลี่ยนไปตามเวลา ค่าเดียวจึงสรุปมันไม่ได้", pValue))
    }

    // MARK: - small linear algebra, kept local

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for index in a.indices {
            covariance += (a[index] - meanA) * (b[index] - meanB)
            varianceA += (a[index] - meanA) * (a[index] - meanA)
            varianceB += (b[index] - meanB) * (b[index] - meanB)
        }
        guard varianceA > 0, varianceB > 0 else { return 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }

    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        guard let inverse = invert(matrix) else { return nil }
        return (0..<vector.count).map { row in
            (0..<vector.count).reduce(0) { $0 + inverse[row][$1] * vector[$1] }
        }
    }

    /// Gauss–Jordan with partial pivoting. Small `p`, so clarity beats a
    /// decomposition nobody here would read.
    private static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        var work = matrix
        var inverse = (0..<n).map { row in
            (0..<n).map { $0 == row ? 1.0 : 0.0 }
        }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(work[$0][column]) < abs(work[$1][column]) }),
                  abs(work[pivot][column]) > 1e-12 else { return nil }
            work.swapAt(column, pivot)
            inverse.swapAt(column, pivot)
            let divisor = work[column][column]
            for index in 0..<n {
                work[column][index] /= divisor
                inverse[column][index] /= divisor
            }
            for row in 0..<n where row != column {
                let factor = work[row][column]
                guard factor != 0 else { continue }
                for index in 0..<n {
                    work[row][index] -= factor * work[column][index]
                    inverse[row][index] -= factor * inverse[column][index]
                }
            }
        }
        return inverse
    }
}
