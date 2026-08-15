import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// P19.1 — the measures a medical paper is written in, checked against a
// published trial's counts (R12: never against our own output).
//
// The trial is the Physicians' Health Study aspirin arm, which is in every
// epidemiology textbook precisely because the numbers are memorable: 104
// myocardial infarctions among 11,037 taking aspirin against 189 among 11,034
// taking placebo. The published relative risk is 0.55 and the "44% reduction"
// headline is the same number said the other way round.
//
// The counts are the published part. Every interval below was computed
// independently — the same formulas in a separate implementation, outside this
// codebase — because a test that checks Swift against Swift checks nothing.
// ─────────────────────────────────────────────────────────────

private let physiciansHealthStudy = TwoByTwo(
    exposedCases: 104, exposedNonCases: 11_037 - 104,
    unexposedCases: 189, unexposedNonCases: 11_034 - 189)

/// Tight enough that a wrong z-value or a swapped denominator fails, loose
/// enough to survive floating-point ordering.
private func isClose(_ actual: Double, _ expected: Double,
                     tolerance: Double = 1e-6) -> Bool {
    abs(actual - expected) <= tolerance * max(1, abs(expected))
}

@Suite("Epidemiological measures")
struct EpidemiologyTests {

    @Test("risk ratio matches the published trial, interval and all")
    func riskRatioMatchesPublished() throws {
        let rr = try Epidemiology.riskRatio(physiciansHealthStudy)
        // 0.55 is the number the trial is known by.
        #expect(isClose(rr.value, 0.5501149812103875))
        #expect(isClose(rr.lower, 0.43367311590896745))
        #expect(isClose(rr.upper, 0.6978216574892077))
        #expect(rr.includes(1) == false, "an interval excluding 1 is the finding")
        #expect(rr.method.contains("Katz"))
    }

    @Test("odds ratio is not the risk ratio, and the difference shows")
    func oddsRatioIsItsOwnMeasure() throws {
        let or = try Epidemiology.oddsRatio(physiciansHealthStudy)
        #expect(isClose(or.value, 0.5458354566559085))
        #expect(isClose(or.lower, 0.4290409679420482))
        #expect(isClose(or.upper, 0.6944240014464241))
        // Close here because the outcome is rare — which is the condition
        // under which an odds ratio may be read as a risk ratio at all, and
        // the reason the two are constantly confused in papers where it does
        // not hold.
        let rr = try Epidemiology.riskRatio(physiciansHealthStudy)
        #expect(abs(or.value - rr.value) < 0.01)
    }

    @Test("risk difference carries the effect in the units people are treated in")
    func riskDifferenceIsAbsolute() throws {
        let rd = try Epidemiology.riskDifference(physiciansHealthStudy)
        #expect(isClose(rd.value, -0.0077060239760047815))
        #expect(isClose(rd.lower, -0.010724297276960124))
        #expect(isClose(rd.upper, -0.004687750675049439))
        // 0.77 percentage points, against a 45% relative reduction: the same
        // result, and the two sentences persuade differently.
        #expect(rd.includes(0) == false)
    }

    @Test("number needed to treat inverts the interval, and says which direction it is")
    func numberNeededToTreat() throws {
        let nnt = try Epidemiology.numberNeededToTreat(physiciansHealthStudy)
        // About 130 men had to take aspirin for one myocardial infarction not
        // to happen — the same result as "44% relative reduction", in the units
        // somebody deciding whether to take it can use.
        #expect(isClose(nnt.value, 129.76860740556037, tolerance: 1e-9))
        #expect(isClose(nnt.lower, 93.24620291423486, tolerance: 1e-9))
        #expect(isClose(nnt.upper, 213.32192544336917, tolerance: 1e-9))
        // A count of people, so positive, with the direction in the name: a
        // minus sign is what goes missing between a table and a sentence, and
        // NNT and NNH mean opposite things.
        #expect(nnt.method.contains("NNT"))

        let harmful = TwoByTwo(exposedCases: 189, exposedNonCases: 11_034 - 189,
                               unexposedCases: 104, unexposedNonCases: 11_037 - 104)
        let nnh = try Epidemiology.numberNeededToTreat(harmful)
        #expect(isClose(nnh.value, 129.76860740556037, tolerance: 1e-9))
        #expect(nnh.method.contains("NNH"), "harm was reported as benefit")
    }

