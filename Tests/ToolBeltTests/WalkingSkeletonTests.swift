import Testing
import Foundation
import AgentKit
import Observability
import Config
import Sidecar
import Persistence
import LLMProviders
import CoreEngine
import Execution
import ToolBelt

// ─────────────────────────────────────────────────────────────
// P1's Done-when in one test: a turn that calls a tool, waits for a human on
// a channel, runs a real command, and leaves the whole thing in the database.
//
// Everything is real except the model — a real SurrealDB, the real hook chain,
// the real broker, a real process. The model is scripted only so the turn's
// *shape* is deterministic; which words a model picks is not what P1 promises.
// ─────────────────────────────────────────────────────────────

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private var surrealBinary: URL? {
    let url = repoRoot().appending(path: "vendor/helpers/surreal")
    return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
}

private actor TestServer {
    let manager: SidecarManager
    let paths: AppPaths
    let client: SurrealClient

    init(port: Int, binary: URL) async throws {
        paths = AppPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coai-skeleton-\(UUID().uuidString)"))
        try paths.createDirectories()
        manager = SidecarManager(paths: paths)
        try await manager.start(SidecarSpec(
            id: "surreal",
            executableURL: binary,
            arguments: ["start", "--user", "root", "--pass", "root",
                        "--bind", "127.0.0.1:\(port)",
                        "surrealkv://\(paths.databaseDirectory.path(percentEncoded: false))"],
            healthURL: URL(string: "http://127.0.0.1:\(port)/health"),
            readinessTimeout: .seconds(30)))

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

/// Asks for `run_shell` on the first round, then answers.
private struct ScriptedModel: LLMExecutor {
    let identifier = "scripted"
    let tier: ModelTier = .selfHosted
    let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: true,
                                       supportsStructuredOutput: true,
                                       supportsStreaming: true, supportsVision: false)
    let command: String
    let rounds: Rounds

    func isAvailable() async -> Bool { true }

    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await rounds.first() {
                    continuation.yield(.textDelta("ขอรันคำสั่งดูก่อนนะครับ"))
                    continuation.yield(.toolCall(.init(
                        id: "call_1", name: "run_shell",
                        argumentsJSON: "{\"command\":\"\(command)\"}")))
                } else {
                    continuation.yield(.textDelta("รันเสร็จแล้ว ผลอยู่ด้านบน"))
                }
                continuation.yield(.finished(reason: "stop"))
                continuation.finish()
            }
        }
    }
}

private actor Rounds {
    private var count = 0
    func first() -> Bool { defer { count += 1 }; return count == 0 }
}

@Suite("The walking skeleton, end to end", .serialized)
struct WalkingSkeletonTests {
    @Test("a turn with a tool call and an approval completes and is fully persisted",
          .timeLimit(.minutes(2)))
    func fullTurn() async throws {
        guard let binary = surrealBinary else {
            Issue.record("skipped: vendor/helpers/surreal not present")
            return
        }
        let server = try await TestServer(port: 18_631, binary: binary)
        defer { Task { await server.shutdown() } }

        let client = await server.client
        let spans = SurrealSpanSink(client: client)
        let conversations = ConversationStore(client: client)

        // A working directory the command may write to, and a marker file that
        // proves the shell really ran rather than the tool merely reporting so.
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coai-skeleton-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let marker = workspace.appending(path: "proof.txt")

        let broker = ApprovalBroker(spanSink: spans)
        let gateway = ToolGateway(approver: broker, spanSink: spans,
                                  modes: OperatingModes(autonomy: .balanced))
        await gateway.register(RunShellTool(registry: ProcessRegistry(spanSink: spans)))

        // A channel standing in for the GUI: it is shown the request and
        // answers through the broker, exactly as the approval banner does.
        let seen = SeenRequests()
        await broker.subscribe(CallbackChannel(
            id: ChannelID("test-gui"),
            onPresent: { request in
                await seen.record(request)
                await broker.submit(request.id, decision: .approved, from: ChannelID("test-gui"))
            }))

        let router = ModelRouter(executors: [ScriptedModel(command: "echo ผ่านครบวงจร > proof.txt; echo done",
                                                           rounds: Rounds())],
                                 spanSink: spans)
        let runner = AgentTurnRunner(router: router, gateway: gateway,
                                     transcript: conversations, spanSink: spans)

        let conversation = try await conversations.create(scope: .central, title: "skeleton")
        var events: [TurnEvent] = []
        for await event in await runner.run(userText: "ลองรันคำสั่งให้หน่อย",
                                            conversationID: conversation.id,
                                            scope: .central,
                                            workingDirectory: workspace) {
            events.append(event)
        }

        // 1 — a human was actually asked, and the request described the command.
        let requests = await seen.all
        #expect(requests.count == 1)
        #expect(requests.first?.toolName == "run_shell")
        #expect(requests.first?.risk == .high)
        #expect(requests.first?.detail.contains("proof.txt") == true)

        // 2 — the command really ran.
        #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
        #expect(try String(contentsOf: marker, encoding: .utf8).contains("ผ่านครบวงจร"))

        // 3 — the turn finished rather than stalling on the approval.
        #expect(events.contains { if case .finished = $0 { return true }; return false })

        // 4 — the whole turn is in the database, in order, readable after a
        //     reload: user → assistant → tool → assistant.
        let history = try await conversations.history(conversationID: conversation.id)
        #expect(history.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(history[0].content == "ลองรันคำสั่งให้หน่อย")
        #expect(history[2].content.contains("run_shell"))
        #expect(history[2].content.contains("[exit 0"))

        // 5 — and so is the trail: the turn, the approval and the tool call.
        let recorded = try await spans.recent(limit: 100)
        #expect(recorded.contains { $0.name == "turn" })
        #expect(recorded.contains { $0.name == "approval:run_shell" && $0.status == .succeeded })
        let toolSpan = try #require(recorded.first { $0.name == "tool:run_shell" && $0.status == .succeeded })
        let turnSpan = try #require(recorded.first { $0.name == "turn" })
        #expect(toolSpan.parent == turnSpan.id)
    }
}

private actor SeenRequests {
    private(set) var all: [ApprovalRequest] = []
    func record(_ request: ApprovalRequest) { all.append(request) }
}
