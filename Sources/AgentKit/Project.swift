import Foundation

// ─────────────────────────────────────────────────────────────
// A project, as a thing the system knows about (ARCHITECTURE §19.1).
//
// `Scope.project` has existed since P0, but only as a label: nothing could say
// when a project started, what it covered, which stage it was in, or whether it
// could be closed — and the app filled the id in with the literal string
// "default", so every project was the same project.
//
// Declared here for the same reason `Scope` is: the store, the lifecycle, the
// gate and the UI all need these types, and a type declared in three places is
// the v1 mistake §0.2 rule 3 exists to prevent.
// ─────────────────────────────────────────────────────────────

/// The five stages of §19.4. `closed` is the terminal state, distinct from
/// `closing` — "we are wrapping up" and "it is over" allow different work.
public enum ProjectStage: String, Sendable, Codable, CaseIterable, Comparable {
    case initiation
    case planning
    case execution
    case closing
    case closed

    /// Order of the life cycle, used for "forward only" transition checks.
    public var order: Int {
        switch self {
        case .initiation: 0
        case .planning: 1
        case .execution: 2
        case .closing: 3
        case .closed: 4
        }
    }

    public static func < (lhs: ProjectStage, rhs: ProjectStage) -> Bool {
        lhs.order < rhs.order
    }

    public var label: String {
        switch self {
        case .initiation: "เริ่มต้น"
        case .planning: "วางแผน"
        case .execution: "ดำเนินงาน"
        case .closing: "ปิดโครงการ"
        case .closed: "ปิดแล้ว"
        }
    }

    /// The gate that has to pass to *leave* this stage (§19.4). `closed` has
    /// none — there is nowhere further to go.
    public var exitGate: String? {
        switch self {
        case .initiation: "G1"
        case .planning: "G2"
        case .execution: "G3"
        case .closing: "G4"
        case .closed: nil
        }
    }
}

/// Which template a project follows (§20.2). A declared shape, not behaviour:
/// what each one implies lives in its manifest, so adding one is a file.
public enum ProjectKind: String, Sendable, Codable, CaseIterable {
    case blank
    case research
    case software
    case analysis

    public var label: String {
        switch self {
        case .blank: "ทั่วไป"
        case .research: "งานวิจัย"
        case .software: "ซอฟต์แวร์"
        case .analysis: "วิเคราะห์ข้อมูล"
        }
    }
}

/// §19.6. Five lists, and `outOfScope` matters as much as `inScope`: a
/// boundary that never says what is *not* being done is a boundary that moves
/// every week, and it is what an agent needs in order to refuse work with a
/// reason rather than an opinion.
public struct ScopeStatement: Sendable, Codable, Equatable {
    public var inScope: [String]
    public var outOfScope: [String]
    public var assumptions: [String]
    public var constraints: [String]
    public var acceptanceCriteria: [String]

    public init(inScope: [String] = [],
                outOfScope: [String] = [],
                assumptions: [String] = [],
                constraints: [String] = [],
                acceptanceCriteria: [String] = []) {
        self.inScope = inScope
        self.outOfScope = outOfScope
        self.assumptions = assumptions
        self.constraints = constraints
        self.acceptanceCriteria = acceptanceCriteria
    }

    public var isEmpty: Bool {
        inScope.isEmpty && outOfScope.isEmpty && assumptions.isEmpty
            && constraints.isEmpty && acceptanceCriteria.isEmpty
    }
}

/// How a project ended. Recorded rather than inferred: a project stopped
/// halfway is a legitimate outcome, and calling it "done" loses the one fact
/// anybody reading it later needs (§19.12).
public enum ProjectClosure: String, Sendable, Codable {
    case completed
    case terminated

    public var label: String {
        switch self {
        case .completed: "ส่งมอบครบ"
        case .terminated: "ยุติก่อนกำหนด"
        }
    }
}

public struct Project: Sendable, Codable, Equatable, Identifiable {
    public let id: ProjectID
    public var name: String
    public var kind: ProjectKind
    public var stage: ProjectStage
    public var brief: String
    public var statement: ScopeStatement
    public let createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?
    public var closure: ProjectClosure?

    public init(id: ProjectID = ProjectID(OpaqueID.make(OpaqueID.project)),
                name: String,
                kind: ProjectKind = .blank,
                stage: ProjectStage = .initiation,
                brief: String = "",
                statement: ScopeStatement = ScopeStatement(),
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                closedAt: Date? = nil,
                closure: ProjectClosure? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.stage = stage
        self.brief = brief
        self.statement = statement
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.closure = closure
    }

    /// Everything a project owns is addressed through this — knowledge, task
    /// ledger, spans, conversations, notebooks. One accessor rather than
    /// `.project(project.id)` spelled out at every call site.
    public var scope: Scope { .project(id) }

    public var isOpen: Bool { stage != .closed }
}

/// What the hook chain needs to know about a project, and nothing more.
///
/// Declared in AgentKit so `CoreEngine` can gate on the stage without
/// depending on `ProjectKit` — the same shape as `ApprovalAnswering`, and for
/// the same reason: the module that owns the decision must not have to import
/// the module that owns the data (§19.15).
public protocol ProjectStageReading: Sendable {
    /// `nil` means "no such project", which the gate treats as a refusal, not
    /// as permission — an unknown id is exactly the case where guessing is
    /// worst.
    func stage(of id: ProjectID) async -> ProjectStage?
}

/// Where projects are kept, as the lifecycle sees it.
///
/// Declared here so `ProjectKit` owns the rules without importing the database:
/// the store lives in `Persistence` with every other store, and the two meet at
/// this protocol instead of at an import that would point the wrong way.
public protocol ProjectPersisting: Sendable {
    func save(_ project: Project) async throws
    func all() async throws -> [Project]
    func project(_ id: ProjectID) async throws -> Project?
    func delete(_ id: ProjectID) async throws
}
