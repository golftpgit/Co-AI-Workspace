import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// P19.3 — checked against Freireich et al. (1963), the leukaemia remission
// trial every survival textbook works through: 21 patients on
// 6-mercaptopurine against 21 on placebo, remission time in weeks, with the
// 6-MP arm heavily censored because the trial stopped while most of them were
// still in remission.
//
// The published figures this is measured against: median remission **23 weeks
// against 8**, a log-rank **χ² of 16.79**, and a hazard ratio of about **4.5**
// for placebo. Every interval and residual statistic below was computed
// independently outside this codebase (R12).
// ─────────────────────────────────────────────────────────────

private func observations(_ raw: [(Double, Bool)]) -> [SurvivalObservation] {
    raw.map { SurvivalObservation(time: $0.0, event: $0.1) }
}

/// `+` in the published table means censored — still in remission when the
/// trial ended.
private let mercaptopurine = observations([
    (6, true), (6, true), (6, true), (6, false), (7, true), (9, false),
    (10, true), (10, false), (11, false), (13, true), (16, true), (17, false),
    (19, false), (20, false), (22, true), (23, true), (25, false), (32, false),
    (32, false), (34, false), (35, false),
])

private let placebo = observations([
    (1, true), (1, true), (2, true), (2, true), (3, true), (4, true), (4, true),
    (5, true), (5, true), (8, true), (8, true), (8, true), (8, true), (11, true),
    (11, true), (12, true), (12, true), (15, true), (17, true), (22, true), (23, true),
])

private func isClose(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-4) -> Bool {
    abs(actual - expected) <= tolerance
}

@Suite("Survival analysis")
struct SurvivalTests {

    @Test("Kaplan–Meier reproduces the published curve, censoring and all")
    func kaplanMeierMatchesPublished() throws {
        let curve = try Survival.kaplanMeier(mercaptopurine)
        #expect(curve.censored == 12)
        // The estimate only steps at event times; the censored subjects change
        // the denominator without producing a step of their own.
        #expect(curve.points.map(\.time) == [6, 7, 10, 13, 16, 22, 23])
        #expect(isClose(curve.points[0].survival, 0.8571))
        #expect(isClose(curve.points[0].standardError, 0.0764))
        #expect(isClose(curve.points.last!.survival, 0.4482))
        #expect(isClose(curve.points.last!.standardError, 0.1346))
        #expect(curve.median == 23)

        let control = try Survival.kaplanMeier(placebo)
        #expect(control.median == 8)   // the published pair: 23 weeks against 8
        #expect(control.censored == 0)
    }

    /// The test that says censored subjects were used rather than discarded —
    /// the claim that is easiest to make and easiest to get silently wrong.
    @Test("censored subjects are used for as long as they were observed, and no longer")
    func censoringIsUsedNotDropped() throws {
        let withCensoring = try Survival.kaplanMeier(mercaptopurine)

        // Dropping them entirely: everybody left is an event, so the curve
        // falls much faster and the median collapses.
        let ifDropped = try Survival.kaplanMeier(mercaptopurine.filter(\.event))
        #expect(ifDropped.median! < withCensoring.median!)

        // Treating them as events instead: also wrong, and wrong the same
        // direction.
        let ifCounted = try Survival.kaplanMeier(
            mercaptopurine.map { SurvivalObservation(time: $0.time, event: true) })
        #expect(ifCounted.survival(at: 23) < withCensoring.survival(at: 23))

        // What "used" means precisely: a subject censored at 11 is still in the
        // denominator at 10 and gone from it at 13.
        let atRiskAt10 = withCensoring.points.first { $0.time == 10 }!.atRisk
        let atRiskAt13 = withCensoring.points.first { $0.time == 13 }!.atRisk
        #expect(atRiskAt10 == 15)
        // 15 → 12: the event and the censoring at 10, and the censoring at 11.
        // The censored two are counted at 10 and gone by 13, which is exactly
        // what "used for as long as they were observed" means.
        #expect(atRiskAt13 == 12)
    }

