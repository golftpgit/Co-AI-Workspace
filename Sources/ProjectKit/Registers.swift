import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The five registers (ARCHITECTURE §19.11, P10.8).
//
// One shape, five kinds. They share everything that makes a register useful —
// who raised it, who owns it, what state it is in, when it changed — and differ
// only in the fields that decide what to do about it. Five separate tables
// would have produced five slightly different answers to "is this still open".
//
// One rule is not shared, and it is the reason `decide` exists: **a change is
// decided by a person, always** (§19.11). An agent may propose one — that is
// most of the value — but approving a change to the baseline is the thing the
// standards reserve for whoever owns the business case, and here that is never
// an agent.
// ─────────────────────────────────────────────────────────────

public enum RegisterKind: String, Sendable, Codable, CaseIterable {
    case risk, issue, change, decision, lesson

    public var label: String {
        switch self {
        case .risk: "ความเสี่ยง"
        case .issue: "ปัญหา"
        case .change: "คำขอเปลี่ยนแปลง"
        case .decision: "การตัดสินใจ"
        case .lesson: "บทเรียน"
        }
    }
}

public enum RegisterStatus: String, Sendable, Codable, CaseIterable {
    case open
    case proposed
    case approved
    case rejected
    case closed

    public var isOpen: Bool { self == .open || self == .proposed }

    public var label: String {
        switch self {
        case .open: "เปิดอยู่"
        case .proposed: "รอตัดสิน"
        case .approved: "อนุมัติแล้ว"
        case .rejected: "ปฏิเสธ"
        case .closed: "ปิดแล้ว"
        }
    }
}

/// Who put it there. Kept because the answer changes what a reader does with
/// it: a risk an agent noticed is a prompt to look, a risk a person recorded is
/// a decision already made.
public enum RegisterOrigin: Sendable, Codable, Equatable {
    case agent(Role)
    case human(String)

    public var isHuman: Bool {
        if case .human = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .agent(let role): role.rawValue
        case .human(let name): name.isEmpty ? "คน" : name
        }
    }
}

/// The fields that differ. An enum rather than a bag of optionals, so a risk
/// cannot be written with a change's fields and every kind is exhaustive.
public enum RegisterDetail: Sendable, Codable, Equatable {
    /// probability and impact on 1–5, the response in PRINCE2's four.
    case risk(probability: Int, impact: Int, response: RiskResponse)
    case issue(severity: Int, kind: IssueKind)
    /// What it would do to the three things a baseline holds (§19.11).
    case change(scopeImpact: String, timeImpact: String, costImpact: String)
    case decision(options: [String], reversible: Bool)
    case lesson(cause: String, doDifferently: String, appliesTo: String)

    public var kind: RegisterKind {
        switch self {
        case .risk: .risk
        case .issue: .issue
        case .change: .change
        case .decision: .decision
        case .lesson: .lesson
        }
    }
}

public enum RiskResponse: String, Sendable, Codable, CaseIterable {
    case avoid, reduce, transfer, accept

    public var label: String {
        switch self {
        case .avoid: "เลี่ยง"
        case .reduce: "ลด"
        case .transfer: "โอน"
        case .accept: "ยอมรับ"
        }
    }
}

public enum IssueKind: String, Sendable, Codable, CaseIterable {
    case problem, concern, offSpecification

    public var label: String {
        switch self {
        case .problem: "ปัญหา"
        case .concern: "ข้อกังวล"
        case .offSpecification: "ไม่ตรงสเปก"
        }
    }
}

public struct RegisterEntry: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    public var title: String
    public var detail: RegisterDetail
    public var status: RegisterStatus
    public var origin: RegisterOrigin
    /// Who is doing something about it. Distinct from `origin`: noticing and
    /// owning are different jobs, and a register where they are the same field
    /// quietly makes whoever spotted a risk responsible for it.
    public var owner: RACIActor?
    public var note: String
    public let createdAt: Date
    public var updatedAt: Date
    /// Set when a person decides a change. Never set by anything else.
    public var decidedBy: String?

    public var kind: RegisterKind { detail.kind }

    public init(id: String = OpaqueID.make(OpaqueID.register),
                projectID: ProjectID,
                title: String,
                detail: RegisterDetail,
                status: RegisterStatus? = nil,
                origin: RegisterOrigin,
                owner: RACIActor? = nil,
                note: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                decidedBy: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.detail = detail
        // A change starts as a proposal, everything else starts open. Spelled
        // here so no caller has to remember it.
        self.status = status ?? (detail.kind == .change ? .proposed : .open)
        self.origin = origin
        self.owner = owner
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.decidedBy = decidedBy
    }
}

public enum RegisterError: Error, CustomStringConvertible, Equatable {
    case changeDecidedByAgent
    case notAChange
    case emptyDecider

    public var description: String {
        switch self {
        case .changeDecidedByAgent:
            "คำขอเปลี่ยนแปลงต้องให้คนตัดสิน — agent เสนอได้ แต่อนุมัติเองไม่ได้"
        case .notAChange: "รายการนี้ไม่ใช่คำขอเปลี่ยนแปลง"
        case .emptyDecider: "ต้องระบุชื่อผู้ตัดสิน"
        }
    }
}

extension RegisterEntry {
    /// Deciding a change request. The only way `approved`/`rejected` is
    /// reached, and it takes a person's name rather than a `RegisterOrigin` —
    /// there is no argument here that an agent can be passed as (§19.11).
    public func decided(approve: Bool, by person: String) throws -> RegisterEntry {
        guard kind == .change else { throw RegisterError.notAChange }
        let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RegisterError.emptyDecider }

        var decided = self
        decided.status = approve ? .approved : .rejected
        decided.decidedBy = name
        decided.updatedAt = Date()
        return decided
    }
}

/// Where the registers are kept. Same split as the rest of ProjectKit.
public protocol RegisterPersisting: Sendable {
    func save(_ entry: RegisterEntry) async throws
    func all(project: ProjectID) async throws -> [RegisterEntry]
}

/// Lessons leaving the project (§19.11, §19.12 condition 7).
///
/// A lesson that stays inside the project it came from has taught nobody. At
/// closing they go to the central knowledge base, which is what the next
/// project searches — the loop PRINCE2's "learn from experience" describes, and
/// the reason the register exists at all.
public protocol LessonPublishing: Sendable {
    func publish(_ lessons: [RegisterEntry], from project: Project) async throws
}

/// What a project leaves behind for the next one (§19.1.1, P21.4).
///
/// Lessons are the part somebody wrote deliberately. This is the rest: the
/// external references the project gathered and the conflict decisions it
/// declared as precedent — and, just as much, everything that must **not**
/// follow it up. Participants agreed to one study; their answers do not become
/// library stock because the study finished.
///
/// A protocol here for the same reason as `LessonPublishing`: ProjectKit
/// decides *when* this happens — at closing, once — and knows nothing about
/// what a knowledge base is.
public protocol ClosingKnowledgeHandover: Sendable {
    /// - Returns: how many chunks moved and how many deliberately stayed, so
    ///   the closing report can say so rather than leaving it to be assumed.
    @discardableResult
    func handOver(from project: Project) async throws -> HandoverCount
}

public struct HandoverCount: Sendable, Equatable {
    public let movedUp: Int
    public let keptInProject: Int
    public let precedents: Int

    public init(movedUp: Int, keptInProject: Int, precedents: Int) {
        self.movedUp = movedUp
        self.keptInProject = keptInProject
        self.precedents = precedents
    }
}
