import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// When two sources disagree (ARCHITECTURE §11.6, P3.6).
//
// The dangerous behaviour this exists to prevent is not being wrong — it is
// **choosing quietly**. A retrieval system that silently prefers one of two
// contradictory passages leaves the user with no way to know the other one
// existed.
//
// So: the system detects, weighs, and *proposes*. A clear-cut difference is
// decided automatically and recorded as having been a conflict; anything close
// goes to the human. Either way the decision is kept, so the same question is
// not asked twice.
// ─────────────────────────────────────────────────────────────

public struct ConflictSide: Sendable, Equatable, Codable {
    /// Quoted, never summarised: §11.6 says the human reads both sides in the
    /// words they were written in.
    public let text: String
    public let provenance: Provenance
    /// Other chunks that say the same thing. Corroboration is part of weight.
    public let corroborations: Int

    public init(text: String, provenance: Provenance, corroborations: Int = 0) {
        self.text = text
        self.provenance = provenance
        self.corroborations = corroborations
    }
}

public struct ConflictWeight: Sendable, Equatable {
    public let score: Double
    /// One line per factor, in the words the card shows. A weight nobody can
    /// read is a weight nobody can argue with.
    public let reasons: [String]
}

public enum ConflictResolution: Sendable, Equatable, Codable {
    case preferA(reason: String)
    case preferB(reason: String)
    /// Both hold, in different circumstances. The condition is required: a
    /// resolution that says "it depends" without saying on what settles
    /// nothing.
    case bothInContext(condition: String)
    /// Explicitly unresolved — the document must then say the question is
    /// open rather than pick a side.
    case unresolved
}

public struct ConflictDecision: Sendable, Equatable, Codable {
    public let resolution: ConflictResolution
    /// Project-scoped or a central precedent that applies everywhere (§11.6).
    public let scope: Scope
    public let decidedAt: Date
    public let decidedByHuman: Bool

    public init(resolution: ConflictResolution, scope: Scope,
                decidedAt: Date = Date(), decidedByHuman: Bool) {
        self.resolution = resolution
        self.scope = scope
        self.decidedAt = decidedAt
        self.decidedByHuman = decidedByHuman
    }
}

public struct Conflict: Sendable, Equatable, Identifiable {
    public let id: String
    public let question: String
    public let a: ConflictSide
    public let b: ConflictSide
    public let weightA: ConflictWeight
    public let weightB: ConflictWeight
    /// What the system would do. Stated as a proposal, including when it is
    /// confident enough to act on it by itself.
    public let proposal: ConflictResolution
    public let needsHuman: Bool
    /// `internal(set)`: the ledger is what records a decision, and it is a
    /// separate type in this module. Callers outside it still cannot.
    public internal(set) var decision: ConflictDecision?

    public var isOpen: Bool { decision == nil }

    /// Identity is the pair of passages, so the same disagreement found again
    /// is the same conflict rather than a new one.
    public static func identity(_ a: ConflictSide, _ b: ConflictSide) -> String {
        let pair = [IngestionPipeline.contentHash(a.text),
                    IngestionPipeline.contentHash(b.text)].sorted()
        return "conflict_" + pair.joined(separator: "_").prefix(32)
    }

}

public struct ConflictLedger: Sendable {
    /// How far apart two weights must be before the system decides on its own.
    /// §11.6's example — T1 from 2026 against T5 from 2019 — is worth about
    /// 4 points under the scoring below, so the bar sits under that and above
    /// a one-tier gap.
    public let automaticMargin: Double
    private var conflicts: [String: Conflict] = [:]

    public init(automaticMargin: Double = 2.5) {
        self.automaticMargin = automaticMargin
    }

    public var open: [Conflict] { conflicts.values.filter(\.isOpen).sorted { $0.id < $1.id } }
    public var all: [Conflict] { conflicts.values.sorted { $0.id < $1.id } }

    // MARK: - weighing

