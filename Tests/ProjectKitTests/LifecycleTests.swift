import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// The stage machine (ARCHITECTURE §19.4, P10.2).
//
// What is under test here is the *refusal*: a gate that reports a problem and
// advances anyway is a label, and this project has already paid for one of
// those. The store behind the service is a double on purpose — persistence has
// its own suite against a real SurrealDB (PersistenceTests/ProjectStoreTests),
// and what these tests are about is which transitions are legal.
// ─────────────────────────────────────────────────────────────

actor MemoryProjectStore: ProjectPersisting {
    private var rows: [ProjectID: Project] = [:]
    private(set) var writes = 0

    func save(_ project: Project) async throws {
        rows[project.id] = project
        writes += 1
    }
    func all() async throws -> [Project] { Array(rows.values) }
    func project(_ id: ProjectID) async throws -> Project? { rows[id] }
    func delete(_ id: ProjectID) async throws { rows.removeValue(forKey: id) }
}

private func briefed(_ name: String = "ความเครียดพยาบาล") -> Project {
    Project(name: name,
            kind: .research,
            brief: "วัดความชุกของภาวะหมดไฟใน รพ. ตติยภูมิ 2 แห่ง",
            statement: ScopeStatement(
                inScope: ["ความชุกในพยาบาลวิชาชีพ"],
                outOfScope: ["การเปรียบเทียบข้ามวิชาชีพ"]),
            board: [BoardRole(seat: .executive, person: "ผู้ใช้")])
}

@Suite("Project life cycle")
struct LifecycleTests {

    @Test("G1 refuses a project that never said what it is not doing")
    func outOfScopeIsRequired() async throws {
        var project = briefed()
        project.statement.outOfScope = []

        let gate = try #require(ProjectLifecycle.evaluate(project))
        #expect(gate.gate == "G1")
        #expect(!gate.passed)
        // The one people skip. A boundary with only an in-scope list is a
        // boundary that moves every week (§19.6).
        #expect(gate.unmet == ["ขอบเขต 'ไม่ทำ' อย่างน้อย 1 ข้อ"])
    }

    @Test("G1 refuses a project with no reason to exist")
    func briefIsRequired() async throws {
        var project = briefed()
        project.brief = "   "

        let gate = try #require(ProjectLifecycle.evaluate(project))
        #expect(gate.unmet == ["มีเหตุผลที่ทำ (brief)"])
    }

    @Test("a complete brief passes G1 and lands in Planning")
    func advancesThroughG1() async throws {
        let service = ProjectService(store: MemoryProjectStore())
        var seeded = briefed()
        seeded.board = [BoardRole(seat: .executive, person: "ผู้ใช้")]
        let created = try await service.create(name: seeded.name, kind: .research,
                                               brief: seeded.brief,
                                               statement: seeded.statement,
                                               board: seeded.board)
        #expect(created.stage == .initiation)

        let moved = try await service.advance(created.id)
        #expect(moved.stage == .planning)
        #expect(await service.stage(of: created.id) == .planning)
    }

    @Test("advancing past a gate that has not passed throws, and changes nothing")
    func refusalLeavesTheStageAlone() async throws {
        let service = ProjectService(store: MemoryProjectStore())
        let created = try await service.create(name: "ไม่มีขอบเขต")

        await #expect(throws: LifecycleError.self) {
            try await service.advance(created.id)
        }
        // The half that matters. A gate that reports a problem and moves the
        // project anyway is worse than no gate: it produces a stage nobody
        // agreed to *and* a record that says it was checked.
        #expect(await service.stage(of: created.id) == .initiation)
    }

    @Test("Execution will not close while a work package is open")
    func executionNeedsEverythingDone() async throws {
        var project = briefed()
        project.stage = .execution
        // The count comes from the plan itself (P10.4) rather than from a
        // number the caller supplies — a gate whose input is an argument is a
        // gate whose input can be wrong.
        let leaf = WorkPackage(projectID: project.id, title: "สคริปต์",
                               scopeRef: project.statement.inScope[0],
                               acceptanceCriteria: [Criterion(text: "รันได้", evidenceRequired: "exit 0")],
                               raci: RACI(accountable: .teamLead))
        var finished = leaf
        finished.status = .done

        let gate = try #require(ProjectLifecycle.evaluate(project, wbs: WorkBreakdown([leaf])))
        #expect(gate.gate == "G3")
        #expect(!gate.passed)
        #expect(ProjectLifecycle.evaluate(project, wbs: WorkBreakdown([finished]))?.passed == true)
    }

    @Test("Closing reads all eight conditions, and a lesson is one of them")
    func closingNeedsLessons() async throws {
        var project = briefed()
        project.stage = .closing

        let gate = try #require(ProjectLifecycle.evaluate(project, hasLessons: false))
        #expect(gate.conditions.count == 8)
        #expect(gate.unmet.contains { $0.contains("บันทึกบทเรียน") })
        // Writing the lesson is necessary and not sufficient — the other seven
        // are in ClosingTests, one case each (§19.12).
        #expect(ProjectLifecycle.evaluate(project, hasLessons: true)?.passed == false)
    }

    @Test("stopping early is recorded as terminated, not as completed")
    func terminationKeepsTheTruth() async throws {
        let service = ProjectService(store: MemoryProjectStore())
        let created = try await service.create(name: "คัดกรองเบาหวาน")

        let ended = try await service.terminate(created.id, reason: "ข้อมูลไม่พอ")
        #expect(ended.stage == .closed)
        #expect(ended.closure == .terminated)
        #expect(ended.closedAt != nil)
        #expect(ended.brief.contains("ข้อมูลไม่พอ"))
        // §19.12 — a project stopped halfway is a legitimate outcome, and
        // calling it success loses the only fact a later reader needs.
        #expect(ended.closure != .completed)
    }

    @Test("a closed project has no next stage and cannot be advanced")
    func closedIsTerminal() async throws {
        let service = ProjectService(store: MemoryProjectStore())
        let created = try await service.create(name: "ปิดแล้ว")
        _ = try await service.terminate(created.id, reason: "จบ")

        #expect(await service.gate(for: created.id) == nil)
        await #expect(throws: LifecycleError.self) {
            try await service.advance(created.id)
        }
    }

    @Test("open projects sort before closed ones")
    func openProjectsComeFirst() async throws {
        let service = ProjectService(store: MemoryProjectStore())
        let done = try await service.create(name: "ปิดแล้ว")
        _ = try await service.terminate(done.id, reason: "จบ")
        let live = try await service.create(name: "ยังทำอยู่")

        let listed = try await service.projects()
        #expect(listed.map(\.id) == [live.id, done.id])
    }
}
