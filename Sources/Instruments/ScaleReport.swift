import Foundation

// ─────────────────────────────────────────────────────────────
// The answers, turned into the numbers §20.4 asks for (P11.3).
//
// α, ω, ICC and EFA all take a respondents × items matrix. Real answers are
// text — a Likert answer is stored as its ordinal, a single-choice answer as the
// option's own words — so something has to decide what becomes a number and what
// does not. That decision is here, in M15, rather than in the screen that shows
// the result, for the reason this project has learned twice: the app target is
// an executable with no unit tests, so logic that lands there is logic nothing
// can check. The screen's whole job is to hand this an item id → answer map.
//
// Three decisions are made out loud:
//
//  • **Only ordered numeric items are scored.** Assigning 1, 2, 3 to
//    "โรงพยาบาลรัฐ / เอกชน / คลินิก" would invent an order nobody chose, so
//    those items are named as left out rather than quietly dropped.
//  • **Listwise deletion**, with the count of who it removed on the result. The
//    honest form of "everything below needs a complete matrix" is to say how many
//    people were excluded, not to fill the holes with means.
//  • **Demographic items are out.** They measure who somebody is, not the
//    construct — including them is how "อายุ" ends up as a factor of its own.
// ─────────────────────────────────────────────────────────────

/// One item that could not be turned into a number, and why.
public struct SkippedItem: Sendable, Identifiable, Equatable {
    public let itemID: String
    public let prompt: String
    public let reason: String
    public var id: String { itemID }

    public init(itemID: String, prompt: String, reason: String) {
        self.itemID = itemID
        self.prompt = prompt
        self.reason = reason
    }
}

/// The scored matrix, plus everything that did not make it in.
public struct ScoredResponses: Sendable, Equatable {
    public let itemIDs: [String]
    /// One row per respondent who answered every scored item.
    public let matrix: [[Double]]
    public let skippedItems: [SkippedItem]
    /// Respondents left out because they had at least one scored item blank.
    public let droppedRespondents: Int

    /// Turns stored answers into numbers.
    ///
    /// `answers` is one dictionary per respondent, keyed by item id — the shape
    /// any store of answers can be reduced to, which is what keeps this module
    /// free of a dependency on the one that holds them.
    public static func score(instrument: Instrument,
                             answers: [[String: String]]) -> ScoredResponses {
        var scorable: [Item] = []
        var skipped: [SkippedItem] = []
        for item in instrument.ordered where !item.isDemographic {
            switch item.kind {
            case .likert, .number:
                scorable.append(item)
            case .single, .multiple, .ranking:
                skipped.append(SkippedItem(
                    itemID: item.id, prompt: item.prompt.thai,
                    reason: "ตัวเลือกไม่มีลำดับในตัวเอง — การให้เลข 1, 2, 3 แทนตัวเลือก "
                        + "คือการสร้างลำดับที่ไม่มีใครกำหนดไว้"))
            case .openText, .date, .fileUpload, .matrix:
                skipped.append(SkippedItem(
                    itemID: item.id, prompt: item.prompt.thai,
                    reason: "ชนิด “\(item.kind.label)” ไม่ใช่คะแนนที่นำมาหาความเที่ยงได้"))
            }
        }

        var matrix: [[Double]] = []
        var dropped = 0
        for row in answers {
            let scores = scorable.compactMap { item in row[item.id].flatMap(Double.init) }
            if !scorable.isEmpty, scores.count == scorable.count {
                matrix.append(scores)
            } else {
                dropped += 1
            }
        }
        return ScoredResponses(itemIDs: scorable.map(\.id), matrix: matrix,
                               skippedItems: skipped, droppedRespondents: dropped)
    }
}

/// Reliability and construct validity over one instrument's answers — everything
/// §20.4 puts after fieldwork, in one value.
///
/// Nothing here is a gate and nothing here can refuse anything. EFA runs after
/// the data was collected, so the useful thing it can do is put the number, the
/// warning and the item that caused it in the same place.
public struct ScaleReport: Sendable, Equatable {

    /// One declared construct, with the two reliability coefficients §20.4 names.
    public struct Subscale: Sendable, Identifiable, Equatable {
        public let constructID: String
        public let name: String
        public let itemIDs: [String]
        /// `nil` when the subscale is too small or too flat for α to mean
        /// anything — a different statement from a low α.
        public let alpha: Reliability?
        /// `nil` under ω's own conditions, which are stricter: three items, more
        /// respondents than items, a factorable matrix.
        public let omega: OmegaReliability?
        public var id: String { constructID }

        /// The item dragging α down, if there is one worth naming. Below .30 is
        /// the usual mark for "this item is not measuring what the others are".
        public var weakestItem: (item: String, correlation: Double)? {
            guard let alpha,
                  let worst = alpha.itemTotal.min(by: { $0.value < $1.value }),
                  worst.value < 0.30 else { return nil }
            return (worst.key, worst.value)
        }
    }

    public let respondents: Int
    public let droppedRespondents: Int
    public let scoredItemIDs: [String]
    public let skippedItems: [SkippedItem]
    public let subscales: [Subscale]
    /// `nil` when EFA could not run at all — `refusal` then says why, in words
    /// that name what to do about it.
    public let solution: FactorSolution?
    public let fit: ConstructFit?
    public let refusal: String?

    public var hasAnything: Bool { !subscales.isEmpty || solution != nil }

    public static func of(instrument: Instrument, scored: ScoredResponses,
                          rule: RetentionRule) -> ScaleReport {
        let names = Dictionary(instrument.constructs.map { ($0.id, $0.name.thai) },
                               uniquingKeysWith: { first, _ in first })
        let constructOfItem = Dictionary(
            instrument.items.compactMap { item -> (String, String)? in
                guard let construct = item.constructID,
                      scored.itemIDs.contains(item.id) else { return nil }
                return (item.id, construct)
            }, uniquingKeysWith: { first, _ in first })

        // Per construct, never over the whole instrument: α across items that
        // measure different things rises with the item count and means nothing,
        // which is why §20.4 sets its threshold per subscale.
        var subscales: [Subscale] = []
        for construct in instrument.constructs {
            let items = scored.itemIDs.filter { constructOfItem[$0] == construct.id }
            guard !items.isEmpty else { continue }
            let columns = items.compactMap { scored.itemIDs.firstIndex(of: $0) }
            let block = scored.matrix.map { row in columns.map { row[$0] } }
            subscales.append(Subscale(
                constructID: construct.id,
                name: names[construct.id] ?? construct.id,
                itemIDs: items,
                alpha: Reliability.cronbach(scores: block, itemIDs: items),
                omega: Reliability.omega(scores: block, itemIDs: items)))
        }

        var solution: FactorSolution?
        var fit: ConstructFit?
        var refusal: String?
        do {
            let found = try ExploratoryFactorAnalysis.analyse(
                scores: scored.matrix, itemIDs: scored.itemIDs, rule: rule)
            solution = found
            if !constructOfItem.isEmpty {
                fit = ConstructFit.compare(found, constructOfItem: constructOfItem)
            }
        } catch {
            refusal = "\(error)"
        }

        return ScaleReport(respondents: scored.matrix.count,
                           droppedRespondents: scored.droppedRespondents,
                           scoredItemIDs: scored.itemIDs,
                           skippedItems: scored.skippedItems,
                           subscales: subscales, solution: solution, fit: fit,
                           refusal: refusal)
    }
}
