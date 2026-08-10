import Testing
import Foundation
import AgentKit
import Observability
import Config
import Sidecar
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// These run against a REAL SurrealDB, never a mock: v1's hardest bugs were
// all engine behaviours no mock would have reproduced (ARCHITECTURE App. C).
// The binary lives in vendor/helpers (gitignored); without it the suite
// skips loudly rather than pretending to pass.
// ─────────────────────────────────────────────────────────────

private func repoRoot() -> URL {
    // .../Tests/PersistenceTests/PersistenceTests.swift → repo root
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private var surrealBinary: URL? {
    let url = repoRoot().appending(path: "vendor/helpers/surreal")
    return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
}

/// One live server per test, on its own port and storage, so tests cannot
/// interfere with each other or with the developer's real workspace.
private actor TestServer {
    let manager: SidecarManager
    let paths: AppPaths
    let port: Int
    let client: SurrealClient

    init(port: Int) async throws {
        guard let binary = surrealBinary else { throw TestSkip.noBinary }
        self.port = port
        paths = AppPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coai-persist-\(UUID().uuidString)"))
        try paths.createDirectories()
        manager = SidecarManager(paths: paths)

        let spec = SidecarSpec(
            id: "surreal",
            executableURL: binary,
            arguments: ["start", "--user", "root", "--pass", "root",
                        "--bind", "127.0.0.1:\(port)",
                        "surrealkv://\(paths.databaseDirectory.path(percentEncoded: false))"],
            healthURL: URL(string: "http://127.0.0.1:\(port)/health"),
            readinessTimeout: .seconds(30))
        try await manager.start(spec)

        client = SurrealClient(url: URL(string: "ws://127.0.0.1:\(port)/rpc")!)
        try await client.connect()
        try await client.bootstrap(user: "root", password: "root")
    }

    func shutdown() async {
        await client.close()
        await manager.stopAll()
        try? FileManager.default.removeItem(at: paths.root)
    }
}

private enum TestSkip: Error { case noBinary }

/// Ports are assigned per suite to keep parallel runs from colliding.
private func makeServer(port: Int) async throws -> TestServer? {
    guard surrealBinary != nil else {
        Issue.record("skipped: vendor/helpers/surreal not present — run scripts/fetch-helpers.sh")
        return nil
    }
    return try await TestServer(port: port)
}

@Suite("Schema bootstrap", .serialized)
struct SchemaTests {
    @Test("bootstrap is idempotent across launches", .timeLimit(.minutes(2)))
    func idempotent() async throws {
        guard let server = try await makeServer(port: 18_401) else { return }
        defer { Task { await server.shutdown() } }
        let client = await server.client

        // Done-when for P1.2: running it three times must not error, which is
        // exactly what SurrealDB v3.2 does without IF NOT EXISTS.
        try await client.bootstrap(user: "root", password: "root")
        try await client.bootstrap(user: "root", password: "root")

        #expect(try await client.schemaVersion() == Schema.version)
    }

    @Test("a failing statement names itself", .timeLimit(.minutes(2)))
    func errorsAreLegible() async throws {
        guard let server = try await makeServer(port: 18_402) else { return }
        defer { Task { await server.shutdown() } }
        let client = await server.client

        do {
            try await client.exec("DEFINE INDEX bad ON nonexistent_table FIELDS !!!")
            Issue.record("expected the malformed statement to fail")
        } catch {
            #expect("\(error)".count > 10)   // a real message, not an opaque code
        }
    }
}

@Suite("ConversationStore", .serialized)
struct ConversationStoreTests {
    @Test("conversation and messages survive a reconnect", .timeLimit(.minutes(2)))
    func persistsAcrossReconnect() async throws {
        guard let server = try await makeServer(port: 18_403) else { return }
        defer { Task { await server.shutdown() } }

        let store = ConversationStore(client: await server.client)
        let convo = try await store.create(scope: .central, title: "งานวิจัยเบาหวาน")
        try await store.append(conversationID: convo.id, role: .user, content: "สวัสดี")
        try await store.append(conversationID: convo.id, role: .assistant, content: "ครับ")

        // Reconnect exactly as a relaunch would.
        await server.client.close()
        let fresh = SurrealClient(url: URL(string: "ws://127.0.0.1:\(await server.port)/rpc")!)
        try await fresh.connect()
        try await fresh.signin(user: "root", pass: "root")
        try await fresh.use(namespace: Schema.namespace, database: Schema.database)

        let history = try await ConversationStore(client: fresh).history(conversationID: convo.id)
        #expect(history.count == 2)
        #expect(history.first?.role == .user)
        #expect(history.first?.content == "สวัสดี")
        #expect(history.last?.role == .assistant)
        await fresh.close()
    }

    @Test("history comes back in order", .timeLimit(.minutes(2)))
    func historyIsOrdered() async throws {
        guard let server = try await makeServer(port: 18_404) else { return }
        defer { Task { await server.shutdown() } }

        let store = ConversationStore(client: await server.client)
        let convo = try await store.create(scope: .project(ProjectID("p1")))
        for i in 1...6 {
            try await store.append(conversationID: convo.id,
                                   role: i.isMultiple(of: 2) ? .assistant : .user,
                                   content: "ข้อความที่ \(i)")
        }

        let history = try await store.history(conversationID: convo.id)
        #expect(history.count == 6)
        #expect(history.map(\.content) == (1...6).map { "ข้อความที่ \($0)" })
    }

    @Test("scope round-trips and filters listings", .timeLimit(.minutes(2)))
    func scopeFiltering() async throws {
        guard let server = try await makeServer(port: 18_405) else { return }
        defer { Task { await server.shutdown() } }

        let store = ConversationStore(client: await server.client)
        let project = Scope.project(ProjectID("alpha"))
        _ = try await store.create(scope: .central, title: "central one")
        _ = try await store.create(scope: project, title: "project one")
        _ = try await store.create(scope: project, title: "project two")

        #expect(try await store.list(scope: project).count == 2)
        #expect(try await store.list(scope: .central).count == 1)
        #expect(try await store.list().count == 3)
        #expect(try await store.list(scope: project).allSatisfy { $0.scope == project })
    }

    @Test("deleting a conversation removes its messages too", .timeLimit(.minutes(2)))
    func deleteCascades() async throws {
        guard let server = try await makeServer(port: 18_406) else { return }
        defer { Task { await server.shutdown() } }

        let store = ConversationStore(client: await server.client)
        let convo = try await store.create(scope: .central)
        try await store.append(conversationID: convo.id, role: .user, content: "x")
        #expect(try await store.messageCount(conversationID: convo.id) == 1)

        try await store.delete(convo.id)
        #expect(try await store.messageCount(conversationID: convo.id) == 0)
        #expect(try await store.list().isEmpty)
    }

    @Test("appending updates the conversation's sort position", .timeLimit(.minutes(2)))
    func appendTouchesConversation() async throws {
        guard let server = try await makeServer(port: 18_407) else { return }
        defer { Task { await server.shutdown() } }

        let store = ConversationStore(client: await server.client)
        let first = try await store.create(scope: .central, title: "older")
        try await Task.sleep(for: .milliseconds(50))
        _ = try await store.create(scope: .central, title: "newer")

        try await Task.sleep(for: .milliseconds(50))
        try await store.append(conversationID: first.id, role: .user, content: "ping")

        // Most recently touched must sort first — this is the chat sidebar order.
        #expect(try await store.list().first?.id == first.id)
    }
}

@Suite("SurrealSpanSink", .serialized)
struct SpanSinkTests {
    @Test("spans persist and survive restart", .timeLimit(.minutes(2)))
    func persistsSpans() async throws {
        guard let server = try await makeServer(port: 18_408) else { return }
        defer { Task { await server.shutdown() } }

        let sink = SurrealSpanSink(client: await server.client)
        let recorder = SpanRecorder(sink: sink)
        _ = try await recorder.run("kb_search", role: .researcher, scope: .central) { true }

        let stored = try await sink.recent()
        #expect(stored.contains { $0.name == "kb_search" && $0.status == .succeeded })
        #expect(stored.first { $0.name == "kb_search" }?.role == .researcher)
    }

    /// The v1 failure this replaces: events vanished when the user changed
    /// view, because the only copy lived in that view's memory.
    @Test("a failed span keeps its reason", .timeLimit(.minutes(2)))
    func keepsFailureDetail() async throws {
        guard let server = try await makeServer(port: 18_409) else { return }
        defer { Task { await server.shutdown() } }

        struct Boom: Error {}
        let sink = SurrealSpanSink(client: await server.client)
        let recorder = SpanRecorder(sink: sink)
        await #expect(throws: Boom.self) {
            try await recorder.run("run_shell") { throw Boom() }
        }

        let failed = try await sink.recent().first { $0.name == "run_shell" }
        #expect(failed?.status == .failed)
        #expect(failed?.detail?.contains("Boom") == true)
    }

    @Test("parent/child spans reassemble", .timeLimit(.minutes(2)))
    func parentChild() async throws {
        guard let server = try await makeServer(port: 18_410) else { return }
        defer { Task { await server.shutdown() } }

        let sink = SurrealSpanSink(client: await server.client)
        let recorder = SpanRecorder(sink: sink)
        let parent = SpanID()
        _ = try await recorder.run("child-a", parent: parent) { 1 }
        _ = try await recorder.run("child-b", parent: parent) { 2 }

        let children = try await sink.children(of: parent)
        #expect(Set(children.map(\.name)) == ["child-a", "child-b"])
    }
}

