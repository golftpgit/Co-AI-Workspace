import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// P19.6 — the two questions asked before anybody collects anything.
//
// The sample-size formulas are the standard normal-approximation ones every
// textbook prints; the expected values below were computed independently
// outside this codebase, and the round numbers (63 per group for a half-SD
// difference at 80% power) are the ones a reviewer recognises.
// ─────────────────────────────────────────────────────────────

private func isClose(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-5) -> Bool {
    abs(actual - expected) <= tolerance
}

@Suite("How many, and how well they agree")
struct StudySizeTests {

    @Test("two means: the familiar 63 per group")
    func twoMeans() throws {
        // A five-unit difference with SD 10 — half a standard deviation, the
        // textbook example — needs 63 per group at 80% power.
        let eighty = try StudySize.twoMeans(difference: 5, standardDeviation: 10)
        #expect(eighty.perGroup == 63)
        #expect(eighty.total == 126)

        // 90% costs a third more people, which is the trade a protocol has to
        // state rather than assume.
        let ninety = try StudySize.twoMeans(difference: 5, standardDeviation: 10, power: 0.9)
        #expect(ninety.perGroup == 85)
    }

    @Test("two proportions: 163 per group for 30% against 45%")
    func twoProportions() throws {
        let size = try StudySize.twoProportions(0.30, 0.45)
        #expect(size.perGroup == 163)
        // The number is meaningless without what it assumed, so it travels with
        // it — an ethics committee asks exactly this.
        #expect(size.assumption.contains("0.3"))
        #expect(size.assumption.contains("0.45"))
    }

    @Test("a fraction of a participant rounds up, never down")
    func roundingIsAlwaysUp() throws {
        // 62.79 becomes 63. Rounding down is how a study ends up under-powered
        // by design, and by less than one person.
        let size = try StudySize.twoMeans(difference: 5, standardDeviation: 10)
        let exact = 2 * pow(1.959964 + 0.841621, 2) * 100 / 25
        #expect(Double(size.perGroup) >= exact)
        #expect(Double(size.perGroup) - exact < 1)
    }

    @Test("the other direction: what a study this size can actually see")
    func powerFromSampleSize() throws {
        // The honest question when the sample is whoever is available.
        let power = try StudySize.power(perGroup: 100, difference: 5, standardDeviation: 10)
        #expect(isClose(power, 0.942438, 1e-5))

        let underpowered = try StudySize.power(perGroup: 20, difference: 5, standardDeviation: 10)
        #expect(underpowered < 0.5, "a study this size cannot see this effect")
    }

    @Test("an effect of zero is refused rather than answered with infinity")
    func impossibleDesignsAreRefused() {
        #expect(throws: StatError.self) {
            _ = try StudySize.twoMeans(difference: 0, standardDeviation: 10)
        }
        #expect(throws: StatError.self) {
            _ = try StudySize.twoProportions(0.4, 0.4)
        }
        #expect(throws: StatError.self) {
            _ = try StudySize.twoMeans(difference: 5, standardDeviation: 10, power: 1.0)
        }
    }
}

@Suite("Do two ways of measuring agree")
struct MethodAgreementTests {

    /// Two devices on the same ten patients.
    private let deviceA: [Double] = [120, 132, 140, 128, 150, 138, 142, 126, 134, 146]
    private let deviceB: [Double] = [124, 130, 146, 126, 152, 141, 139, 131, 133, 151]

    @Test("the answer is the limits of agreement, not the bias")
    func limitsOfAgreement() throws {
        let result = try MethodAgreement.blandAltman(deviceA, deviceB)
        #expect(isClose(result.bias, -1.7))
        #expect(isClose(result.standardDeviation, 3.400980, 1e-6))
        // On average they are 1.7 apart. On any one patient they can be 8
        // apart, and that is the number a clinician needs.
        #expect(isClose(result.limitsOfAgreement.lower, -8.365921, 1e-5))
        #expect(isClose(result.limitsOfAgreement.upper, 4.965921, 1e-5))
    }

    @Test("each limit carries its own uncertainty, which is large on a small study")
    func limitsHaveIntervals() throws {
        let result = try MethodAgreement.blandAltman(deviceA, deviceB)
        // Student's t on 9 degrees of freedom, not a normal quantile: ten pairs
        // is exactly the size where the difference changes the conclusion.
        #expect(isClose(result.lowerLimitInterval.lower, -12.579853, 1e-4))
        #expect(isClose(result.biasInterval.lower, -4.132915, 1e-4))
        #expect(isClose(result.biasInterval.upper, 0.732915, 1e-4))
        // The bias interval crosses zero: on average these two agree.
        #expect(result.biasInterval.lower < 0 && result.biasInterval.upper > 0)
    }

    /// The judgement that arithmetic cannot make.
    @Test("whether the two are interchangeable needs a clinical limit, supplied")
    func interchangeabilityNeedsAClinicalLimit() throws {
        let result = try MethodAgreement.blandAltman(deviceA, deviceB)
        // If ten units of disagreement would not change treatment, these are
        // interchangeable. If five would, they are not — same data, and no
        // amount of statistics decides which.
        #expect(result.isInterchangeable(withinClinicalLimit: 10))
        #expect(result.isInterchangeable(withinClinicalLimit: 5) == false)
    }

    @Test("unpaired or tiny inputs are refused")
    func badInputsAreRefused() {
        #expect(throws: StatError.self) {
            _ = try MethodAgreement.blandAltman([1, 2, 3], [1, 2])
        }
        #expect(throws: StatError.self) {
            _ = try MethodAgreement.blandAltman([1, 2], [1, 2])
        }
    }

    @Test("two methods that move together perfectly can still disagree badly")
    func correlationIsNotAgreement() throws {
        // The whole reason Bland–Altman exists: this pair correlates at 1.0 and
        // reads five units apart on every single patient.
        let offset = deviceA.map { $0 + 5 }
        let result = try MethodAgreement.blandAltman(deviceA, offset)
        #expect(isClose(result.bias, -5))
        #expect(isClose(result.standardDeviation, 0))
        #expect(result.isInterchangeable(withinClinicalLimit: 2) == false)
    }
}
