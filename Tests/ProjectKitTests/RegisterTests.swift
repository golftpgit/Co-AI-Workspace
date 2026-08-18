import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// Registers, baselines and change control (§19.11, P10.7–P10.8).
//
// The two rules worth the tests are the two that decide whether a plan means
// anything a week later: a change is decided by a person, and a baseline is
// superseded rather than rewritten.
// ─────────────────────────────────────────────────────────────

actor MemoryRegisterStore: RegisterPersisting {
    private var rows: [String: RegisterEntry] = [:]
    func save(_ entry: RegisterEntry) async throws { rows[entry.id] = entry }
    func all(project: ProjectID) async throws -> [RegisterEntry] {
        rows.values.filter { $0.projectID == project }
    }
}

actor MemoryBaselineStore: BaselinePersisting {
    private(set) var rows: [Baseline] = []
    func save(_ baseline: Baseline) async throws { rows.append(baseline) }
    func all(project: ProjectID) async throws -> [Baseline] {
        rows.filter { $0.projectID == project }
    }
}

actor RecordingLessonPublisher: LessonPublishing {
    private(set) var published: [RegisterEntry] = []
    private(set) var fromProject: String?
    func publish(_ lessons: [RegisterEntry], from project: Project) async throws {
        published += lessons
        fromProject = project.name
    }
}

private let done = [Criterion(text: "ตรวจได้", evidenceRequired: "exit 0")]

private func makeService(baselines: MemoryBaselineStore = MemoryBaselineStore(),
                         lessons: RecordingLessonPublisher? = nil)
-> (ProjectService, MemoryProjectStore, MemoryRegisterStore) {
    let projects = MemoryProjectStore()
    let registers = MemoryRegisterStore()
    let service = ProjectService(store: projects, plans: MemoryPlanStore(),
                                 exceptions: MemoryExceptionStore(),
                                 registers: registers, baselines: baselines,
                                 lessons: lessons)
    return (service, projects, registers)
}

actor MemoryPlanStore: WorkPackagePersisting {
    private var rows: [String: WorkPackage] = [:]
    func save(_ package: WorkPackage) async throws { rows[package.id] = package }
    func save(_ packages: [WorkPackage]) async throws {
        for package in packages { rows[package.id] = package }
    }
    func all(project: ProjectID) async throws -> [WorkPackage] {
        rows.values.filter { $0.projectID == project }
    }
    func delete(_ id: String, project: ProjectID) async throws { rows.removeValue(forKey: id) }
}

@Suite("Registers")
struct RegisterTests {

    @Test("a change is decided by a person — an agent cannot be passed as one")
    func agentsProposeAndDoNotDecide() throws {
        let entry = RegisterEntry(
            projectID: ProjectID("pj_1"),
            title: "ตัดข้อ 14 และ 17",
            detail: .change(scopeImpact: "นิยามตัวแปรเปลี่ยน",
                            timeImpact: "+0.5 วัน", costImpact: "+$40"),
            origin: .agent(.analyst))

        // An agent may raise it, and it starts as a proposal without anyone
        // having to remember to set that.
        #expect(entry.status == .proposed)

        // `decided(by:)` takes a person's name. There is no argument here that
        // a `Role` can be passed as, which is the same shape as the Executive
        // seat: the rule is in the signature rather than in a check.
        let decided = try entry.decided(approve: true, by: "ผู้ใช้")
        #expect(decided.status == .approved)
        #expect(decided.decidedBy == "ผู้ใช้")

        #expect(throws: RegisterError.emptyDecider) {
            try entry.decided(approve: true, by: "   ")
        }
    }

    @Test("only a change request can be decided")
    func otherKindsAreNotDecided() {
        let risk = RegisterEntry(projectID: ProjectID("pj_1"), title: "ข้อมูลอาจไม่พอ",
                                 detail: .risk(probability: 3, impact: 4, response: .reduce),
                                 origin: .agent(.analyst))
        #expect(risk.status == .open)
        #expect(throws: RegisterError.notAChange) { try risk.decided(approve: true, by: "ผู้ใช้") }
    }

    @Test("approving a change freezes the next baseline instead of rewriting the last")
    func approvalSupersedes() async throws {
        let baselines = MemoryBaselineStore()
        let (service, _, _) = makeService(baselines: baselines)
        let project = try await service.create(name: "ความเครียดพยาบาล")
        try await service.freezeBaseline(project, reason: "ผ่าน G2")

        let change = RegisterEntry(projectID: project.id, title: "เพิ่มงานตรวจความเที่ยง",
                                   detail: .change(scopeImpact: "+1 ใบ", timeImpact: "+1 วัน",
                                                   costImpact: "+$40"),
                                   origin: .agent(.analyst))
        try await service.record(change)
        try await service.decideChange(change, approve: true, by: "ผู้ใช้")

        let history = await service.baselineHistory(of: project.id)
        #expect(history.map(\.version) == [2, 1])
        // v1 is still readable, which is the whole point: the number of
        // versions is the answer to "how many times did the plan change".
        #expect(history.last?.reason == "ผ่าน G2")
        #expect(history.first?.reason.contains("เพิ่มงานตรวจความเที่ยง") == true)
    }

    @Test("rejecting a change leaves the baseline alone")
    func rejectionChangesNothing() async throws {
        let baselines = MemoryBaselineStore()
        let (service, _, _) = makeService(baselines: baselines)
        let project = try await service.create(name: "คัดกรองเบาหวาน")
        try await service.freezeBaseline(project, reason: "ผ่าน G2")

        let change = RegisterEntry(projectID: project.id, title: "ขยายไปอีก รพ.",
                                   detail: .change(scopeImpact: "+3 ใบ", timeImpact: "+2 สัปดาห์",
                                                   costImpact: "+$800"),
                                   origin: .agent(.teamLead))
        try await service.record(change)
        try await service.decideChange(change, approve: false, by: "ผู้ใช้")

        #expect(await service.baselineHistory(of: project.id).count == 1)
    }
}

