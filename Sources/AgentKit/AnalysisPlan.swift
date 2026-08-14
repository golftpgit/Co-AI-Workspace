import Foundation

// ─────────────────────────────────────────────────────────────
// The Analysis Plan and the gaps that stand between a proposal and one
// (ARCHITECTURE §12.4, P6.7).
//
// §12.4 models this on pre-registration: the method is agreed *before* the
// numbers are seen, so that a result nobody liked cannot quietly become a
// different analysis. Two things follow, and both are enforced by this type
// rather than asked of whoever writes the UI:
//
//  • **An approved plan has no `agent_suggested` left in it.** The tag exists
//    to audit which decisions were the agent's idea; if one survives approval,
//    the audit says a human agreed to something they were never asked about.
//    `approve(by:)` throws instead.
//  • **An approved plan cannot be edited and stay approved.** Any change after
//    the fact drops the approval and records why. Without that, "approved" is
//    a flag rather than a statement about what was agreed — which is exactly
//    the p-hacking the pre-registration idea exists to prevent.
//
// Types only, no logic that talks to anything: the model that reads a proposal
// lives in CoreEngine, the storage in Persistence, and both work on these.
// ─────────────────────────────────────────────────────────────

/// Where a decision in the plan came from. §12.4's audit tag.
public enum DecisionOrigin: String, Sendable, Codable, CaseIterable {
    /// The proposal says so, in words that are in the proposal.
    case proposalStated = "proposal_stated"
    /// A person chose it — either agreeing with a suggestion or writing their own.
    case humanConfirmed = "human_confirmed"
    /// The agent filled it in. Never survives approval.
    case agentSuggested = "agent_suggested"

    public var label: String {
        switch self {
        case .proposalStated: "โครงร่างระบุไว้"
        case .humanConfirmed: "คนยืนยันแล้ว"
        case .agentSuggested: "agent เสนอ"
        }
    }
}

/// §12.4's three levels.
public enum GapSeverity: String, Sendable, Codable, CaseIterable {
    /// Missing and the analysis cannot proceed — a hard block.
    case critical
    /// Could mean more than one thing in the data that exists.
    case ambiguous
    /// A choice of method the proposal does not make.
    case assumptionNeeded = "assumption_needed"

    public var label: String {
        switch self {
        case .critical: "วิกฤต — ไม่มีแล้ววิเคราะห์ไม่ได้"
        case .ambiguous: "กำกวม — ตีความได้หลายแบบ"
        case .assumptionNeeded: "ต้องเลือกวิธี"
        }
    }

    /// Whether leaving this open stops approval.
    ///
    /// `assumptionNeeded` does not, on its own — it produces an
    /// `agent_suggested` decision instead, and *that* is what blocks until a
    /// person confirms it. One rule, enforced in one place.
    public var blocksApproval: Bool {
        switch self {
        case .critical, .ambiguous: true
        case .assumptionNeeded: false
        }
    }
}

public struct AnalysisGap: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let severity: GapSeverity
    /// The field or the decision that is missing.
    public let subject: String
    public let detail: String
    /// What the user can pick from, when there is a choice to make.
    public let options: [String]
    public internal(set) var resolution: String?

    public var isOpen: Bool { resolution == nil }

    public init(id: String = OpaqueID.make("gap"),
                severity: GapSeverity,
                subject: String,
                detail: String,
                options: [String] = [],
                resolution: String? = nil) {
        self.id = id
        self.severity = severity
        self.subject = subject
        self.detail = detail
        self.options = options
        self.resolution = resolution
    }
}

public struct AnalysisDecision: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    /// What was decided — "ประชากรที่ศึกษา", "วิธีทางสถิติ".
    public let question: String
    public internal(set) var value: String
    public internal(set) var origin: DecisionOrigin
    /// Why, where that is not obvious from the value.
    public internal(set) var note: String?
    /// True when this started as the agent's idea, whatever it is now.
    ///
    /// `origin` moves to `human_confirmed` the moment a person agrees, which is
    /// exactly what approval requires — but §14.1 needs the other fact: an
    /// assumption the proposal never made belongs in Limitations even after
    /// somebody signed off on it. Set once, never cleared.
    public let wasAgentSuggested: Bool

    public init(id: String = OpaqueID.make("dec"),
                question: String,
                value: String,
                origin: DecisionOrigin,
                note: String? = nil) {
        self.id = id
        self.question = question
        self.value = value
        self.origin = origin
        self.note = note
        self.wasAgentSuggested = origin == .agentSuggested
    }
}

public enum PlanApprovalError: Error, CustomStringConvertible, Equatable {
    case notReady([String])

    public var description: String {
        switch self {
        case .notReady(let reasons):
            "ยังอนุมัติแผนไม่ได้:\n" + reasons.map { "• \($0)" }.joined(separator: "\n")
        }
    }
}