    @Test("the log-rank test reproduces the published χ²")
    func logRankMatchesPublished() throws {
        let result = try Survival.logRank(mercaptopurine, placebo)
        #expect(isClose(result.statistic, 16.7929, 1e-3))
        #expect(result.degreesOfFreedom == 1)
        #expect(result.pValue < 0.001)
        #expect(result.summary.contains("log-rank"))
    }

    @Test("Cox regression reproduces the published hazard ratio")
    func coxMatchesPublished() throws {
        // One covariate: 1 for placebo, 0 for 6-MP. The published hazard ratio
        // is about 4.5 — placebo patients relapse at roughly four and a half
        // times the rate.
        let all = mercaptopurine + placebo
        let treatment = [Double](repeating: 0, count: mercaptopurine.count)
            + [Double](repeating: 1, count: placebo.count)

        let fit = try Survival.cox(all, covariates: [treatment])
        #expect(isClose(fit.coefficients[0], 1.5092, 1e-3))
        #expect(isClose(fit.hazardRatios[0], 4.5231, 1e-3))
        #expect(isClose(fit.standardErrors[0], 0.4096, 1e-3))
        // The interval excludes 1, which is the finding.
        #expect(isClose(fit.confidenceIntervals[0].lower, 2.0268, 1e-3))
        #expect(isClose(fit.confidenceIntervals[0].upper, 10.0938, 1e-3))
        #expect(fit.iterations < 20)
    }

    /// §12.3's rule applied to the assumption this whole model rests on: a
    /// hazard ratio that changes over time is not a hazard ratio.
    @Test("proportional hazards is checked, and reported like any other assumption")
    func proportionalHazardsIsChecked() throws {
        let all = mercaptopurine + placebo
        let treatment = [Double](repeating: 0, count: mercaptopurine.count)
            + [Double](repeating: 1, count: placebo.count)
        let fit = try Survival.cox(all, covariates: [treatment])
        let check = Survival.proportionalHazards(all, covariates: [treatment], fit: fit)

        #expect(check.wasChecked)
        #expect(check.passed, "this dataset is the textbook example of hazards that are proportional")
        #expect(isClose(check.statistic ?? -1, 0.0199, 1e-3))
        #expect(check.detail.contains("Schoenfeld"))
    }

    @Test("too few events means the assumption is unchecked, not passed")
    func tooFewEventsIsUnchecked() throws {
        // "Could not be checked" and "passed" are different answers, and the
        // gate has said so since P6.6.
        let tiny = observations([(1, true), (2, true), (3, false), (4, true)])
        let covariate = [0.0, 1, 0, 1]
        let fit = try Survival.cox(tiny, covariates: [covariate])
        let check = Survival.proportionalHazards(tiny, covariates: [covariate], fit: fit)
        #expect(check.wasChecked == false)
        #expect(check.passed == false)
        #expect(check.detail.contains("not checked, which is not the same as passed"))
    }

    @Test("a study where nothing happened is refused rather than fitted")
    func noEventsIsRefused() {
        let censoredOnly = observations([(5, false), (7, false), (9, false)])
        #expect(throws: StatError.self) {
            _ = try Survival.cox(censoredOnly, covariates: [[0.0, 1, 0]])
        }
        #expect(throws: StatError.self) {
            _ = try Survival.logRank(censoredOnly, censoredOnly)
        }
    }

    @Test("a curve that never reaches half has no median, and says so")
    func noMedianIsNotTheLastTime() throws {
        // Reporting the last observed time would be reporting a median that
        // does not exist, which is the shape of most optimistic survival
        // claims.
        let mostlyAlive = observations([(10, true), (20, false), (30, false),
                                        (40, false), (50, false)])
        let curve = try Survival.kaplanMeier(mostlyAlive)
        #expect(curve.median == nil)
        #expect(curve.points.first!.survival == 0.8)
    }
}
