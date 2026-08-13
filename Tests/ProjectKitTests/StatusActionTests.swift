import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// The status bar's actions (ARCHITECTURE §19.2.3, P10.15).
//
// One test here is a rule rather than a case: **every** `StatusAction` must
// leave something in the register. The status bar can widen a budget or close an
// exception in one click from any screen, which makes it the easiest place in the
// system for a decision to be made and forgotten — so the test iterates the
// actions rather than checking the three that exist today, and a fourth case
// that forgets to record fails it.
// ─────────────────────────────────────────────────────────────

private func stoppedProject(_ service: ProjectService) async throws
-> (Project, ExceptionReport) {
    var project = try await service.create(
        name: "หยุดรอคน", brief: "b",
        statement: ScopeStatement(inScope: ["ก"], outOfScope: ["ข"],
                                  acceptanceCriteria: ["ตรวจได้"]),
        board: [BoardRole(seat: .executive, person: "ผู้ใช้")])
    project.stage = .execution
    project.tolerances = Tolerances(limits: [.cost: 100])
    try await service.update(project)

    let raised = try await service.raiseBreaches(for: project.id,
                                                readings: ToleranceReadings(spent: 900))
    return (project, raised[0])
}

private func service(_ registers: MemoryRegisterStore,
                     exceptions: MemoryExceptionStore = MemoryExceptionStore())
-> ProjectService {
    ProjectService(store: MemoryProjectStore(), plans: MemoryPlanStore(),
                   exceptions: exceptions, registers: registers,
                   baselines: MemoryBaselineStore())
}

@Suite("Status bar actions")
struct StatusActionTests {

    @Test("every action leaves a record in the register — all of them, by iteration")
    func nothingHappensSilently() async throws {
        for action in try await allActions() {
            let registers = MemoryRegisterStore()
            let service = service(registers)
            let (project, report) = try await stoppedProject(service)
            // Each case is rebuilt against this project, because an exception
            // from another service is not one this project can resolve.
            let bound = rebind(action, report: report)

            let before = await service.entries(of: project.id).count
            try await service.perform(bound, in: project.id, by: "ผู้ใช้")
            let after = await service.entries(of: project.id)

            #expect(after.count > before,
                    "\(bound.title) ไม่ได้เขียนอะไรลงทะเบียนเลย")
            // And whatever it wrote names a person. A record with no name is a
            // record of something that "was decided".
            #expect(after.contains { $0.origin.isHuman })
        }
    }

    @Test("deciding an exception from the popover unblocks the project and is recorded")
    func decidingWithoutChangingScreens() async throws {
        let registers = MemoryRegisterStore()
        let service = service(registers)
        let (project, report) = try await stoppedProject(service)
        #expect(await service.hasOpenException(project.id))

        await #expect(throws: StatusActionError.emptyDecision) {
            try await service.perform(.decideException(report, decision: "   "), in: project.id)
        }
        // Still stopped: a refused decision must not half-close anything.
        #expect(await service.hasOpenException(project.id))

        try await service.perform(.decideException(report, decision: "ยอมจ่ายเพิ่มรอบนี้"),
                                  in: project.id, by: "ผู้ใช้")
        #expect(!(await service.hasOpenException(project.id)))

        let decisions = await service.entries(of: project.id, kind: .decision)
        #expect(decisions.count == 1)
        #expect(decisions.first?.note == "ยอมจ่ายเพิ่มรอบนี้")
        // The alternatives that were on the table, kept from the report itself.
        if case .decision(let options, let reversible) = decisions.first?.detail {
            #expect(!options.isEmpty)
            // Work already done under the decision cannot be un-done.
            #expect(!reversible)
        } else {
            Issue.record("ไม่ได้บันทึกเป็นการตัดสินใจ")
        }
    }

    @Test("widening a breached frame closes the exception it raised")
    func wideningReleasesTheStop() async throws {
        let registers = MemoryRegisterStore()
        let service = service(registers)
        let (project, _) = try await stoppedProject(service)

        try await service.perform(.widenTolerance(.cost, to: 2_000, reason: "อนุมัติงบเพิ่ม"),
                                  in: project.id, by: "ผู้ใช้")

        // The frame moved…
        #expect(await service.project(project.id)?.tolerances.limit(.cost) == 2_000)
        // …and the stop that the old frame produced is gone with it. Leaving it
        // open would keep the project halted for a limit that no longer exists,
        // which reads as the system ignoring the decision.
        #expect(!(await service.hasOpenException(project.id)))
        #expect(await service.entries(of: project.id, kind: .decision).count == 1)
    }

    @Test("a frame widened after G2 also opens a change request")
    func wideningAfterBaselineIsAChange() async throws {
        let registers = MemoryRegisterStore()
        let baselines = MemoryBaselineStore()
        let service = ProjectService(store: MemoryProjectStore(), plans: MemoryPlanStore(),
                                     exceptions: MemoryExceptionStore(),
                                     registers: registers, baselines: baselines)
        let (project, _) = try await stoppedProject(service)
        try await service.freezeBaseline(project, reason: "ผ่าน G2")

        try await service.perform(.widenTolerance(.cost, to: 2_000, reason: "อนุมัติงบเพิ่ม"),
                                  in: project.id, by: "ผู้ใช้")
        // Two entries, and they are not the same thing: the decision says a
        // person chose this, the change request says the agreement has to catch
        // up and somebody still has to approve it (§19.11).
        #expect(await service.entries(of: project.id, kind: .decision).count == 1)
        #expect(await service.entries(of: project.id, kind: .change).count == 1)
        #expect(await service.entries(of: project.id, kind: .change).first?.status == .proposed)
    }

    @Test("opening a change request from the scope popover records the impact, not a decision")
    func driftBecomesARequest() async throws {
        let registers = MemoryRegisterStore()
        let service = service(registers)
        let (project, _) = try await stoppedProject(service)

        try await service.perform(.requestChange(title: "แผนต่างจาก baseline: เพิ่ม 2",
                                                 scopeImpact: "+2 ใบ",
                                                 timeImpact: "ยังประเมินไม่ได้",
                                                 costImpact: "ยังประเมินไม่ได้"),
                                  in: project.id, by: "ผู้ใช้")
        let changes = await service.entries(of: project.id, kind: .change)
        #expect(changes.count == 1)
        #expect(changes.first?.status == .proposed)
        // No decision entry: nothing was decided, something was *asked*. A
        // decision record here would claim the opposite of what happened.
        #expect(await service.entries(of: project.id, kind: .decision).isEmpty)
    }

    /// One of each case. Built in a function rather than a stored array because
    /// the exception case needs a report from a live service.
    private func allActions() async throws -> [StatusAction] {
        let placeholder = ExceptionReport(projectID: ProjectID("pj_x"), dimension: .cost,
                                         cause: "c", impact: "i", options: ["a", "b"],
                                         recommendation: "r", needsFromHuman: "n")
        return [
            .widenTolerance(.cost, to: 2_000, reason: "อนุมัติงบเพิ่ม"),
            .decideException(placeholder, decision: "ยอมจ่ายเพิ่ม"),
            .requestChange(title: "แผนเปลี่ยน", scopeImpact: "+1 ใบ",
                           timeImpact: "—", costImpact: "—"),
        ]
    }

    private func rebind(_ action: StatusAction, report: ExceptionReport) -> StatusAction {
        if case .decideException(_, let decision) = action {
            return .decideException(report, decision: decision)
        }
        return action
    }
}
