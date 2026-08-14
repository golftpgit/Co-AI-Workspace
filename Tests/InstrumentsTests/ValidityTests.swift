import Testing
import Foundation
@testable import Instruments

// ─────────────────────────────────────────────────────────────
// Content validity and reliability (ARCHITECTURE §20.4, P11.3).
//
// Checked against values worked out by hand, because that is the only way to know
// these are the published formulas rather than something that merely returns
// numbers in the right range. The thresholds are Rovinelli & Hambleton's for IOC
// and Polit & Beck's for CVI, and they are constants in the code on purpose — a
// threshold with a settings toggle is a threshold that moves the evening before a
// deadline.
// ─────────────────────────────────────────────────────────────

@Suite("Content validity")
struct ContentValidityTests {

    @Test("IOC is the mean of +1/0/−1 across experts")
    func iocIsAMean() {
        // Three experts: +1, +1, 0 → 0.667, which clears 0.5.
        let ratings = [
            ExpertRating(itemID: "a", expert: "ก", congruence: 1),
            ExpertRating(itemID: "a", expert: "ข", congruence: 1),
            ExpertRating(itemID: "a", expert: "ค", congruence: 0),
            // +1, −1, 0 → 0.0, which does not.
            ExpertRating(itemID: "b", expert: "ก", congruence: 1),
            ExpertRating(itemID: "b", expert: "ข", congruence: -1),
            ExpertRating(itemID: "b", expert: "ค", congruence: 0),
        ]
        let validity = ContentValidity.assess(ratings: ratings, itemIDs: ["a", "b"])
        let a = validity.items.first { $0.itemID == "a" }
        let b = validity.items.first { $0.itemID == "b" }
        #expect(abs((a?.ioc ?? 0) - 2.0 / 3.0) < 0.001)
        #expect(a?.passes == true)
        #expect(b?.ioc == 0)
        #expect(b?.passes == false)
        #expect(b?.reason?.contains("0.50") == true)
        #expect(!validity.passes)
        #expect(validity.experts == ["ก", "ข", "ค"])
    }

    @Test("I-CVI counts 3 and 4 as relevant; S-CVI/Ave is the mean of those")
    func cviFollowsPolitAndBeck() {
        // Item a: 4,4,3 → all three relevant → I-CVI 1.00
        // Item b: 4,2,2 → one of three → I-CVI 0.33, below 0.78
        let ratings = [
            ExpertRating(itemID: "a", expert: "ก", congruence: 1, relevance: 4),
            ExpertRating(itemID: "a", expert: "ข", congruence: 1, relevance: 4),
            ExpertRating(itemID: "a", expert: "ค", congruence: 1, relevance: 3),
            ExpertRating(itemID: "b", expert: "ก", congruence: 1, relevance: 4),
            ExpertRating(itemID: "b", expert: "ข", congruence: 1, relevance: 2),
            ExpertRating(itemID: "b", expert: "ค", congruence: 1, relevance: 2),
        ]
        let validity = ContentValidity.assess(ratings: ratings, itemIDs: ["a", "b"])
        #expect(validity.items.first { $0.itemID == "a" }?.icvi == 1)
        #expect(abs((validity.items.first { $0.itemID == "b" }?.icvi ?? 0) - 1.0 / 3.0) < 0.001)
        // S-CVI/Ave = (1.00 + 0.33) / 2 = 0.67, under 0.90 — and the item-level
        // failure already blocks it.
        #expect(abs((validity.scviAve ?? 0) - 2.0 / 3.0) < 0.001)
        #expect(!validity.passes)
        #expect(validity.summary.contains("S-CVI/Ave"))
    }

    @Test("an item nobody rated fails, and does not average as zero")
    func unratedItemsFail() {
        let ratings = [ExpertRating(itemID: "a", expert: "ก", congruence: 1, relevance: 4)]
        // "b" was never reviewed. Dropping it would report a perfect instrument
        // while a third of it had not been looked at.
        let validity = ContentValidity.assess(ratings: ratings, itemIDs: ["a", "b"])
        let b = validity.items.first { $0.itemID == "b" }
        #expect(b?.ioc == nil)
        #expect(b?.raters == 0)
        #expect(b?.passes == false)
        #expect(b?.reason?.contains("ยังไม่มีผู้เชี่ยวชาญ") == true)
        #expect(!validity.passes)
    }

