import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The one owner of project state (ARCHITECTURE §19.15, P10.1/P10.2).
//
// Everything that wants to know or change what a project is goes through here:
// the UI, and — through `ProjectStageReading` — the hook chain. That matters
// for the gate specifically. If the stage the gate reads could come from a
// second copy held somewhere else, the two would drift, and the drift would
// show up as tools running in a stage that forbids them.
//
// The in-memory cache is a cache of the store, never a second source: every
// mutation writes through before it is visible, and `refresh` replaces the
// cache wholesale rather than merging.
// ─────────────────────────────────────────────────────────────

public actor ProjectService {
    private let store: any ProjectPersisting
    private let plans: (any WorkPackagePersisting)?
    private let exceptions: (any ExceptionPersisting)?
    /// Which projects are outside their frame. Cached because the hook chain
    /// asks on every tool call, and refreshed on every write that could change
    /// the answer — the cost of being wrong here is work that should have
    /// stopped carrying on.
    private var blocked: Set<ProjectID> = []
    private var byID: [ProjectID: Project] = [:]
    private var loaded = false

    public init(store: any ProjectPersisting,
                plans: (any WorkPackagePersisting)? = nil,
                exceptions: (any ExceptionPersisting)? = nil) {
        self.store = store
        self.plans = plans
        self.exceptions = exceptions
    }

    // MARK: - exceptions (§19.10)

    /// Raises the report and stops the project until somebody answers.
    @discardableResult
    public func raise(_ report: ExceptionReport) async throws -> ExceptionReport {
        try await exceptions?.save(report)
        blocked.insert(report.projectID)
        return report
    }

    /// Raises one report per breached dimension that does not already have an
    /// open one. Returns what was newly raised, so the caller sends exactly the
    /// messages that are new rather than repeating them every check.
    @discardableResult
    public func raiseBreaches(for id: ProjectID,
                              readings: ToleranceReadings) async throws -> [ExceptionReport] {
        guard let project = await project(id) else { return [] }
        let open = Set((try? await openExceptions(id))?.map(\.dimension) ?? [])
        var raised: [ExceptionReport] = []
        for status in ToleranceCheck.breaches(project.tolerances, readings: readings)
        where !open.contains(status.dimension) {
            raised.append(try await raise(.automatic(projectID: id, status: status)))
        }
        return raised
    }

    public func openExceptions(_ id: ProjectID) async throws -> [ExceptionReport] {
        guard let exceptions else { return [] }
        return try await exceptions.all(project: id).filter(\.isOpen)
    }

    public func resolve(_ report: ExceptionReport, decision: String) async throws {
        guard let exceptions else { return }
        var resolved = report
        resolved.resolvedAt = Date()
        resolved.resolution = decision
        try await exceptions.save(resolved)
        blocked = try await openExceptions(report.projectID).isEmpty
            ? blocked.subtracting([report.projectID])
            : blocked.union([report.projectID])
    }

    /// Reloads the blocked set from the store. Called at boot: an exception
    /// raised before the app was closed must still stop work after it reopens.
    public func refreshExceptions() async {
        guard let exceptions else { return }
        var stopped: Set<ProjectID> = []
        for project in (try? await projects()) ?? [] {
            if let open = try? await exceptions.all(project: project.id), open.contains(where: \.isOpen) {
                stopped.insert(project.id)
            }
        }
        blocked = stopped
    }

    // MARK: - the plan

    /// The project's WBS, read fresh. Not cached: the tree is small, it is
    /// edited constantly, and a stale plan feeding a gate is the one kind of
    /// staleness that matters here.
    public func breakdown(of id: ProjectID) async -> WorkBreakdown {
        guard let plans, let packages = try? await plans.all(project: id) else {
            return WorkBreakdown()
        }
        return WorkBreakdown(packages)
    }

    public func save(_ package: WorkPackage) async throws {
        guard let plans else { return }
        try await plans.save(package)
    }

    public func removePackage(_ packageID: String, from id: ProjectID) async throws {
        guard let plans else { return }
        try await plans.delete(packageID, project: id)
    }

    /// Closing a leaf. Goes through `WorkBreakdown` so the evidence rule is
    /// enforced in one place rather than at each caller (§19.15 invariant 4).
    public func complete(_ packageID: String, in id: ProjectID,
                         with evidence: [Evidence]) async throws {
        let wbs = await breakdown(of: id)
        try await save(wbs.complete(packageID, with: evidence))
    }

    // MARK: - reading

    @discardableResult
    public func refresh() async throws -> [Project] {
        let all = try await store.all()
        byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        loaded = true
        return all
    }

    /// Newest first, open ones before closed — the order the sidebar wants,
    /// decided once here rather than in each view that lists them.
    public func projects() async throws -> [Project] {
        if !loaded { _ = try await refresh() }
        return byID.values.sorted { lhs, rhs in
            if lhs.isOpen != rhs.isOpen { return lhs.isOpen }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public func project(_ id: ProjectID) async -> Project? {
        if let cached = byID[id] { return cached }
        guard let fetched = try? await store.project(id) else { return nil }
        byID[id] = fetched
        return fetched
    }

    // MARK: - writing

    public func create(name: String,
                       kind: ProjectKind = .blank,
                       brief: String = "",
                       statement: ScopeStatement = ScopeStatement(),
                       board: [BoardRole] = []) async throws -> Project {
        let project = Project(name: name, kind: kind, brief: brief,
                              statement: statement, board: board)
        try await store.save(project)
        byID[project.id] = project
        return project
    }

    public func update(_ project: Project) async throws {
        var updated = project
        updated.updatedAt = Date()
        try await store.save(updated)
        byID[updated.id] = updated
    }

    /// The gate for the *next* stage boundary, or nil for a closed project.
    public func gate(for id: ProjectID, hasLessons: Bool = true) async -> GateEvaluation? {
        guard let project = await project(id) else { return nil }
        return ProjectLifecycle.evaluate(project, wbs: await breakdown(of: id),
                                         hasLessons: hasLessons)
    }

    /// The only way a stage changes. Refuses rather than reports: a gate that
    /// returns "you probably should not" is a gate that gets ignored.
    @discardableResult
    public func advance(_ id: ProjectID, hasLessons: Bool = true) async throws -> Project {
        guard var project = await project(id) else { throw LifecycleError.alreadyClosed }
        guard let evaluation = ProjectLifecycle.evaluate(project,
                                                         wbs: await breakdown(of: id),
                                                         hasLessons: hasLessons) else {
            throw LifecycleError.alreadyClosed
        }
        guard evaluation.passed else {
            throw LifecycleError.gateNotPassed(gate: evaluation.gate, unmet: evaluation.unmet)
        }
        project.stage = evaluation.to
        if project.stage == .closed {
            project.closedAt = Date()
            project.closure = .completed
        }
        try await update(project)
        return byID[project.id] ?? project
    }

    /// Ending a project without passing G4. Recorded as `terminated`, never as
    /// completed — §19.12: stopping early is a legitimate outcome, and calling
    /// it success loses the only fact a later reader needs.
    @discardableResult
    public func terminate(_ id: ProjectID, reason: String) async throws -> Project {
        guard var project = await project(id) else { throw LifecycleError.alreadyClosed }
        guard project.isOpen else { throw LifecycleError.alreadyClosed }
        project.stage = .closed
        project.closedAt = Date()
        project.closure = .terminated
        project.brief = project.brief.isEmpty
            ? "ยุติก่อนกำหนด: \(reason)"
            : project.brief + "\n\nยุติก่อนกำหนด: \(reason)"
        try await update(project)
        return byID[project.id] ?? project
    }

    public func delete(_ id: ProjectID) async throws {
        try await store.delete(id)
        byID.removeValue(forKey: id)
    }
}

// The gate asks this, and only this. Kept deliberately narrow: the hook chain
// has no business reading a scope statement.
extension ProjectService: ProjectStageReading {
    public func stage(of id: ProjectID) async -> ProjectStage? {
        await project(id)?.stage
    }

    public func hasOpenException(_ id: ProjectID) async -> Bool {
        blocked.contains(id)
    }
}
