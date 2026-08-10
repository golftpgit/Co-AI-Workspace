import Testing
import Foundation
import AgentKit
import Config
import Sidecar
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// Regression cover for the scope-storage decision.
//
// Scope used to be persisted as one composite string ("project/alpha").
// That broke in a way worth remembering: SurrealDB v3 re-types *bound*
// strings by shape, and a bound string containing `/` produces NO RPC
// response at all — the caller simply hangs until its timeout. `central`
// and `policy` were unaffected, so the bug looked like a random flake.
//
// The fix (Persistence.ScopeColumns) is to bind primitives only. These
// tests hold that line: every Scope shape must round-trip, and filtering
// must not leak across scopes.
// ─────────────────────────────────────────────────────────────

@Suite("Scope column storage", .serialized)
struct ScopeColumnTests {
    private func makeStore(port: Int) async throws
        -> (store: ConversationStore, teardown: @Sendable () async -> Void)? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appending(path: "vendor/helpers/surreal")
        guard FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)) else {
            Issue.record("skipped: vendor/helpers/surreal not present")
            return nil
        }

        let paths = AppPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coai-scope-\(UUID().uuidString)"))
        try paths.createDirectories()
        let manager = SidecarManager(paths: paths)
        try await manager.start(SidecarSpec(
            id: "surreal", executableURL: binary,
            arguments: ["start", "--user", "root", "--pass", "root",
                        "--bind", "127.0.0.1:\(port)",
                        "surrealkv://\(paths.databaseDirectory.path(percentEncoded: false))"],
            healthURL: URL(string: "http://127.0.0.1:\(port)/health"),
            readinessTimeout: .seconds(30)))

        let client = SurrealClient(url: URL(string: "ws://127.0.0.1:\(port)/rpc")!)
        try await client.connect()
        try await client.bootstrap(user: "root", password: "root")

        return (ConversationStore(client: client), {
            await client.close()
            await manager.stopAll()
            try? FileManager.default.removeItem(at: paths.root)
        })
    }

    @Test("every scope shape round-trips", .timeLimit(.minutes(2)))
    func allShapesRoundTrip() async throws {
        guard let (store, teardown) = try await makeStore(port: 18_450) else { return }
        defer { Task { await teardown() } }

        // Project ids deliberately include the characters that used to break
        // binding: dashes, dots and slashes must all survive as plain data.
        let scopes: [Scope] = [
            .central,
            .policy,
            .project(ProjectID("alpha")),
            .project(ProjectID("a-b-c")),
            .project(ProjectID("team/sub")),
            .project(ProjectID("2026.08")),
        ]

        for scope in scopes {
            let created = try await store.create(scope: scope, title: "s")
            #expect(created.scope == scope, "create lost the scope: \(scope)")

            let listed = try await store.list(scope: scope)
            #expect(listed.contains { $0.id == created.id },
                    "listing by \(scope) did not return the row just created")
        }
    }

    @Test("filtering does not leak across scopes", .timeLimit(.minutes(2)))
    func filteringIsExact() async throws {
        guard let (store, teardown) = try await makeStore(port: 18_451) else { return }
        defer { Task { await teardown() } }

        let a = Scope.project(ProjectID("alpha"))
        let b = Scope.project(ProjectID("beta"))
        _ = try await store.create(scope: a)
        _ = try await store.create(scope: a)
        _ = try await store.create(scope: b)
        _ = try await store.create(scope: .central)
        _ = try await store.create(scope: .policy)

        #expect(try await store.list(scope: a).count == 2)
        #expect(try await store.list(scope: b).count == 1)
        #expect(try await store.list(scope: .central).count == 1)
        #expect(try await store.list(scope: .policy).count == 1)
        #expect(try await store.list().count == 5)
        #expect(try await store.list(scope: a).allSatisfy { $0.scope == a })
    }
}