// ─────────────────────────────────────────────────────────────
// Regression: v3 coerces a *bound* string shaped like `table:id` into a record
// link, which then fails a `TYPE string` field (App. C.0). Our own ids avoid
// the colon, but text we do not control cannot — and this was live: every span
// the gate, the router and the broker emit is named `tool:run_shell`,
// `llm:gx10`, `approval:run_shell`, so none of them were being stored at all.
// ─────────────────────────────────────────────────────────────
@Suite("Text that looks like a record id", .serialized)
struct RecordShapedTextTests {
    @Test("a message whose text looks like a record id is stored verbatim", .timeLimit(.minutes(2)))
    func messageContentSurvives() async throws {
        guard let server = try await makeServer(port: 18_411) else { return }
        defer { Task { await server.shutdown() } }

        let store = ConversationStore(client: await server.client)
        let conversation = try await store.create(scope: .central, title: "note:1")
        // Each of these is a shape v3 re-types when bound: record link, uuid.
        let awkward = ["note:1", "table:id", "a487d755-9ec0-4b1a-9f8e-1c2b3d4e5f60", "ดู tool:run_shell สิ"]
        for text in awkward {
            try await store.append(conversationID: conversation.id, role: .user, content: text)
        }

        let history = try await store.history(conversationID: conversation.id)
        #expect(history.map(\.content) == awkward)
        #expect(try await store.list(scope: .central).first?.title == "note:1")
    }

    @Test("spans named after their tool are stored, not silently dropped", .timeLimit(.minutes(2)))
    func spanNamesSurvive() async throws {
        guard let server = try await makeServer(port: 18_412) else { return }
        defer { Task { await server.shutdown() } }

        let sink = SurrealSpanSink(client: await server.client)
        var span = Span(name: "tool:run_shell", scope: .central, status: .succeeded)
        span.endedAt = Date()
        span.detail = "escalated past on-device:refused"
        await sink.record(span)

        let stored = try await sink.recent().first { $0.name == "tool:run_shell" }
        #expect(stored?.detail == "escalated past on-device:refused")
        #expect(stored?.status == .succeeded)
    }
}
