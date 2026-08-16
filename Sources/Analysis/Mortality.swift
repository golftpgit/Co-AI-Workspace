import Foundation
import StatKit

// ─────────────────────────────────────────────────────────────
// Mortality statistics (Bland, ch. 21).
//
// Direct standardisation — a rate reweighted onto a standard population —
// already exists as `Epidemiology.ageStandardisedRate`. The two things it
// cannot answer are here.
//
//  • **The SMR** is indirect standardisation: instead of asking what this
//    group's rate would be in a standard population, it asks how many deaths
//    the *reference* rates predict for this group, and compares. That is the
//    right question when the group is small, because a direct rate computed
//    from four deaths in an age band is a number built on four deaths.
//  • **A life table** turns age-specific rates into survival, which is how
//    "the mortality rate at 70 is 3%" becomes "of 100 people alive at 60, this
//    many reach 80" — the form anybody outside the field can act on.
//
// The interval on an SMR is exact (Poisson), not normal. With 6 observed
// deaths the normal approximation gives a lower limit below zero, and a
// negative number of deaths is not a limit.
// ─────────────────────────────────────────────────────────────

public struct StandardisedMortalityRatio: Sendable, Equatable {
    public let observed: Int
    public let expected: Double
    public let ratio: Double
    public let lower: Double
    public let upper: Double

    /// Percent, as mortality statistics are usually quoted.
    public var indexed: Double { ratio * 100 }

    public var summary: String {
        let direction = lower > 1 ? "สูงกว่าประชากรอ้างอิงอย่างมีนัยสำคัญ"
            : upper < 1 ? "ต่ำกว่าประชากรอ้างอิงอย่างมีนัยสำคัญ"
            : "ยังแยกจากประชากรอ้างอิงไม่ได้"
        return String(format: "SMR = %.2f (95%% CI %.2f–%.2f) · ตายจริง %d ราย "
                      + "เทียบกับ %.1f รายที่อัตราของประชากรอ้างอิงทำนายไว้ — %@",
                      ratio, lower, upper, observed, expected, direction)
            + " · **ช่วงคำนวณแบบ exact (Poisson)** เพราะการประมาณแบบปกติที่จำนวนตายน้อย "
            + "ให้ขอบล่างต่ำกว่าศูนย์ ซึ่งไม่ใช่จำนวนคนตาย"
    }
}

public struct LifeTable: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        /// Where the age band starts, and how many years wide it is.
        public let age: Double
        public let width: Double
        /// Deaths per person-year in this band.
        public let rate: Double
        /// Probability of dying within the band, given you reached it.
        public let probabilityOfDying: Double
        /// How many of the starting cohort are alive at the start of the band.
        public let survivors: Double
        /// Expected years of life remaining at this age.
        public let lifeExpectancy: Double

        public var id: Double { age }
    }

    public let rows: [Row]
    public let radix: Double

    /// Life expectancy at the youngest age in the table — what "life
    /// expectancy" means when quoted with no age attached.
    public var lifeExpectancyAtStart: Double { rows.first?.lifeExpectancy ?? 0 }
}

public enum Mortality {

    /// Indirect standardisation.
    ///
    /// - Parameter strata: for each age band, the deaths seen in this group,
    ///   its person-time, and the reference population's rate for that band.
    public static func smr(_ strata: [(observed: Int, personTime: Double,
                                       referenceRate: Double)]) throws
        -> StandardisedMortalityRatio {
        guard !strata.isEmpty else { throw StatError.notEnoughData("ไม่มีชั้นอายุ") }
        guard strata.allSatisfy({ $0.personTime >= 0 && $0.referenceRate >= 0 && $0.observed >= 0 })
        else {
            throw StatError.badShape("person-time, อัตราอ้างอิง และจำนวนตาย ติดลบไม่ได้")
        }
        let observed = strata.reduce(0) { $0 + $1.observed }
        let expected = strata.reduce(0.0) { $0 + $1.personTime * $1.referenceRate }
        guard expected > 0 else {
            throw StatError.notEnoughData(
                "อัตราของประชากรอ้างอิงทำนายว่าจะไม่มีใครตายเลย — หารด้วยศูนย์ไม่ได้")
        }

        // Exact Poisson limits for the observed count, then scaled by the
        // expectation. Byar's approximation would be close and this is not a
        // hot path.
        let (low, high) = Distributions.poissonInterval(observed: observed)
        return StandardisedMortalityRatio(observed: observed, expected: expected,
                                          ratio: Double(observed) / expected,
                                          lower: low / expected, upper: high / expected)
    }

    /// A life table from age-specific mortality rates.
    ///
    /// - Parameters:
    ///   - bands: the start of each age band, its width in years, and the
    ///     deaths per person-year in it. Must be in order and must not overlap.
    ///   - radix: the notional cohort, conventionally 100,000.
    public static func lifeTable(_ bands: [(age: Double, width: Double, rate: Double)],
                                 radix: Double = 100_000) throws -> LifeTable {
        guard bands.count >= 2 else {
            throw StatError.notEnoughData("ตารางชีพต้องมีอย่างน้อยสองช่วงอายุ")
        }
        guard bands.allSatisfy({ $0.width > 0 && $0.rate >= 0 }) else {
            throw StatError.badShape("ช่วงอายุต้องกว้างกว่าศูนย์ และอัตราตายติดลบไม่ได้")
        }
        guard zip(bands, bands.dropFirst()).allSatisfy({ $0.age < $1.age }) else {
            throw StatError.badShape("ช่วงอายุต้องเรียงจากน้อยไปมาก")
        }

        // Deaths are assumed to fall in the middle of a band, which is the
        // standard actuarial assumption and is stated because it is an
        // assumption: it is wrong for infancy, where deaths cluster at the
        // very start.
        var survivors = radix
        var rows: [LifeTable.Row] = []
        var personYears: [Double] = []

        for band in bands {
            let q = (band.width * band.rate) / (1 + 0.5 * band.width * band.rate)
            let dying = survivors * min(1, q)
            let years = band.width * (survivors - 0.5 * dying)
            personYears.append(years)
            rows.append(LifeTable.Row(age: band.age, width: band.width, rate: band.rate,
                                      probabilityOfDying: min(1, q), survivors: survivors,
                                      lifeExpectancy: 0))
            survivors -= dying
        }

        // Life expectancy is the person-years lived from each age onwards,
        // divided by the survivors at that age — filled in backwards.
        var remaining = 0.0
        var withExpectancy: [LifeTable.Row] = []
        for index in rows.indices.reversed() {
            remaining += personYears[index]
            let row = rows[index]
            withExpectancy.append(LifeTable.Row(
                age: row.age, width: row.width, rate: row.rate,
                probabilityOfDying: row.probabilityOfDying, survivors: row.survivors,
                lifeExpectancy: row.survivors > 0 ? remaining / row.survivors : 0))
        }
        return LifeTable(rows: withExpectancy.reversed(), radix: radix)
    }
}