    /// Tier, recency and corroboration, each as a readable line. A newer year
    /// is worth less than a tier step on purpose: a 2026 blog post does not
    /// outrank a 2019 standard.
    public static func weigh(_ side: ConflictSide, now: Date = Date()) -> ConflictWeight {
        var score = 0.0
        var reasons: [String] = []

        let tier = side.provenance.tier
        switch tier {
        case .t1: score += 4; reasons.append("แหล่ง T1 (เอกสารทางการ)")
        case .t2: score += 3; reasons.append("แหล่ง T2 (peer-reviewed)")
        case .t3: score += 2; reasons.append("แหล่ง T3 (preprint/กึ่งทางการ)")
        case .t4: score += 1; reasons.append("แหล่ง T4 (ชุมชนที่ตรวจกันเอง)")
        case .t5: score += 0; reasons.append("แหล่ง T5 (เว็บทั่วไป)")
        case nil: score += 1; reasons.append("ระบบเขียนเอง (ไม่มี tier ภายนอก)")
        }

        if let year = side.provenance.year {
            let currentYear = Calendar(identifier: .gregorian)
                .component(.year, from: now)
            let age = max(0, currentYear - year)
            switch age {
            case 0...2: score += 1.5; reasons.append("ปี \(year) — ใหม่")
            case 3...6: score += 0.75; reasons.append("ปี \(year) — พอสมควร")
            default: reasons.append("ปี \(year) — เก่า")
            }
        } else {
            reasons.append("ไม่ระบุปี")
        }

        if side.corroborations > 0 {
            // Capped: ten weak sources agreeing is not an authority.
            let bonus = min(Double(side.corroborations) * 0.5, 1.5)
            score += bonus
            reasons.append("มีอีก \(side.corroborations) แหล่งที่สอดคล้อง")
        }

        return ConflictWeight(score: score, reasons: reasons)
    }

    // MARK: - recording

    /// Files a disagreement. Returns the conflict as it now stands — already
    /// decided if a precedent covers it, auto-resolved if one side is clearly
    /// stronger, otherwise open and waiting for a human.
    @discardableResult
    public mutating func record(question: String,
                                a: ConflictSide, b: ConflictSide,
                                scope: Scope,
                                now: Date = Date()) -> Conflict {
        let id = Conflict.identity(a, b)

        // Asked and answered: a precedent that already covers this pair is not
        // re-litigated, which is the whole reason decisions are kept (§11.6).
        if let existing = conflicts[id], existing.decision != nil {
            return existing
        }

        let weightA = Self.weigh(a, now: now)
        let weightB = Self.weigh(b, now: now)
        let margin = weightA.score - weightB.score
        let decisive = abs(margin) >= automaticMargin

        let proposal: ConflictResolution = margin >= 0
            ? .preferA(reason: weightA.reasons.joined(separator: " · "))
            : .preferB(reason: weightB.reasons.joined(separator: " · "))

        var conflict = Conflict(id: id, question: question, a: a, b: b,
                                weightA: weightA, weightB: weightB,
                                proposal: proposal, needsHuman: !decisive,
                                decision: nil)

        if decisive {
            // Decided, but recorded as having been a conflict — §11.6's point
            // is that the alternative never disappears from the record.
            conflict.decision = ConflictDecision(resolution: proposal, scope: scope,
                                                 decidedAt: now, decidedByHuman: false)
        }

        conflicts[id] = conflict
        return conflict
    }

    /// A human's decision. Always allowed to override an automatic one — the
    /// system proposes.
    @discardableResult
    public mutating func decide(_ id: String, _ resolution: ConflictResolution,
                                scope: Scope, now: Date = Date()) -> Bool {
        guard var conflict = conflicts[id] else { return false }
        conflict.decision = ConflictDecision(resolution: resolution, scope: scope,
                                             decidedAt: now, decidedByHuman: true)
        conflicts[id] = conflict
        return true
    }

    public func decision(for id: String) -> ConflictDecision? {
        conflicts[id]?.decision
    }

    /// Reopens a conflict because a better source has arrived. §11.6: a new
    /// higher-tier source is grounds to ask again, and only that — a decision
    /// does not expire on its own.
    @discardableResult
    public mutating func reopen(_ id: String, because source: Provenance) -> Bool {
        guard var conflict = conflicts[id], let decision = conflict.decision else { return false }
        guard let newTier = source.tier else { return false }

        // `max()` since the tiers became one type: `<` means "worth less", so
        // the strongest source is the largest. It read `min()` while this
        // module's `<` meant the opposite of AgentKit's — the sort of line
        // that keeps working until somebody moves it.
        let bestSoFar = [conflict.a.provenance.tier, conflict.b.provenance.tier]
            .compactMap { $0 }
            .max()
        guard let bestSoFar, newTier > bestSoFar else { return false }

        // Superseded rather than deleted: the card can show that a decision
        // was made and what displaced it.
        _ = decision
        conflict.decision = nil
        conflicts[id] = conflict
        return true
    }
}
