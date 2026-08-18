import Foundation

// ─────────────────────────────────────────────────────────────
// Content validity, as arithmetic (ARCHITECTURE §20.4, P11.3).
//
// IOC and CVI are the two checks a Thai thesis committee will ask for by name,
// and both are averages of expert ratings — which is why §20.4 puts them in
// Swift rather than in Python: the app is sandboxed and its Python has no numpy
// (§18), so a validity suite that lived there would work on this machine and fail
// on the examiner's.
//
// The thresholds are the published ones and they are *not* configurable here:
// IOC ≥ 0.5 (Rovinelli & Hambleton), I-CVI ≥ 0.78 and S-CVI/Ave ≥ 0.90 (Polit &
// Beck, for 3–5 experts). A threshold somebody can lower in the UI is a threshold
// that gets lowered the evening before a deadline.
// ─────────────────────────────────────────────────────────────

/// One expert's judgement of one item.
public struct ExpertRating: Sendable, Codable, Equatable {
    public let itemID: String
    /// Who rated it. Kept because IOC is reported per expert panel and a rating
    /// with no rater cannot be defended.
    public let expert: String
    /// IOC convention: +1 congruent, 0 unsure, −1 not congruent.
    public let congruence: Int
    /// CVI convention: relevance on 1–4, where 3 and 4 count as relevant.
    public let relevance: Int?

    public init(itemID: String, expert: String, congruence: Int, relevance: Int? = nil) {
        self.itemID = itemID
        self.expert = expert
        self.congruence = max(-1, min(1, congruence))
        self.relevance = relevance.map { max(1, min(4, $0)) }
    }
}

/// One item's verdict.
public struct ItemValidity: Sendable, Equatable, Identifiable {
    public let itemID: String
    /// Mean congruence across experts. `nil` when nobody rated it — which is a
    /// different state from a low score and must not average as zero.
    public let ioc: Double?
    /// Proportion of experts calling it relevant (3–4 on the 1–4 scale).
    public let icvi: Double?
    public let raters: Int

    public var id: String { itemID }

    public var passes: Bool {
        guard let ioc, ioc >= 0.5 else { return false }
        // I-CVI only applies if relevance was collected at all: a panel that
        // scored congruence and not relevance has done half the standard method,
        // and demanding the other half retroactively would fail a valid item.
        if let icvi, icvi < 0.78 { return false }
        return true
    }

    public var reason: String? {
        guard !passes else { return nil }
        guard let ioc else { return localised("no expert has rated this item yet", "Why an item has no validity figure.") }
        if ioc < 0.5 {
            return String(format: localised("IOC %.2f is below 0.50", "An item failed the IOC threshold. Placeholder: the IOC."), ioc)
        }
        if let icvi, icvi < 0.78 {
            return String(format: localised("I-CVI %.2f is below 0.78", "An item failed the I-CVI threshold. Placeholder: the I-CVI."), icvi)
        }
        return nil
    }
}

public struct ContentValidity: Sendable, Equatable {
    public let items: [ItemValidity]
    /// S-CVI/Ave — the mean of the item-level CVIs, which is the number a
    /// methods section reports for the instrument as a whole.
    public let scviAve: Double?
    public let experts: [String]

    public var failing: [ItemValidity] { items.filter { !$0.passes } }

    /// The smallest panel these thresholds mean anything for.
    ///
    /// Both published rules assume a panel: Rovinelli & Hambleton's IOC and Polit
    /// & Beck's I-CVI ≥ 0.78 are stated for 3–5 experts. With one rater I-CVI can
    /// only ever be 0 or 1 and IOC is that person's opinion — arithmetic that
    /// looks like a validity study and is not one. Cheaper to refuse here than in
    /// a defence (risk R12).
    public static let minimumPanel = 3

    /// Whether the panel is large enough for the thresholds to apply.
    public var hasPanel: Bool { experts.count >= Self.minimumPanel }

    /// Every item passes, the panel is big enough, and the scale as a whole clears
    /// S-CVI/Ave ≥ 0.90.
    ///
    /// `scviAve == nil` (relevance never collected) does not block: IOC alone is
    /// the accepted minimum in a great many Thai theses, and refusing it would
    /// make the gate unusable rather than strict.
    public var passes: Bool {
        guard !items.isEmpty, failing.isEmpty, hasPanel else { return false }
        if let scviAve, scviAve < 0.90 { return false }
        return true
    }

