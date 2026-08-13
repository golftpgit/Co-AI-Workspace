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
    private let registers: (any RegisterPersisting)?
    private let baselines: (any BaselinePersisting)?
    private let lessons: (any LessonPublishing)?
    private let benefits: (any BenefitPersisting)?
    private let tailoring: (any TailoringPersisting)?
    private let closingLedger: (any ClosingLedgerReading)?
    private let reports: (any ReportPersisting)?
    /// What the app measured last time it looked (§19.16). Held rather than
    /// asked for, because `advance` evaluates the gate itself and cannot call
    /// back into a screen.
    private var observed = ObservedFacts()
    /// Which projects are outside their frame. Cached because the hook chain
    /// asks on every tool call, and refreshed on every write that could change
    /// the answer — the cost of being wrong here is work that should have
    /// stopped carrying on.
    private var blocked: Set<ProjectID> = []
    private var byID: [ProjectID: Project] = [:]
    private var loaded = false

    public init(store: any ProjectPersisting,
                plans: (any WorkPackagePersisting)? = nil,
                exceptions: (any ExceptionPersisting)? = nil,
                registers: (any RegisterPersisting)? = nil,
                baselines: (any BaselinePersisting)? = nil,
                lessons: (any LessonPublishing)? = nil,
                benefits: (any BenefitPersisting)? = nil,
                tailoring: (any TailoringPersisting)? = nil,
                closingLedger: (any ClosingLedgerReading)? = nil,
                reports: (any ReportPersisting)? = nil) {
        self.reports = reports
        self.store = store
        self.plans = plans
        self.exceptions = exceptions
        self.registers = registers
        self.baselines = baselines
        self.lessons = lessons
        self.benefits = benefits
        self.tailoring = tailoring
        self.closingLedger = closingLedger
    }

    /// Hands over the numbers only the app can read (§19.16). Called by the
    /// screen after it refreshes the status strip; the gate reads whatever
    /// arrived last, and a stale reading is visible as one because every
    /// conformance row says what it counted.
    public func observe(_ facts: ObservedFacts) {
        observed = facts
    }

    // MARK: - registers (§19.11)

    public func entries(of id: ProjectID, kind: RegisterKind? = nil) async -> [RegisterEntry] {
        let all = (try? await registers?.all(project: id)) ?? []
        let filtered = kind.map { wanted in all.filter { $0.kind == wanted } } ?? all
        return filtered.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func record(_ entry: RegisterEntry) async throws {
        try await registers?.save(entry)
    }

    /// Deciding a change request, and the one place a baseline is superseded.
    ///
    /// Approving is what creates the next version — the plan does not quietly
    /// become the new agreement by being edited (§19.11).
    public func decideChange(_ entry: RegisterEntry, approve: Bool,
                             by person: String) async throws {
        let decided = try entry.decided(approve: approve, by: person)
        try await record(decided)
        guard approve, let project = await project(entry.projectID) else { return }
        try await freezeBaseline(project, reason: "คำขอเปลี่ยนแปลง: \(entry.title)")
    }

    // MARK: - benefits (§19.12)

    public func benefitLedger(of id: ProjectID) async -> BenefitLedger {
        BenefitLedger((try? await benefits?.all(project: id)) ?? [])
    }

    public func save(_ benefit: Benefit) async throws {
        guard let benefits else { return }
        var updated = benefit
        updated.updatedAt = Date()
        try await benefits.save(updated)
    }

    /// Recording what a benefit turned out to be.
    ///
    /// Deliberately allowed on a closed project — that is what a review date
    /// three months out means, and §19.12 asks for the review rather than for a
    /// reopened project. It is the one write closing does not stop, and it is
    /// safe because a measurement adds a fact instead of changing an agreement.
    public func measure(_ benefit: Benefit, value: Double,
                        by person: String, note: String = "") async throws {
        let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BenefitError.emptyMeasurer }
        var updated = benefit
        updated.result = BenefitMeasurement(value: value, measuredBy: name, note: note)
        try await save(updated)
    }

    public func removeBenefit(_ benefitID: String, from id: ProjectID) async throws {
        try await benefits?.delete(benefitID, project: id)
    }

    // MARK: - reporting (§19.13)

    public func reportHistory(of id: ProjectID) async -> [ProjectReport] {
        ((try? await reports?.all(project: id)) ?? []).sorted { $0.generatedAt > $1.generatedAt }
    }

    /// Assembles one of the three reports out of the rows, and keeps it.
    ///
    /// Kept rather than only rendered because a report is a claim made on a
    /// date: "what did we say in June" is the question a status report exists to
    /// be able to answer, and it also makes `reporting` a practice with real
    /// evidence rather than one that needs a tailoring record (§19.16).
    @discardableResult
    public func issueReport(_ kind: ReportKind, for id: ProjectID,
                            now: Date = Date()) async throws -> ProjectReport? {
        guard let project = await project(id) else { return nil }
        let previous = await reportHistory(of: id).first { $0.kind == kind }
        let report = ReportBuilder.build(kind, from: ReportInputs(
            project: project,
            wbs: await breakdown(of: id),
            registers: await entries(of: id),
            benefits: await benefitLedger(of: id),
            baselines: await baselineHistory(of: id),
            drift: await drift(of: id),
            tolerances: ToleranceCheck.evaluate(project.tolerances, readings: observed.readings),
            measured: observed.measured,
            elapsedSeconds: observed.measuredSeconds,
            exceptions: (try? await openExceptions(id)) ?? [],
            gate: await gate(for: id),
            conformance: await conformance(of: id),
            since: previous?.generatedAt), now: now)
        try await reports?.save(report)
        return report
    }

    // MARK: - conformance and tailoring (§19.15–§19.16)

    public func tailoringRecords(of id: ProjectID) async -> [TailoringRecord] {
        ((try? await tailoring?.all(project: id)) ?? []).sorted { $0.decidedAt > $1.decidedAt }
    }

    /// Writing down that a practice is not being done, and why. Throws when
    /// either half is missing (`TailoringRecord.decided`).
    @discardableResult
    public func tailor(_ practice: Practice, in id: ProjectID,
                       reason: String, by person: String) async throws -> TailoringRecord {
        let record = try TailoringRecord.decided(projectID: id, practice: practice,
                                                 reason: reason, by: person)
        try await tailoring?.save(record)
        return record
    }

    /// All seventeen practices, each answered by something that exists.
    public func conformance(of id: ProjectID) async -> [PracticeStatus] {
        Conformance.evaluate(await conformanceFacts(of: id),
                             tailoring: await tailoringRecords(of: id))
    }

    /// Counted from the stores, never declared. A conformance matrix whose rows
    /// somebody ticked is the thing §19.16 says this one is not.
    public func conformanceFacts(of id: ProjectID) async -> ConformanceFacts {
        let project = await project(id)
        let leaves = await breakdown(of: id).leaves
        let entries = await entries(of: id)
        // Every exception report went out on every channel (§19.10), so each one
        // is a communication that demonstrably reached a person.
        let raised = ((try? await exceptions?.all(project: id)) ?? []).count
        return ConformanceFacts(
            leafCount: leaves.count,
            benefitCount: await benefitLedger(of: id).benefits.count,
            inScopeCount: project?.statement.inScope.count ?? 0,
            outOfScopeCount: project?.statement.outOfScope.count ?? 0,
            staffedLeaves: leaves.count { $0.role != nil || $0.raci?.responsible.isEmpty == false },
            dependencyCount: leaves.reduce(0) { $0 + $1.dependsOn.count },
            measuredSeconds: observed.measuredSeconds,
            spent: observed.spent,
            riskCount: entries.count { $0.kind == .risk },
            issueCount: entries.count { $0.kind == .issue },
            changeCount: entries.count { $0.kind == .change },
            decisionCount: entries.count { $0.kind == .decision },
            lessonCount: entries.count { $0.kind == .lesson },
            baselineVersions: await baselineHistory(of: id).count,
            evidenceCount: leaves.reduce(0) { $0 + $1.evidence.count(where: \.passed) },
            boardSeats: project?.board.count { $0.isFilled } ?? 0,
            messagesSent: observed.messagesSent + raised,
            reportsIssued: await reportHistory(of: id).count,
            dataDispositionDecided: project?.dataDisposition?.isDecided == true)
    }

    /// What happens to the leftovers (§19.12 condition 8).
    @discardableResult
    public func decideDisposition(_ disposition: DataDisposition,
                                  for id: ProjectID) async throws -> Project {
        guard var project = await project(id) else { throw LifecycleError.alreadyClosed }
        guard disposition.isDecided else { throw LifecycleError.dispositionIncomplete }
        project.dataDisposition = disposition
        try await update(project)
        return byID[project.id] ?? project
    }

    /// Everything G4 asks that is not in the plan. Assembled here because this
    /// is the only object that holds all of the stores it reads.
    public func closingFacts(of id: ProjectID) async -> ClosingFacts {
        guard let project = await project(id) else { return ClosingFacts() }
        let entries = await entries(of: id)
        let stillOpen = entries.count {
            [RegisterKind.risk, .issue, .change].contains($0.kind) && $0.status.isOpen
        }
        return ClosingFacts(
            openRegisterEntries: stillOpen,
            openConflicts: await closingLedger?.openConflictCount(scope: project.scope),
            pendingAssumptions: await closingLedger?.unconfirmedAssumptionCount(scope: project.scope),
            conformanceGaps: Conformance.gaps(await conformanceFacts(of: id),
                                              tailoring: await tailoringRecords(of: id)),
            dataDisposition: project.dataDisposition)
    }

    // MARK: - baselines (§19.11)

    public func baselineHistory(of id: ProjectID) async -> [Baseline] {
        ((try? await baselines?.all(project: id)) ?? []).sorted { $0.version > $1.version }
    }

    public func currentBaseline(of id: ProjectID) async -> Baseline? {
        await baselineHistory(of: id).first
    }

    /// Freezes the next version. Never overwrites: the count of versions is
    /// itself the answer to "how many times did the plan change".
    @discardableResult
    public func freezeBaseline(_ project: Project, reason: String) async throws -> Baseline? {
        guard let baselines else { return nil }
        let next = (await baselineHistory(of: project.id).first?.version ?? 0) + 1
        let baseline = Baseline.freeze(project, wbs: await breakdown(of: project.id),
                                       version: next, reason: reason)
        try await baselines.save(baseline)
        return baseline
    }

    /// What has moved since the plan was agreed. Empty when there is no
    /// baseline yet — before G2 there is nothing to have drifted from.
    public func drift(of id: ProjectID) async -> BaselineDiff? {
        guard let project = await project(id), let baseline = await currentBaseline(of: id) else {
            return nil
        }
        return BaselineDiff.between(baseline, and: project, wbs: await breakdown(of: id))
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
        // The sixth axis, filled in here rather than by the caller: this object
        // owns the benefit ledger, and a business-case tolerance the screen
        // computes is one the gate cannot check when nobody is looking at it.
        // Nothing measured leaves the reading alone — an unmeasured benefit is
        // not a benefit of zero (§19.12).
        var readings = readings
        if let achieved = await benefitLedger(of: id).lowestAchievement {
            readings.benefitRatio = achieved
        }
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
    /// Sends the project's lessons to wherever the next project will look for
    /// them. Nothing here knows what a knowledge base is — that is the point of
    /// `LessonPublishing`.
    private func publishLessons(of project: Project) async throws {
        guard let lessons else { return }
        let entries = await entries(of: project.id, kind: .lesson)
        guard !entries.isEmpty else { return }
        try await lessons.publish(entries, from: project)
    }

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
    public func gate(for id: ProjectID) async -> GateEvaluation? {
        guard let project = await project(id) else { return nil }
        return ProjectLifecycle.evaluate(
            project,
            wbs: await breakdown(of: id),
            hasLessons: !(await entries(of: id, kind: .lesson)).isEmpty,
            drift: await drift(of: id),
            undecidedChanges: await entries(of: id, kind: .change)
                .count { $0.status == .proposed },
            closing: project.stage == .closing ? await closingFacts(of: id) : ClosingFacts())
    }

    /// The only way a stage changes. Refuses rather than reports: a gate that
    /// returns "you probably should not" is a gate that gets ignored.
    @discardableResult
    public func advance(_ id: ProjectID) async throws -> Project {
        guard var project = await project(id) else { throw LifecycleError.alreadyClosed }
        guard let evaluation = await gate(for: id) else {
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

        // §19.11 — the plan becomes an agreement at G2, and the agreement is a
        // frozen copy rather than a promise to remember what it said.
        if project.stage == .execution {
            try await freezeBaseline(project, reason: "ผ่าน G2")
        }
        // §19.12 condition 7 — a lesson that never leaves the project it came
        // from has taught nobody.
        if project.stage == .closed {
            try await publishLessons(of: project)
        }
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
        defer { Task { try? await self.publishLessons(of: project) } }
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
