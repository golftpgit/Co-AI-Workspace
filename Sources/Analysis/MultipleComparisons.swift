import Foundation

// ─────────────────────────────────────────────────────────────
// Testing more than one thing (Bland, ch. 22).
//
// Twenty tests at p < 0.05 on data with nothing in it produce one significant
// result on average. That is not a subtle statistical point; it is the most
// common way a paper claims something that is not there, and the analysis that
// produced it looks exactly like an analysis that found something.
//
// So this file exists to be *used*, not to be available: `StatGate` reports a
// p-value per test, and a run that produced eight of them should say what
// eight tests do to the one that came out smallest.
//
// Three methods, and the choice between them is a decision about what kind of
// mistake matters more:
//
//  • **Bonferroni** controls the chance of *any* false positive, and pays for
//    it in power. Right when one wrong claim is expensive — a safety endpoint.
//  • **Holm** controls the same thing and is never worse, so a plain
//    Bonferroni is only kept here because reviewers ask for it by name.
//  • **Benjamini–Hochberg** controls the *share* of findings that are false.
//    Right when the output is a list to follow up rather than a claim.
// ─────────────────────────────────────────────────────────────

public struct AdjustedComparison: Sendable, Equatable, Identifiable {
    public let label: String
    public let raw: Double
    public let adjusted: Double
    public var id: String { label }

    /// Whether it survives at the level asked for.
    public func survives(at alpha: Double) -> Bool { adjusted <= alpha }
}

public struct MultiplicityReport: Sendable, Equatable {
    public enum Method: String, Sendable, CaseIterable {
        case bonferroni, holm, benjaminiHochberg

        public var label: String {
            switch self {
            case .bonferroni: "Bonferroni"
            case .holm: "Holm"
            case .benjaminiHochberg: "Benjamini–Hochberg (FDR)"
            }
        }

        public var controls: String {
            switch self {
            case .bonferroni, .holm: "โอกาสที่จะมีผลบวกปลอม**สักข้อ**ในชุดนี้"
            case .benjaminiHochberg: "**สัดส่วน**ของข้อที่พบว่าเป็นผลบวกปลอม"
            }
        }
    }

    public let method: Method
    public let comparisons: [AdjustedComparison]
    public let alpha: Double

    public var survivors: [AdjustedComparison] { comparisons.filter { $0.survives(at: alpha) } }

    /// The sentence a report needs. It names how many tests were run, because
    /// that is the number the reader cannot recover from a list of p-values —
    /// and it is the number that decides what they mean.
    public var summary: String {
        let lostCount = comparisons.count { $0.raw <= alpha } - survivors.count
        var text = "ทดสอบ \(comparisons.count) ข้อ ปรับด้วย \(method.label) "
            + "ซึ่งคุม\(method.controls) · เหลือที่ยังมีนัยสำคัญ \(survivors.count) ข้อ"
        if lostCount > 0 {
            text += " · **\(lostCount) ข้อที่ p ดิบต่ำกว่า \(alpha) ไม่รอดหลังปรับ** — "
                + "การทดสอบ \(comparisons.count) ครั้งบนข้อมูลที่ไม่มีอะไรเลย ให้ผลแบบนั้นได้เอง"
        }
        return text
    }
}

public enum MultipleComparisons {

    /// Adjusts a set of p-values.
    ///
    /// The labels travel with the numbers because an adjusted p-value that has
    /// been separated from what it was testing is a number nobody can put back.
    public static func adjust(_ tests: [(label: String, p: Double)],
                              method: MultiplicityReport.Method = .holm,
                              alpha: Double = 0.05) throws -> MultiplicityReport {
        guard !tests.isEmpty else {
            throw StatError.notEnoughData("ไม่มีการทดสอบให้ปรับ")
        }
        guard tests.allSatisfy({ $0.p >= 0 && $0.p <= 1 }) else {
            throw StatError.badShape("ค่า p ต้องอยู่ระหว่าง 0 ถึง 1")
        }
        let n = Double(tests.count)
        var adjusted: [AdjustedComparison]

        switch method {
        case .bonferroni:
            adjusted = tests.map {
                AdjustedComparison(label: $0.label, raw: $0.p, adjusted: min(1, $0.p * n))
            }

        case .holm:
            // Smallest first, each multiplied by how many are left, and the
            // running maximum so the adjusted values never decrease — without
            // that, a later test could come out "more significant" than an
            // earlier smaller one, which is not a thing.
            let ordered = tests.enumerated().sorted { $0.element.p < $1.element.p }
            var running = 0.0
            var byIndex = [Int: Double]()
            for (rank, item) in ordered.enumerated() {
                let value = min(1, item.element.p * (n - Double(rank)))
                running = max(running, value)
                byIndex[item.offset] = running
            }
            adjusted = tests.enumerated().map {
                AdjustedComparison(label: $0.element.label, raw: $0.element.p,
                                   adjusted: byIndex[$0.offset] ?? $0.element.p)
            }

        case .benjaminiHochberg:
            // Largest first, each scaled by n/rank, with a running minimum for
            // the same monotonicity reason.
            let ordered = tests.enumerated().sorted { $0.element.p > $1.element.p }
            var running = 1.0
            var byIndex = [Int: Double]()
            for (position, item) in ordered.enumerated() {
                let rank = n - Double(position)
                let value = min(1, item.element.p * n / rank)
                running = min(running, value)
                byIndex[item.offset] = running
            }
            adjusted = tests.enumerated().map {
                AdjustedComparison(label: $0.element.label, raw: $0.element.p,
                                   adjusted: byIndex[$0.offset] ?? $0.element.p)
            }
        }

        return MultiplicityReport(method: method, comparisons: adjusted, alpha: alpha)
    }
}
