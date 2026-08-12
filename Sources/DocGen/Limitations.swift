import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// The Limitations section, written by the system (ARCHITECTURE §14.1, P7.8).
//
// The Done-when is that a draft has a correct Limitations section **without
// anyone asking for one**, and the reason that is possible is that every input
// already exists as a fact somewhere else:
//
//  • An assumption the proposal never made is `wasAgentSuggested` on a decision
//    in the Analysis Plan (§12.4). Note that it is not `origin` — by the time a
//    plan is approved every one of those has become `human_confirmed`, and the
//    point of Limitations is precisely that somebody had to choose.
//  • A passage that once had a rival is a decided `Conflict` (§11.6), which
//    keeps both sides verbatim for exactly this reason.
//  • A claim resting on thin sources is `CrossSource.assess` over its citations
//    (§14.1's tier rule).
//
// So nothing here is generated in the sense of invented. Every line is a
// restatement of something the system already recorded, which is what makes it
// safe to write into a document nobody proof-read.
// ─────────────────────────────────────────────────────────────

public struct Limitation: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// A methodological choice the proposal did not make.
        case assumption
        /// Sources disagreed and one side was chosen.
        case resolvedConflict
        /// The claim does not have the corroboration §14.1 asks for.
        case thinEvidence
        /// A statistical assumption that failed or could not be checked (§12.3).
        case statistical
    }

    public let kind: Kind
    public let subject: String
    public let text: String
    public var id: String { "\(kind.rawValue):\(subject)" }
}

public struct LimitationsSection: Sendable, Equatable {
    public let items: [Limitation]

    public var isEmpty: Bool { items.isEmpty }

    /// The section as prose, in the order §14.1 implies: what was assumed,
    /// what was disputed, what is thinly supported.
    public func rendered(heading: String = "ข้อจำกัดของการศึกษานี้") -> String {
        guard !items.isEmpty else {
            return "\(heading)\n\nไม่พบข้อจำกัดที่ระบบบันทึกไว้จากขั้นตอนที่ผ่านมา"
        }
        var lines = [heading, ""]
        for item in items { lines.append("• \(item.text)") }
        return lines.joined(separator: "\n")
    }
}

public enum LimitationsBuilder {

    /// Builds the section from what the run already recorded.
    ///
    /// Everything is optional because a draft may have no plan, no conflicts or
    /// no citations — and an empty section is a true statement about a run with
    /// nothing to declare, which is not the same as a section nobody wrote.
    public static func build(plan: AnalysisPlan? = nil,
                             conflicts: [Conflict] = [],
                             citations: [CitedText] = [],
                             statistical: [String] = []) -> LimitationsSection {
        var items: [Limitation] = []

        // §12.4 → §14.1: the assumptions, in the words the plan recorded, with
        // the reason they had to be made at all.
        for decision in plan?.decisions ?? [] where decision.wasAgentSuggested {
            let note = decision.note.map { " (\($0))" } ?? ""
            items.append(Limitation(
                kind: .assumption,
                subject: decision.question,
                text: "\(decision.question) กำหนดเป็น “\(decision.value)” "
                    + "เนื่องจากโครงร่างไม่ได้ระบุไว้\(note)"
                    + (decision.origin == .humanConfirmed ? " — ผู้วิจัยยืนยันแล้ว" : "")))
        }

        // §11.6 → §14.1: a passage that survived a disagreement is not the same
        // as a passage nobody disputed, and the reader is entitled to know
        // which one they are reading.
        for conflict in conflicts {
            guard let decision = conflict.decision else { continue }
            items.append(Limitation(
                kind: .resolvedConflict,
                subject: conflict.question,
                text: "มีแหล่งที่ขัดกันในประเด็น “\(conflict.question)” — "
                    + "เลือกใช้: \(describe(decision.resolution)) "
                    + "(ตัดสินโดย\(decision.decidedByHuman ? "ผู้วิจัย" : "ระบบ") "
                    + "เมื่อ \(dateText(decision.decidedAt)))"))
        }

        // §14.1's tier rule, stated as a limitation rather than left implicit.
        if !citations.isEmpty {
            let corroboration = CrossSource.assess(citations)
            if let note = corroboration.note {
                items.append(Limitation(
                    kind: .thinEvidence,
                    subject: "ความหนาแน่นของหลักฐาน",
                    text: "หลักฐานที่อ้างอิง: \(note)"))
            }
        }

        // §12.3 → §14.1: an assumption that failed, or one that could not be
        // checked, is a limitation of the analysis and not a detail of it.
        for warning in statistical {
            items.append(Limitation(kind: .statistical,
                                    subject: warning, text: "ข้อสมมติทางสถิติ: \(warning)"))
        }

        return LimitationsSection(items: items)
    }

    private static func describe(_ resolution: ConflictResolution) -> String {
        switch resolution {
        case .preferA(let reason): "ฝั่ง A — \(reason)"
        case .preferB(let reason): "ฝั่ง B — \(reason)"
        case .bothInContext(let condition): "ถูกทั้งคู่ในบริบทต่างกัน — \(condition)"
        // §11.6 is explicit that an unresolved question must be written as
        // open rather than quietly picking a side, so it stays in Limitations
        // as exactly that.
        case .unresolved: "ยังไม่ตัดสิน — เอกสารต้องระบุว่าประเด็นนี้ยังเปิดอยู่"
        }
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "th_TH")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter.string(from: date)
    }
}