public struct AnalysisPlan: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var scope: Scope
    /// The proposal this was read from, when there is one (§12.4 triggers on
    /// `doc_type: proposal` in the knowledge base).
    public var proposalDocumentID: String?

    public private(set) var decisions: [AnalysisDecision]
    public private(set) var gaps: [AnalysisGap]
    public private(set) var approvedAt: Date?
    public private(set) var approvedBy: String?
    /// Every time approval was lost, and why. Kept rather than overwritten: a
    /// pre-registration whose history is editable is not a pre-registration.
    public private(set) var revisions: [String]
    public var createdAt: Date

    public init(id: String = OpaqueID.make("plan"),
                title: String,
                scope: Scope = .central,
                proposalDocumentID: String? = nil,
                decisions: [AnalysisDecision] = [],
                gaps: [AnalysisGap] = [],
                createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.scope = scope
        self.proposalDocumentID = proposalDocumentID
        self.decisions = decisions
        self.gaps = gaps
        self.approvedAt = nil
        self.approvedBy = nil
        self.revisions = []
        self.createdAt = createdAt
    }

    // MARK: - reading

    public var isApproved: Bool { approvedAt != nil }

    /// The decisions still standing as the agent's idea. This list must be
    /// empty for `approve(by:)` to succeed — P6.7's Done-when.
    public var agentSuggestions: [AnalysisDecision] {
        decisions.filter { $0.origin == .agentSuggested }
    }

    public var openGaps: [AnalysisGap] { gaps.filter(\.isOpen) }

    public var blockingGaps: [AnalysisGap] {
        gaps.filter { $0.isOpen && $0.severity.blocksApproval }
    }

    /// Why this cannot be approved yet, in the words the screen shows. Empty
    /// means ready.
    public var blockers: [String] {
        var reasons: [String] = []
        if decisions.isEmpty { reasons.append("แผนยังไม่มีการตัดสินใจใดๆ") }
        for gap in blockingGaps {
            reasons.append("\(gap.severity.label): \(gap.subject)")
        }
        for decision in agentSuggestions {
            reasons.append("ยังเป็นข้อเสนอของ agent ที่ยังไม่มีคนยืนยัน: \(decision.question)")
        }
        return reasons
    }

    public var isReadyForApproval: Bool { blockers.isEmpty }

    // MARK: - editing

    /// A person accepts a decision — with an edit, or as it stands. This is the
    /// only route from `agent_suggested` to anything else, and it is what makes
    /// the audit tag mean something.
    @discardableResult
    public mutating func confirm(_ decisionID: String, value: String? = nil,
                                 note: String? = nil) -> Bool {
        guard let index = decisions.firstIndex(where: { $0.id == decisionID }) else { return false }
        loseApprovalIfHeld("แก้การตัดสินใจ “\(decisions[index].question)” หลังอนุมัติ")
        if let value { decisions[index].value = value }
        if let note { decisions[index].note = note }
        decisions[index].origin = .humanConfirmed
        return true
    }

    /// Answers a gap. An answer is a decision, so it becomes one — tagged
    /// `human_confirmed`, because a person is the one who answered.
    @discardableResult
    public mutating func resolve(gap gapID: String, with answer: String) -> Bool {
        guard let index = gaps.firstIndex(where: { $0.id == gapID }) else { return false }
        loseApprovalIfHeld("ตอบช่องว่าง “\(gaps[index].subject)” หลังอนุมัติ")
        gaps[index].resolution = answer
        let gap = gaps[index]
        if let existing = decisions.firstIndex(where: { $0.question == gap.subject }) {
            decisions[existing].value = answer
            decisions[existing].origin = .humanConfirmed
        } else {
            decisions.append(AnalysisDecision(question: gap.subject, value: answer,
                                              origin: .humanConfirmed,
                                              note: gap.detail))
        }
        return true
    }

    public mutating func add(_ decision: AnalysisDecision) {
        loseApprovalIfHeld("เพิ่มการตัดสินใจ “\(decision.question)” หลังอนุมัติ")
        decisions.append(decision)
    }

    public mutating func add(_ gap: AnalysisGap) {
        loseApprovalIfHeld("พบช่องว่างใหม่ “\(gap.subject)” หลังอนุมัติ")
        gaps.append(gap)
    }

    // MARK: - approval

    /// Approves the plan as a block, the way §12.4 asks — one decision about
    /// the whole method, separate from the per-step approvals that come later.
    public mutating func approve(by approver: String) throws {
        let reasons = blockers
        guard reasons.isEmpty else { throw PlanApprovalError.notReady(reasons) }
        approvedAt = Date()
        approvedBy = approver
    }

    /// §12.3's loop back: an assumption failed, so the method changes, so the
    /// plan is no longer the one that was approved.
    ///
    /// The proposed alternative enters as `agent_suggested`, which means the
    /// plan cannot be re-approved until a person has looked at it. That is the
    /// whole mechanism — nothing here needs to know what a t-test is.
    public mutating func methodologyChanged(reason: String,
                                            proposal: AnalysisDecision? = nil) {
        approvedAt = nil
        approvedBy = nil
        revisions.append(reason)
        if let proposal { decisions.append(proposal) }
    }

    private mutating func loseApprovalIfHeld(_ reason: String) {
        guard isApproved else { return }
        approvedAt = nil
        approvedBy = nil
        revisions.append(reason)
    }
}


// ─────────────────────────────────────────────────────────────
// What a notebook cell answered (ARCHITECTURE §12.4 · §20.8, P11.9).
//
// Here rather than in M8 or M10 because it is the record those two share: the
// analysis store produces one when a cell runs, and the manuscript resolves its
// numbers out of one. Putting it in either would make the other depend on a
// DuckDB engine or on a document renderer to hold a table of strings.
// ─────────────────────────────────────────────────────────────

/// What a cell answered, recorded when it ran.
///
/// Carries `source` because "which query produced this number" is the question
/// a committee asks, and because a run whose source no longer matches the cell
/// is a run about a different question.
public struct CellRun: Sendable, Codable, Equatable, Identifiable {
    public let notebookID: String
    public let cellID: String
    public let source: String
    public let columns: [String]
    public let rows: [[String?]]
    public let ranAt: Date

    public var id: String { "\(notebookID)|\(cellID)" }

    public init(notebookID: String, cellID: String, source: String,
                columns: [String], rows: [[String?]], ranAt: Date = Date()) {
        self.notebookID = notebookID
        self.cellID = cellID
        self.source = source
        self.columns = columns
        self.rows = rows
        self.ranAt = ranAt
    }
}