    /// The error that keeps reaching print: an NNT quoted from a risk
    /// difference whose interval crosses zero. Inverting that interval does not
    /// give a range — it gives two rays with a hole in the middle, and printing
    /// its ends as a confidence interval states the opposite of the data.
    @Test("an NNT is refused when the risk difference could be zero")
    func nntRefusesWhenTheIntervalCrossesZero() {
        let noEffect = TwoByTwo(exposedCases: 50, exposedNonCases: 450,
                                unexposedCases: 55, unexposedNonCases: 445)
        #expect(throws: StatError.self) {
            _ = try Epidemiology.numberNeededToTreat(noEffect)
        }
        // The risk difference itself is still reportable — it is the inversion
        // that is invalid, not the estimate.
        #expect(throws: Never.self) { _ = try Epidemiology.riskDifference(noEffect) }
    }

    @Test("a zero cell is refused rather than silently corrected")
    func emptyCellIsRefused() {
        // Adding 0.5 to every cell is a real correction with a name, and doing
        // it quietly hands back an estimate for a table nobody has.
        let noEventsExposed = TwoByTwo(exposedCases: 0, exposedNonCases: 100,
                                       unexposedCases: 12, unexposedNonCases: 88)
        #expect(throws: StatError.self) { _ = try Epidemiology.riskRatio(noEventsExposed) }
        #expect(throws: StatError.self) { _ = try Epidemiology.oddsRatio(noEventsExposed) }
    }

    // ─────────────────────────────────────────────────────────

    @Test("a proportion uses Wilson, so zero events is not perfect certainty")
    func prevalenceUsesWilson() throws {
        let none = try Epidemiology.prevalence(cases: 0, population: 20)
        #expect(none.value == 0)
        #expect(none.lower == 0)
        // Wald would say [0, 0] here: twenty observations claiming the rate is
        // exactly zero. Wilson says what twenty observations support.
        #expect(isClose(none.upper, 0.16112515805281938))

        let common = try Epidemiology.prevalence(cases: 90, population: 100)
        #expect(isClose(common.lower, 0.8256343384950865))
        #expect(isClose(common.upper, 0.9447708629393249))
    }

    @Test("an incidence rate is per person-time, with a Poisson interval")
    func incidenceRate() throws {
        let rate = try Epidemiology.incidenceRate(cases: 28, personTime: 5_000)
        #expect(isClose(rate.value, 0.0056))
        #expect(isClose(rate.lower, 0.003866571590484998))
        #expect(isClose(rate.upper, 0.00811054425506354))
        // The count carries the uncertainty: same rate, ten times the events,
        // a much tighter interval.
        let tighter = try Epidemiology.incidenceRate(cases: 280, personTime: 50_000)
        #expect(isClose(tighter.value, 0.0056))
        #expect(tighter.upper - tighter.lower < rate.upper - rate.lower)
    }

    @Test("age standardisation answers what a crude rate cannot")
    func ageStandardisation() throws {
        // A young-skewed population and an old-skewed standard: the crude rate
        // and the standardised rate come apart, which is the whole reason the
        // measure exists.
        let strata = [
            Epidemiology.Stratum(cases: 30, personTime: 10_000, standardWeight: 60_000),
            Epidemiology.Stratum(cases: 70, personTime: 5_000, standardWeight: 40_000),
        ]
        let standardised = try Epidemiology.ageStandardisedRate(strata)
        #expect(isClose(standardised.value, 0.0074))
        #expect(isClose(standardised.lower, 0.0059385448675015945))
        #expect(isClose(standardised.upper, 0.008861455132498407))

        // Crude: 100 cases in 15,000 person-time = 0.00667. The standardised
        // rate is higher because the standard population is older than this
        // one, and reporting the crude number would say this place is healthier
        // than a place it is not comparable with.
        #expect(standardised.value > 100.0 / 15_000.0)
    }

    @Test("every measure comes back with an interval — there is no way to ask for less")
    func nothingReturnsABareNumber() throws {
        // Structural rather than behavioural: a point estimate on its own is
        // the number that gets quoted, and eleven events and eleven hundred
        // produce the same sentence without one.
        let all: [Estimate] = [
            try Epidemiology.riskRatio(physiciansHealthStudy),
            try Epidemiology.oddsRatio(physiciansHealthStudy),
            try Epidemiology.riskDifference(physiciansHealthStudy),
            try Epidemiology.numberNeededToTreat(physiciansHealthStudy),
            try Epidemiology.prevalence(cases: 90, population: 100),
            try Epidemiology.incidenceRate(cases: 28, personTime: 5_000),
        ]
        for estimate in all {
            #expect(estimate.isFinite)
            #expect(estimate.lower <= estimate.value && estimate.value <= estimate.upper)
            #expect(!estimate.method.isEmpty, "an interval that does not name its method")
        }
    }
}
