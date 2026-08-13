import Foundation

// ─────────────────────────────────────────────────────────────
// The work breakdown structure (ARCHITECTURE §19.6, P10.4).
//
// PRINCE2's product-based planning, and the reason for it: the leaves of the
// tree are *things that can be handed over*, not activities. Only a deliverable
// can be reviewed against evidence — "worked on the analysis" cannot fail a
// check, and a plan made of those is a plan that is always going fine until it
// suddenly is not.
//
// A leaf is one `Assignment`. That is not a coincidence to be maintained by
// hand: `Assignment.acceptanceCriteria` has been non-optional since P4, so the
// same field is spelled the same way here and a leaf that never said what
// "done" means cannot be turned into work.
// ─────────────────────────────────────────────────────────────

public enum WorkPackageStatus: String, Sendable, Codable, CaseIterable {
    case backlog
    case ready
    case inProgress
    case inReview
    case blocked
    case done

    public var label: String {
        switch self {
        case .backlog: "รอคิว"
        case .ready: "พร้อมเริ่ม"
        case .inProgress: "กำลังทำ"
        case .inReview: "รอ QA"
        case .blocked: "ติด"
        case .done: "เสร็จ"
        }
    }

    public var isOpen: Bool { self != .done }
}

public struct WorkPackage: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    /// `nil` for a top-level deliverable. A parent that does not exist is a
    /// broken tree, which `WorkBreakdown` reports rather than silently
    /// re-parenting.
    public var parent: String?
    public var title: String
    /// What is handed over — "สคริปต์ + log การรัน", "ตารางที่ 2". Prose, but
    /// prose about an object.
    public var deliverableType: String
    /// Which line of the project's in-scope list this exists for (§19.6).
    /// A leaf without one is work nobody agreed to, and G2 says so.
    public var scopeRef: String?
    /// Spelled like `Assignment`'s field on purpose: not optional, so a leaf
    /// cannot be written without the author being asked what done means. It
    /// can still be *empty*, which is a different failure and one the gate
    /// catches by name.
    public var acceptanceCriteria: [Criterion]
    /// Who it is for. `nil` until the lead assigns it.
    public var role: Role?
    /// Who answers for it (§19.9). `nil` until the plan says — G2 refuses to
    /// close over a leaf that nobody is accountable for.
    public var raci: RACI?
    /// How much is at stake in this deliverable. Declared by whoever plans it,
    /// and it decides one thing: work classified `.high` must be accountable
    /// to a person, not to the team lead (§19.9).
    public var riskClass: RiskLevel
    public var status: WorkPackageStatus
    /// Position among its siblings. Explicit rather than implied by insertion
    /// order, because a plan gets reordered and the order is part of it.
    public var order: Int
    /// What the reviewer accepted. Required to reach `.done` — see
    /// `WorkBreakdown.complete(_:with:)`.
    public var evidence: [Evidence]

    public init(id: String = OpaqueID.make(OpaqueID.workPackage),
                projectID: ProjectID,
                parent: String? = nil,
                title: String,
                deliverableType: String = "",
                scopeRef: String? = nil,
                acceptanceCriteria: [Criterion],
                role: Role? = nil,
                raci: RACI? = nil,
                riskClass: RiskLevel = .low,
                status: WorkPackageStatus = .backlog,
                order: Int = 0,
                evidence: [Evidence] = []) {
        self.id = id
        self.projectID = projectID
        self.parent = parent
        self.title = title
        self.deliverableType = deliverableType
        self.scopeRef = scopeRef
        self.acceptanceCriteria = acceptanceCriteria
        self.role = role
        self.raci = raci
        self.riskClass = riskClass
        self.status = status
        self.order = order
        self.evidence = evidence
    }

    /// The assignment this leaf becomes, or `nil` when it has nothing to be
    /// reviewed against. The one-way trip from plan to work goes through here,
    /// so a package that cannot say what done means cannot be handed to anyone.
    public func assignment(for role: Role? = nil) -> Assignment? {
        guard let role = role ?? self.role, !acceptanceCriteria.isEmpty else { return nil }
        return Assignment(role: role,
                          goal: title,
                          acceptanceCriteria: acceptanceCriteria,
                          deliverableType: deliverableType.isEmpty ? title : deliverableType)
    }
}

/// Where the plan is kept, as the lifecycle sees it. Same split as
/// `ProjectPersisting`: the rules live in ProjectKit, the rows live in
/// Persistence, and neither imports the other.
public protocol WorkPackagePersisting: Sendable {
    func save(_ package: WorkPackage) async throws
    func save(_ packages: [WorkPackage]) async throws
    func all(project: ProjectID) async throws -> [WorkPackage]
    func delete(_ id: String, project: ProjectID) async throws
}