    @Test("IOC alone is enough when relevance was never collected")
    func iocWithoutCVIStillPasses() {
        // The common case in practice: a panel scores congruence only. Refusing
        // it would make the gate unusable rather than strict (§20.4).
        let ratings = ["ก", "ข", "ค"].map {
            ExpertRating(itemID: "a", expert: $0, congruence: 1)
        }
        let validity = ContentValidity.assess(ratings: ratings, itemIDs: ["a"])
        #expect(validity.scviAve == nil)
        #expect(validity.passes)
    }

    @Test("ratings are clamped to their scales rather than trusted")
    func ratingsAreClamped() {
        // A UI bug or a bad import must not produce an IOC of 7.
        let wild = ExpertRating(itemID: "a", expert: "ก", congruence: 9, relevance: 99)
        #expect(wild.congruence == 1)
        #expect(wild.relevance == 4)
        let low = ExpertRating(itemID: "a", expert: "ก", congruence: -9, relevance: -3)
        #expect(low.congruence == -1)
        #expect(low.relevance == 1)
    }
}

@Suite("Reliability")
struct ReliabilityTests {

    @Test("Cronbach's α matches a hand-computed example")
    func alphaIsCorrect() throws {
        // Four respondents, three items, worked out by hand (sample variance,
        // n−1):
        //   item a: 1,2,3,3 → var 0.9167   item b: 1,2,3,4 → var 1.6667
        //   item c: 2,3,4,4 → var 0.9167   → Σ = 3.5
        //   totals 4,7,10,11 → var 10.0
        //   α = (3/2)(1 − 3.5/10) = 1.5 × 0.65 = 0.975
        let scores: [[Double]] = [
            [1, 1, 2],
            [2, 2, 3],
            [3, 3, 4],
            [3, 4, 4],
        ]
        let reliability = try #require(Reliability.cronbach(scores: scores,
                                                          itemIDs: ["a", "b", "c"]))
        #expect(abs(reliability.alpha - 0.975) < 0.001)
        #expect(reliability.passes)
        #expect(reliability.respondents == 4)
        // Item-total correlations say *which* item is weak, which is the number a
        // person acts on.
        #expect(reliability.itemTotal.count == 3)
        #expect((reliability.itemTotal["a"] ?? 0) > 0.8)
    }

    @Test("an item that measures something else drags α below the threshold")
    func inconsistentItemFailsTheScale() throws {
        // Third column runs opposite to the first two.
        let scores: [[Double]] = [
            [1, 1, 5],
            [2, 2, 4],
            [4, 4, 2],
            [5, 5, 1],
        ]
        let reliability = try #require(Reliability.cronbach(scores: scores,
                                                          itemIDs: ["a", "b", "c"]))
        #expect(!reliability.passes)
        // And it names the culprit: a strongly negative item-total correlation.
        #expect((reliability.itemTotal["c"] ?? 0) < 0)
    }

    @Test("α from too little data is nil, not a number")
    func notEnoughDataIsNil() {
        // Two respondents is arithmetic without meaning, and a gate reading it
        // would be letting noise decide.
        #expect(Reliability.cronbach(scores: [[1, 2], [2, 3]], itemIDs: ["a", "b"]) == nil)
        // One item is not a scale.
        #expect(Reliability.cronbach(scores: [[1], [2], [3]], itemIDs: ["a"]) == nil)
        // Everybody answering identically has no variance to explain.
        #expect(Reliability.cronbach(scores: [[3, 3], [3, 3], [3, 3]],
                                     itemIDs: ["a", "b"]) == nil)
        // Ragged input is a bug upstream, not a value to interpret.
        #expect(Reliability.cronbach(scores: [[1, 2], [1], [2, 3]], itemIDs: ["a", "b"]) == nil)
    }
}
