import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Baselines and change control (ARCHITECTURE §19.11, P10.7).
//
// A baseline is what was agreed, frozen at the moment it was agreed. Its whole
// value is that it does not move: the difference between it and the plan today
// is the only honest answer to "has this project changed", and a baseline that
// gets rewritten whenever the plan does answers "no" forever.
//
// So versions accumulate. v1 is still readable after v3 exists, and the number
// of versions is itself the answer to "how many times did the plan change" —
// a question nobody can reconstruct from a plan that was edited in place.
// ─────────────────────────────────────────────────────────────

public struct Baseline: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    /// 1, 2, 3… Never reused, never rewritten.
    public let version: Int
    public let frozenAt: Date
    /// Why this version exists. v1 says "ผ่าน G2"; later ones name the change
    /// request that produced them, so the history reads as a sequence of
    /// decisions rather than a pile of snapshots.
    public let reason: String
    public let scope: ScopeStatement
    public let packages: [WorkPackage]
    public let toleranceLimits: [String: Double]

    public init(id: String = OpaqueID.make(OpaqueID.baseline),
                projectID: ProjectID,
                version: Int,
                frozenAt: Date = Date(),
                reason: String,
                scope: ScopeStatement,
                packages: [WorkPackage],
                toleranceLimits: [String: Double]) {
        self.id = id
        self.projectID = projectID
        self.version = version
        self.frozenAt = frozenAt
        self.reason = reason
        self.scope = scope
        self.packages = packages
        self.toleranceLimits = toleranceLimits
    }

    public static func freeze(_ project: Project, wbs: WorkBreakdown,
                              version: Int, reason: String,
                              at date: Date = Date()) -> Baseline {
        Baseline(projectID: project.id, version: version, frozenAt: date,
                 reason: reason, scope: project.statement,
                 packages: wbs.packages, toleranceLimits: project.toleranceLimits)
    }
}

/// What moved since the baseline was frozen.
///
/// Renames and re-scopes count as changes rather than as new work: a leaf whose
/// title still matches but whose acceptance criteria were quietly rewritten is
/// exactly the drift a baseline exists to catch.
public struct BaselineDiff: Sendable, Equatable {
    public let added: [WorkPackage]
    public let removed: [WorkPackage]
    public let changed: [WorkPackage]
    public let scopeChanged: Bool

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && !scopeChanged
    }

    /// The number the scope tolerance reads (§19.10). Additions only: removing
    /// work does not widen a project, and counting it as drift would make
    /// cutting scope look like the same problem as growing it.
    public var addedCount: Double { Double(added.count) }

    public var summary: String {
        guard !isEmpty else { return "ตรงกับ baseline" }
        var parts: [String] = []
        if !added.isEmpty { parts.append("เพิ่ม \(added.count)") }
        if !removed.isEmpty { parts.append("ตัดออก \(removed.count)") }
        if !changed.isEmpty { parts.append("แก้ \(changed.count)") }
        if scopeChanged { parts.append("ขอบเขตเปลี่ยน") }
        return parts.joined(separator: " · ")
    }

    public static func between(_ baseline: Baseline, and project: Project,
                               wbs: WorkBreakdown) -> BaselineDiff {
        let before = Dictionary(baseline.packages.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let after = Dictionary(wbs.packages.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })

        let added = wbs.packages.filter { before[$0.id] == nil }
        let removed = baseline.packages.filter { after[$0.id] == nil }
        let changed = wbs.packages.filter { package in
            guard let original = before[package.id] else { return false }
            // Status is deliberately not compared: work getting done is not a
            // change to the plan, it is the plan happening.
            return original.title != package.title
                || original.acceptanceCriteria != package.acceptanceCriteria
                || original.scopeRef != package.scopeRef
                || original.parent != package.parent
                || original.riskClass != package.riskClass
        }
        return BaselineDiff(added: added, removed: removed, changed: changed,
                            scopeChanged: baseline.scope != project.statement)
    }
}

public protocol BaselinePersisting: Sendable {
    func save(_ baseline: Baseline) async throws
    func all(project: ProjectID) async throws -> [Baseline]
}
