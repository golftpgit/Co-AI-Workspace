import Testing
import Foundation
import AgentKit
import LLMProviders
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P21.2 — the work belongs to the workspace, not to the screen.
//
// The Done-when in words: start team work in project A, switch to B, come back
// to A, and the work is still running. Every one of these tests is a way that
// used to be false while there was one lead for the whole app.
// ─────────────────────────────────────────────────────────────

private let projectA = Scope.project(ProjectID("a"))
private let projectB = Scope.project(ProjectID("b"))

/// A specialist that starts its work and then stops, until a test lets it go.
/// This is how "in flight" is a real state here rather than a flag somebody
/// set: the assignment is genuinely half-done while the switch happens.
private actor GatedSpecialist: Specialist {
    nonisolated let role: Role
    nonisolated let definitionOfDone: [Criterion] = [
        Criterion(text: "เทสผ่าน", evidenceRequired: "exit code 0"),
    ]
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var started = 0

    init(role: Role = .engineer) { self.role = role }

    func execute(_ assignment: Assignment) async throws -> Deliverable {
        started += 1
        if !released {
            await withCheckedContinuation { waiting.append($0) }
        }
        return Deliverable(assignmentID: assignment.id, summary: "แก้แล้ว",
                           evidence: [Evidence(kind: .commandExit,
                                               summary: "exit code: 0", passed: true)])
    }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

private func plan(_ id: String) -> TeamPlan {
    TeamPlan(goal: "แก้เทสให้ผ่าน", assignments: [
        Assignment(id: id, role: .engineer, goal: "แก้เทส",
                   acceptanceCriteria: [Criterion(text: "เทสผ่าน",
                                                  evidenceRequired: "exit code 0")],
                   deliverableType: "โค้ด"),
    ])
}

private func registry(_ specialist: any Specialist) -> WorkspaceTeams {
    WorkspaceTeams { scope in
        TeamOrchestrator(router: ModelRouter(executors: []),
                         specialists: [.engineer: specialist],
                         scope: scope)
    }
}

/// Waits for the lead to actually be working, rather than assuming a `Task`
/// that was created has run. A bounded wait: a hang here is a failure, not a
/// test that sits forever.
private func waitUntilBusy(_ team: TeamOrchestrator) async -> Bool {
    for _ in 0..<2_000 {
        if await team.isBusy { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

@Suite("One lead per workspace (P21.2)")
struct WorkspaceTeamsTests {

    @Test("the same workspace gets the same lead, a different one gets its own")
    func oneLeadPerWorkspace() async {
        let teams = registry(GatedSpecialist())
        let first = await teams.team(for: projectA)
        let again = await teams.team(for: projectA)
        let other = await teams.team(for: projectB)

        #expect(first === again, "a second look at one workspace built a second lead")
        #expect(first !== other, "two workspaces shared one lead — this is the P21.2 bug")
        #expect(await first.currentScope == projectA)
        #expect(await other.currentScope == projectB)
    }

    @Test("work started in one project keeps running while another is opened")
    func switchingTabsDoesNotMoveRunningWork() async {
        let specialist = GatedSpecialist()
        let teams = registry(specialist)
        let a = await teams.team(for: projectA)

        // Project A starts working.
        let run = Task { await a.run(goal: "แก้เทส", plan: plan("a1")) }
        #expect(await waitUntilBusy(a), "the assignment never started")

        // The person switches to project B and works there. This is the whole
        // of the Done-when: with one shared lead, opening B either re-pointed
        // the lead mid-run — splitting A's ledger across two projects — or was
        // refused, leaving B filing its rows under A.
        let b = await teams.team(for: projectB)
        #expect(await b.currentScope == projectB)
        #expect(await a.currentScope == projectA, "A's run was re-pointed at another project")
        #expect(await a.isBusy, "A's work stopped because another tab was opened")

        // …and back to A, where the same lead is still holding the same run.
        #expect(await teams.team(for: projectA) === a)

        await specialist.release()
        let delivered = await run.value
        #expect(delivered.count == 1)
        #expect(await a.entries.first?.passed == true)
        #expect(await a.isBusy == false)
    }

    @Test("closing a tab does not let go of a lead that is still working")
    func releaseRefusesWhileBusy() async {
        let specialist = GatedSpecialist()
        let teams = registry(specialist)
        let a = await teams.team(for: projectA)
        let run = Task { await a.run(goal: "แก้เทส", plan: plan("a1")) }
        #expect(await waitUntilBusy(a), "the assignment never started")

        #expect(await teams.release(projectA) == false, "let go of a lead mid-run")
        #expect(await teams.isOpen(projectA), "the running workspace was dropped")
        #expect(await teams.team(for: projectA) === a,
                "reopening the tab built a second lead over live work")

        await specialist.release()
        _ = await run.value

        // Finished: now it may be let go, and the next open is a fresh lead.
        #expect(await teams.release(projectA) == true)
        #expect(await teams.isOpen(projectA) == false)
        #expect(await teams.team(for: projectA) !== a)
    }

    @Test("an idle workspace is let go when its tab closes")
    func releaseDropsIdleWorkspaces() async {
        let teams = registry(GatedSpecialist())
        _ = await teams.team(for: projectA)
        _ = await teams.team(for: projectB)

        #expect(await teams.release(projectB) == true)
        #expect(await teams.openScopes == [projectA])
        // Releasing something that was never open is not an error: closing a
        // tab that never had a team on it is an ordinary thing to do.
        #expect(await teams.release(projectB) == true)
    }
}