    public var summary: String {
        guard !items.isEmpty else { return localised("no assessment yet", "Shown before any expert review exists.") }
        var parts = [localised("\(experts.count) experts", "How many experts reviewed. Placeholder: the count."), localised("\(items.count - failing.count)/\(items.count) items passed", "How many items passed. Placeholders: passing count and total.")]
        if let scviAve { parts.append(String(format: "S-CVI/Ave %.2f", scviAve)) }
        if !hasPanel {
            parts.append(localised("at least \(Self.minimumPanel) experts are needed — ", "Why a content-validity result is not usable. Placeholder: the minimum panel size.")
                         + localised("the IOC and CVI thresholds are set for a panel of 3 to 5", "Ends the reason a content-validity result is not usable."))
        }
        if let worst = failing.first, let reason = worst.reason {
            parts.append(localised("items not yet passing: \(reason)", "Lists the failing items. Placeholder: the reasons."))
        }
        return parts.joined(separator: " · ")
    }

    /// Computes the whole panel's verdict.
    ///
    /// Items with no ratings are included and fail, rather than being dropped:
    /// an instrument where three items were never reviewed has not been reviewed,
    /// and silently averaging the ones that were is how that gets missed.
    public static func assess(ratings: [ExpertRating], itemIDs: [String]) -> ContentValidity {
        let byItem = Dictionary(grouping: ratings, by: \.itemID)
        var results: [ItemValidity] = []
        var cvis: [Double] = []

        for itemID in itemIDs {
            let rows = byItem[itemID] ?? []
            guard !rows.isEmpty else {
                results.append(ItemValidity(itemID: itemID, ioc: nil, icvi: nil, raters: 0))
                continue
            }
            let ioc = Double(rows.map(\.congruence).reduce(0, +)) / Double(rows.count)
            let relevances = rows.compactMap(\.relevance)
            var icvi: Double?
            if !relevances.isEmpty {
                let relevant = relevances.count { $0 >= 3 }
                let value = Double(relevant) / Double(relevances.count)
                icvi = value
                cvis.append(value)
            }
            results.append(ItemValidity(itemID: itemID, ioc: ioc, icvi: icvi,
                                        raters: rows.count))
        }

        let experts = Array(Set(ratings.map(\.expert))).sorted()
        let scvi = cvis.isEmpty ? nil : cvis.reduce(0, +) / Double(cvis.count)
        return ContentValidity(items: results, scviAve: scvi, experts: experts)
    }
}

// ─────────────────────────────────────────────────────────────
// Reliability (§20.4). Cronbach's α and item-total correlation only: ω and CFA
// need factor loadings, EFA needs LAPACK, and half a factor analysis is worse
// than an honest gap (§20.4 says so about CFA in as many words).
// ─────────────────────────────────────────────────────────────

public struct Reliability: Sendable, Equatable {
    /// Cronbach's α for the subscale.
    public let alpha: Double
    /// Correlation of each item with the total of the others — the number that
    /// says *which* item is dragging α down.
    public let itemTotal: [String: Double]
    public let respondents: Int

    /// §20.4's threshold, per subscale.
    public var passes: Bool { alpha >= 0.70 }

    /// α for one subscale from a respondents × items matrix.
    ///
    /// `nil` rather than a number when there is not enough data: α from two
    /// respondents is arithmetic without meaning, and a gate reading it would be
    /// letting noise decide.
    public static func cronbach(scores: [[Double]], itemIDs: [String]) -> Reliability? {
        guard let width = scores.first?.count, width >= 2,
              scores.count >= 3,
              scores.allSatisfy({ $0.count == width }) else { return nil }

        let itemVariances = (0..<width).map { column in
            variance(scores.map { $0[column] })
        }
        let totals = scores.map { $0.reduce(0, +) }
        let totalVariance = variance(totals)
        guard totalVariance > 0 else { return nil }

        let k = Double(width)
        let alpha = (k / (k - 1)) * (1 - itemVariances.reduce(0, +) / totalVariance)

        var itemTotal: [String: Double] = [:]
        for column in 0..<width where column < itemIDs.count {
            let item = scores.map { $0[column] }
            // Against the total of the *other* items: correlating an item with a
            // total that includes it inflates every figure.
            let rest = scores.map { row in
                row.enumerated().filter { $0.offset != column }.map(\.element).reduce(0, +)
            }
            itemTotal[itemIDs[column]] = correlation(item, rest)
        }
        return Reliability(alpha: alpha, itemTotal: itemTotal, respondents: scores.count)
    }

    private static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        var top = 0.0, leftSum = 0.0, rightSum = 0.0
        for index in a.indices {
            let left = a[index] - meanA
            let right = b[index] - meanB
            top += left * right
            leftSum += left * left
            rightSum += right * right
        }
        let bottom = (leftSum * rightSum).squareRoot()
        return bottom == 0 ? 0 : top / bottom
    }
}
