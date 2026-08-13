import Testing
import Foundation
import AgentKit
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// The WBS on disk, and the link the ledger finally has (§19.6, P10.4).
//
// The second suite is the Done-when that matters: opening work from a leaf and
// finding, later, that the ledger row still points back at the leaf it was a
// promise about. Before this the ledger could say what happened and never
// against which promise.
// ─────────────────────────────────────────────────────────────

private let done = [Criterion(text: "รันแล้วผ่าน", evidenceRequired: "exit code 0")]

@Suite("Work package store", .serialized)
struct WorkPackageStoreTests {

    @Test("a package round-trips with its criteria and its place in the tree",
          .timeLimit(.minutes(2)))
    func roundTrips() async throws {
        guard let server = try await makeServer(port: 18_611) else { return }
        defer { Task { await server.shutdown() } }
        let store = WorkPackageStore(client: await server.client)
        let project = ProjectID("pj_alpha")

        let root = WorkPackage(projectID: project, title: "บทความวิจัย",
                               acceptanceCriteria: [])
        let leaf = WorkPackage(projectID: project, parent: root.id,
                               title: "สคริปต์ดึงข้อมูล",
                               deliverableType: "สคริปต์ + log",
                               scopeRef: "ความชุกในพยาบาลวิชาชีพ",
                               acceptanceCriteria: done, role: .engineer,
                               status: .inProgress, order: 1)
        try await store.save([root, leaf])

        let loaded = try await store.all(project: project)
        #expect(loaded.count == 2)
        let restored = try #require(loaded.first { $0.id == leaf.id })
        #expect(restored.parent == root.id)
        #expect(restored.acceptanceCriteria == done)
        #expect(restored.scopeRef == "ความชุกในพยาบาลวิชาชีพ")
        #expect(restored.role == .engineer)
        #expect(restored.status == .inProgress)
    }

    @Test("one project's plan is not another's", .timeLimit(.minutes(2)))
    func plansDoNotMix() async throws {
        guard let server = try await makeServer(port: 18_612) else { return }
        defer { Task { await server.shutdown() } }
        let store = WorkPackageStore(client: await server.client)

        try await store.save(WorkPackage(projectID: ProjectID("pj_a"), title: "ของ A",
                                         acceptanceCriteria: done))
        try await store.save(WorkPackage(projectID: ProjectID("pj_b"), title: "ของ B",
                                         acceptanceCriteria: done))

        #expect(try await store.all(project: ProjectID("pj_a")).map(\.title) == ["ของ A"])
        #expect(try await store.all(project: ProjectID("pj_b")).map(\.title) == ["ของ B"])
    }

    @Test("deleting a group takes its subtree, not just its own row",
          .timeLimit(.minutes(2)))
    func deleteTakesTheSubtree() async throws {
        guard let server = try await makeServer(port: 18_613) else { return }
        defer { Task { await server.shutdown() } }
        let store = WorkPackageStore(client: await server.client)
        let project = ProjectID("pj_tree")

        let root = WorkPackage(projectID: project, title: "บทความ", acceptanceCriteria: [])
        let group = WorkPackage(projectID: project, parent: root.id, title: "ข้อมูล",
                                acceptanceCriteria: [])
        let leaf = WorkPackage(projectID: project, parent: group.id, title: "สคริปต์",
                               acceptanceCriteria: done)
        try await store.save([root, group, leaf])

        try await store.delete(group.id, project: project)

        // Leaving the grandchild behind would produce exactly the "missing
        // parent" state the WBS reports — and it would be this code's fault
        // rather than the plan's.
        let remaining = try await store.all(project: project)
        #expect(remaining.map(\.id) == [root.id])
    }
}

@Suite("The ledger points back at the plan", .serialized)
struct LedgerWorkPackageTests {

    @Test("a round of work is readable from the leaf it was against",
          .timeLimit(.minutes(3)))
    func rowsAreQueryableByWorkPackage() async throws {
        guard let server = try await makeServer(port: 18_614) else { return }
        defer { Task { await server.shutdown() } }
        let client = await server.client
        let project = ProjectID("pj_link")
        let scope = Scope.project(project)

        let leaf = WorkPackage(projectID: project, title: "ความเที่ยงของมาตรวัด",
                               scopeRef: "ความตรงของมาตรวัด",
                               acceptanceCriteria: done, role: .analyst)
        try await WorkPackageStore(client: client).save(leaf)

        // The leaf becomes the assignment. Not a copy of its fields — the same
        // criteria, because `WorkPackage.assignment` is the only way across.
        let assignment = try #require(leaf.assignment())
        #expect(assignment.acceptanceCriteria == done)

        let ledger = TaskLedgerStore(client: client)
        try await ledger.record(LedgerRow(assignmentID: assignment.id, role: .analyst,
                                          goal: assignment.goal, attempts: 1, passed: false,
                                          findings: ["α = 0.61 ต่ำกว่าเกณฑ์"],
                                          summary: nil,
                                          acceptanceCriteria: done,
                                          deliverableType: assignment.deliverableType,
                                          workPackageID: leaf.id),
                                scope: scope)
        // A second round against the same leaf, and one against nothing —
        // work in General is a real state, not a defect.
        try await ledger.record(LedgerRow(assignmentID: OpaqueID.make(OpaqueID.assignment),
                                          role: .analyst, goal: "ลองใหม่", attempts: 2,
                                          passed: true, findings: [], summary: "α = 0.74",
                                          acceptanceCriteria: done,
                                          deliverableType: "ผลความเที่ยง",
                                          workPackageID: leaf.id),
                                scope: scope)
        try await ledger.record(LedgerRow(assignmentID: OpaqueID.make(OpaqueID.assignment),
                                          role: .researcher, goal: "อ่านเปเปอร์", attempts: 1,
                                          passed: true, findings: [], summary: nil),
                                scope: scope)

        let againstLeaf = try await ledger.rows(workPackage: leaf.id, scope: scope)
        #expect(againstLeaf.count == 2)
        #expect(againstLeaf.allSatisfy { $0.workPackageID == leaf.id })
        // Both directions: the ledger still holds everything, and the leaf
        // filter is a view of it rather than a separate record.
        #expect(try await ledger.rows(scope: scope).count == 3)
    }
}