@Suite("Baseline drift")
struct BaselineDriftTests {

    private func project() -> Project {
        Project(name: "ความเครียดพยาบาล",
                brief: "วัดความชุก",
                statement: ScopeStatement(inScope: ["ความชุก"], outOfScope: ["ข้ามวิชาชีพ"]),
                board: [BoardRole(seat: .executive, person: "ผู้ใช้")])
    }

    private func leaf(_ id: String, title: String, project: Project) -> WorkPackage {
        WorkPackage(id: id, projectID: project.id, title: title, scopeRef: "ความชุก",
                    acceptanceCriteria: done, raci: RACI(accountable: .teamLead))
    }

    @Test("work getting done is not a change to the plan")
    func statusIsNotDrift() {
        let project = project()
        let package = leaf("a", title: "สคริปต์", project: project)
        let baseline = Baseline.freeze(project, wbs: WorkBreakdown([package]),
                                       version: 1, reason: "ผ่าน G2")

        var working = package
        working.status = .inProgress
        let diff = BaselineDiff.between(baseline, and: project, wbs: WorkBreakdown([working]))
        #expect(diff.isEmpty)
    }

    @Test("a leaf quietly rewritten counts as changed, not as the same work")
    func rewrittenCriteriaAreDrift() {
        let project = project()
        let package = leaf("a", title: "สคริปต์", project: project)
        let baseline = Baseline.freeze(project, wbs: WorkBreakdown([package]),
                                       version: 1, reason: "ผ่าน G2")

        var edited = package
        edited.acceptanceCriteria = [Criterion(text: "ดูดี", evidenceRequired: "—")]
        let diff = BaselineDiff.between(baseline, and: project, wbs: WorkBreakdown([edited]))
        #expect(diff.changed.map(\.id) == ["a"])
        #expect(!diff.isEmpty)
    }

    @Test("cutting scope is not the same problem as growing it")
    func onlyAdditionsCountTowardsTheScopeTolerance() {
        let project = project()
        let first = leaf("a", title: "สคริปต์", project: project)
        let second = leaf("b", title: "รายงาน", project: project)
        let baseline = Baseline.freeze(project, wbs: WorkBreakdown([first, second]),
                                       version: 1, reason: "ผ่าน G2")

        let cut = BaselineDiff.between(baseline, and: project, wbs: WorkBreakdown([first]))
        #expect(cut.removed.map(\.id) == ["b"])
        // The tolerance counts additions: removing work does not widen a
        // project, and counting it as drift would make cutting scope look like
        // the same failure as scope creep.
        #expect(cut.addedCount == 0)

        let third = leaf("c", title: "บทที่ 4", project: project)
        let grown = BaselineDiff.between(baseline, and: project,
                                         wbs: WorkBreakdown([first, second, third]))
        #expect(grown.addedCount == 1)
    }

    @Test("editing the scope statement itself is drift")
    func scopeStatementDrift() {
        var project = project()
        let baseline = Baseline.freeze(project, wbs: WorkBreakdown(), version: 1, reason: "ผ่าน G2")
        project.statement.inScope.append("เปรียบเทียบสองโรงพยาบาล")

        #expect(BaselineDiff.between(baseline, and: project, wbs: WorkBreakdown()).scopeChanged)
    }
}

@Suite("Lessons leave the project")
struct LessonPublishingTests {

    @Test("closing a project sends its lessons to where the next one will look")
    func lessonsArePublishedAtClosing() async throws {
        let publisher = RecordingLessonPublisher()
        let (service, _, _) = makeService(lessons: publisher)
        let project = try await service.terminateAfterLesson(name: "ความเครียดพยาบาล")

        // §19.12 condition 7 — a lesson that stays inside the project it came
        // from has taught nobody.
        #expect(await publisher.published.count == 1)
        #expect(await publisher.fromProject == project.name)
        #expect(await publisher.published.first?.title == "ฉบับแปลไทยมักไม่รายงาน α รายด้าน")
    }
}

private extension ProjectService {
    /// Creates a project, records one lesson, and terminates it — the shortest
    /// real path to "a closed project with something worth keeping".
    func terminateAfterLesson(name: String) async throws -> Project {
        let project = try await create(name: name)
        try await record(RegisterEntry(
            projectID: project.id,
            title: "ฉบับแปลไทยมักไม่รายงาน α รายด้าน",
            detail: .lesson(cause: "ผู้แปลไม่ได้ตีพิมพ์ภาคผนวก",
                            doDifferently: "ขอฉบับเต็มจากผู้แปลตั้งแต่ต้น",
                            appliesTo: "งานที่ใช้มาตรวัดแปล"),
            origin: .agent(.researcher)))
        _ = try await terminate(project.id, reason: "จบรอบ")
        // `terminate` publishes in a detached task so closing is not held up by
        // an indexing run; give it the turn it needs.
        try await Task.sleep(for: .milliseconds(50))
        return project
    }
}
