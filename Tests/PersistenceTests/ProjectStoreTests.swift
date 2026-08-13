import Testing
import Foundation
import AgentKit
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// Projects against a real SurrealDB (ARCHITECTURE §19.1, P10.1).
//
// The second suite here is the actual Done-when for P10.1, and it is the one
// worth reading. Every table has carried `project_id` since P0 — but with the
// app writing the literal id "default" into all of them, nothing ever proved
// that two projects' work stays apart. "The column exists" and "the column is
// used" are the same distance apart as "there is code" and "there is a feature".
// ─────────────────────────────────────────────────────────────

@Suite("Project store", .serialized)
struct ProjectStoreTests {

    @Test("a project round-trips with its stage and its scope statement",
          .timeLimit(.minutes(2)))
    func roundTrips() async throws {
        guard let server = try await makeServer(port: 18_601) else { return }
        defer { Task { await server.shutdown() } }
        let store = ProjectStore(client: await server.client)

        var project = Project(name: "ความเครียดพยาบาล",
                              kind: .research,
                              brief: "วัดความชุกของภาวะหมดไฟ",
                              statement: ScopeStatement(
                                  inScope: ["ความชุกในพยาบาลวิชาชีพ"],
                                  outOfScope: ["การเปรียบเทียบข้ามวิชาชีพ"],
                                  assumptions: ["ตอบตามจริง"]))
        project.stage = .execution
        try await store.save(project)

        let loaded = try #require(try await store.project(project.id))
        #expect(loaded.name == project.name)
        #expect(loaded.kind == .research)
        #expect(loaded.stage == .execution)
        // The half that a `TYPE string` column would have quietly flattened.
        #expect(loaded.statement.outOfScope == ["การเปรียบเทียบข้ามวิชาชีพ"])
        #expect(loaded.statement.assumptions == ["ตอบตามจริง"])
    }

    @Test("saving twice updates the row instead of creating a second one",
          .timeLimit(.minutes(2)))
    func upsertsRatherThanDuplicates() async throws {
        guard let server = try await makeServer(port: 18_602) else { return }
        defer { Task { await server.shutdown() } }
        let store = ProjectStore(client: await server.client)

        var project = Project(name: "คัดกรองเบาหวาน")
        try await store.save(project)
        project.stage = .planning
        project.name = "คัดกรองเบาหวานในชุมชน"
        try await store.save(project)

        let all = try await store.all()
        #expect(all.count == 1)
        // The v3 quirk this project has been bitten by twice: an id bound
        // without `type::string` never matches its own column, every UPSERT
        // fails the unique index, and the row keeps its first values forever
        // (App. C.0). If that regressed, the stage below would still say
        // `initiation`.
        #expect(all.first?.stage == .planning)
        #expect(all.first?.name == "คัดกรองเบาหวานในชุมชน")
    }

    @Test("closed projects are still listed — they are the audit trail",
          .timeLimit(.minutes(2)))
    func closedProjectsSurvive() async throws {
        guard let server = try await makeServer(port: 18_603) else { return }
        defer { Task { await server.shutdown() } }
        let store = ProjectStore(client: await server.client)

        var ended = Project(name: "จบแล้ว")
        ended.stage = .closed
        ended.closure = .terminated
        ended.closedAt = Date()
        try await store.save(ended)

        let loaded = try #require(try await store.project(ended.id))
        #expect(!loaded.isOpen)
        #expect(loaded.closure == .terminated)
    }
}

@Suite("Two projects do not mix", .serialized)
struct ProjectIsolationTests {

    @Test("conversations and ledger rows stay inside their own project",
          .timeLimit(.minutes(3)))
    func scopedStoresStayApart() async throws {
        guard let server = try await makeServer(port: 18_604) else { return }
        defer { Task { await server.shutdown() } }
        let client = await server.client

        let projects = ProjectStore(client: client)
        let alpha = Project(name: "ความเครียดพยาบาล", kind: .research)
        let beta = Project(name: "คัดกรองเบาหวาน", kind: .analysis)
        try await projects.save(alpha)
        try await projects.save(beta)

        let conversations = ConversationStore(client: client)
        let inAlpha = try await conversations.create(scope: alpha.scope, title: "รอบวิเคราะห์ที่ 1")
        _ = try await conversations.create(scope: beta.scope, title: "ตั้งขอบเขต")
        _ = try await conversations.create(scope: .central, title: "คุยทั่วไป")

        let ledger = TaskLedgerStore(client: client)
        try await ledger.record(LedgerRow(assignmentID: OpaqueID.make(OpaqueID.assignment),
                                          role: .analyst, goal: "ตรวจความเที่ยง",
                                          attempts: 1, passed: false,
                                          findings: [], summary: nil),
                                scope: alpha.scope)
        try await ledger.record(LedgerRow(assignmentID: OpaqueID.make(OpaqueID.assignment),
                                          role: .researcher, goal: "ทบทวนวรรณกรรม",
                                          attempts: 1, passed: true,
                                          findings: [], summary: "เสร็จ"),
                                scope: beta.scope)

        // The Done-when, from both sides. Asking as one project must not
        // return the other's work, and must not return General's either.
        let alphaConversations = try await conversations.list(scope: alpha.scope)
        #expect(alphaConversations.map(\.id) == [inAlpha.id])

        let alphaRows = try await ledger.rows(scope: alpha.scope)
        let betaRows = try await ledger.rows(scope: beta.scope)
        #expect(alphaRows.count == 1)
        #expect(betaRows.count == 1)
        #expect(alphaRows.first?.role == .analyst)
        #expect(betaRows.first?.role == .researcher)
        #expect(alphaRows.first?.assignmentID != betaRows.first?.assignmentID)

        // And General is a third place, not "whatever is left over".
        #expect(try await conversations.list(scope: .central).count == 1)
    }
}
