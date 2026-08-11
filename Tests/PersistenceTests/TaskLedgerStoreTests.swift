import Testing
import Foundation
import AgentKit
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// §2.2 wants "who is doing what, and how did it go" answerable at any time —
// including after the app was closed, which is when a person most often asks.
// ─────────────────────────────────────────────────────────────

private func row(_ id: String, role: Role = .engineer, attempts: Int = 1,
                 passed: Bool = true, findings: [String] = [],
                 summary: String? = "เสร็จแล้ว") -> LedgerRow {
    LedgerRow(assignmentID: id, role: role, goal: "แก้เทสให้ผ่าน", attempts: attempts,
              passed: passed, findings: findings, summary: summary)
}

@Suite("Task ledger store", .serialized)
struct TaskLedgerStoreTests {
    @Test("a finished task is readable after a restart", .timeLimit(.minutes(2)))
    func taskRoundTrips() async throws {
        guard let server = try await makeServer(port: 18_486) else { return }
        defer { Task { await server.shutdown() } }
        let store = TaskLedgerStore(client: await server.client)

        try await store.record(row("a1", attempts: 2), scope: .central)

        let rows = try await store.rows(scope: .central)
        #expect(rows.count == 1)
        #expect(rows.first?.role == .engineer)
        #expect(rows.first?.attempts == 2)
        #expect(rows.first?.passed == true)
        #expect(rows.first?.summary == "เสร็จแล้ว")
    }

    @Test("an escalation keeps the reasons it escalated for",
          .timeLimit(.minutes(2)))
    func findingsSurvive() async throws {
        guard let server = try await makeServer(port: 18_487) else { return }
        defer { Task { await server.shutdown() } }
        let store = TaskLedgerStore(client: await server.client)

        try await store.record(row("a2", attempts: 3, passed: false,
                                   findings: ["ไม่มีหลักฐานว่าได้รัน build/test จริง",
                                              "รันแล้วยังไม่ผ่าน"],
                                   summary: "ยืนยันว่าผ่าน"), scope: .central)

        let stored = try #require(try await store.rows(scope: .central).first)
        // "Escalated" with no reasons is what made v1's loops unreadable.
        #expect(stored.findings.count == 2)
        #expect(stored.findings.first?.contains("build/test") == true)
        // And the claim that was rejected is kept next to the reason it was.
        #expect(stored.summary == "ยืนยันว่าผ่าน")
    }

    @Test("updating a task in progress keeps one row", .timeLimit(.minutes(2)))
    func attemptsAreUpdatedInPlace() async throws {
        guard let server = try await makeServer(port: 18_488) else { return }
        defer { Task { await server.shutdown() } }
        let store = TaskLedgerStore(client: await server.client)

        try await store.record(row("a3", attempts: 1, passed: false), scope: .central)
        try await store.record(row("a3", attempts: 2, passed: false), scope: .central)
        try await store.record(row("a3", attempts: 2, passed: true), scope: .central)

        let rows = try await store.rows(scope: .central)
        #expect(rows.count == 1, "each attempt created a new row")
        #expect(rows.first?.attempts == 2)
        #expect(rows.first?.passed == true)
    }

    @Test("what still needs a person is one query away", .timeLimit(.minutes(2)))
    func unfinishedIsQueryable() async throws {
        guard let server = try await makeServer(port: 18_489) else { return }
        defer { Task { await server.shutdown() } }
        let store = TaskLedgerStore(client: await server.client)

        try await store.record(row("done", passed: true), scope: .central)
        try await store.record(row("stuck", attempts: 3, passed: false,
                                   findings: ["ยังไม่ผ่าน"]), scope: .central)

        // The list a user opens the app to see after leaving a run going.
        let unfinished = try await store.unfinished(scope: .central)
        #expect(unfinished.map(\.assignmentID) == ["stuck"])
    }

    @Test("a project's tasks stay in its project", .timeLimit(.minutes(2)))
    func scopesAreSeparate() async throws {
        guard let server = try await makeServer(port: 18_490) else { return }
        defer { Task { await server.shutdown() } }
        let store = TaskLedgerStore(client: await server.client)

        try await store.record(row("p1"), scope: .project(ProjectID("alpha")))
        #expect(try await store.rows(scope: .project(ProjectID("alpha"))).count == 1)
        #expect(try await store.rows(scope: .central).isEmpty)
    }
}
