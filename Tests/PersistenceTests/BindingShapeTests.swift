import Testing
import Foundation
import AgentKit
import Config
import Sidecar
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// Characterises which *bound string shapes* SurrealDB v3.2 mishandles.
// This matters well beyond scope keys: file paths, URLs and record-like
// text all have to survive binding, and a silent hang is the worst
// possible failure mode. Findings are mirrored in ARCHITECTURE App. C.0.
// ─────────────────────────────────────────────────────────────

@Suite("Bound string shapes", .serialized)
struct BindingShapeTests {
    @Test("characterise every shape we will need to store", .timeLimit(.minutes(3)))
    func shapes() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appending(path: "vendor/helpers/surreal")
        guard FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)) else {
            Issue.record("skipped: vendor/helpers/surreal not present")
            return
        }

        let paths = AppPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coai-shapes-\(UUID().uuidString)"))
        try paths.createDirectories()
        let manager = SidecarManager(paths: paths)
        try await manager.start(SidecarSpec(
            id: "surreal", executableURL: binary,
            arguments: ["start", "--user", "root", "--pass", "root",
                        "--bind", "127.0.0.1:18452",
                        "surrealkv://\(paths.databaseDirectory.path(percentEncoded: false))"],
            healthURL: URL(string: "http://127.0.0.1:18452/health"),
            readinessTimeout: .seconds(30)))
        let client = SurrealClient(url: URL(string: "ws://127.0.0.1:18452/rpc")!)
        try await client.connect()
        try await client.bootstrap(user: "root", password: "root")
        defer {
            Task { await client.close(); await manager.stopAll()
                   try? FileManager.default.removeItem(at: paths.root) }
        }

        try await client.exec("DEFINE TABLE IF NOT EXISTS probe SCHEMALESS")

        let shapes: [(String, String)] = [
            ("plain", "hello"),
            ("dashed", "a-b-c"),
            ("dotted", "2026.08.10"),
            ("underscored", "team__sub"),
            ("colon", "project:alpha"),
            ("uuid", UUID().uuidString),
            ("one slash", "team/sub"),
            ("leading slash", "/Users/me/file.txt"),
            ("url", "https://example.com/a/b"),
            ("double slash", "a//b"),
            ("thai", "งานวิจัยเบาหวาน"),
            ("spaces", "hello world"),
        ]

        var results: [String: String] = [:]
        for (label, value) in shapes {
            do {
                let r = try await client.query(
                    "CREATE probe CONTENT { label: $label, payload: $value }",
                    vars: ["label": label, "value": value],
                    timeout: 5)
                if r.first?.ok == true {
                    // Also confirm it reads back byte-identical.
                    let back = try await client.query(
                        "SELECT payload FROM probe WHERE label = $label", vars: ["label": label], timeout: 5)
                    let stored = back.first?.rows.first?["payload"]?.stringValue
                    results[label] = stored == value ? "ok" : "altered: \(stored ?? "nil")"
                } else {
                    results[label] = "rejected"
                }
            } catch {
                results[label] = "\(error)"
            }
        }

        for (label, _) in shapes {
            print("  \(label.padding(toLength: 16, withPad: " ", startingAt: 0)) → \(results[label] ?? "?")")
        }

        // Shapes the system must be able to store. Any regression here is a
        // real data-loss bug, so they are assertions, not observations.
        for label in ["plain", "dashed", "dotted", "underscored", "thai", "spaces",
                      "one slash", "leading slash", "url", "double slash", "colon"] {
            #expect(results[label] == "ok", "\(label): \(results[label] ?? "?")")
        }

        // Known and deliberately not "fixed": a UUID-shaped string is stored as
        // a UUID value and reads back normalised, so it is not byte-identical.
        // Ids therefore use AgentKit.OpaqueID, which cannot be re-typed.
        #expect(results["uuid"]?.hasPrefix("altered") == true,
                "UUID coercion changed behaviour — revisit OpaqueID: \(results["uuid"] ?? "?")")

        // The same coercion on the *other* side of a statement, which is where
        // it actually cost us: a UUID-shaped id bound into a comparison is a
        // UUID value and never equals the string that was stored. Every UPSERT
        // then matched nothing, tried to create, was refused by the unique
        // index, and the row kept its first values — a task ledger that
        // recorded attempt 1 of a run that took three and escalated.
        let matchable = UUID().uuidString
        try await client.exec(
            "CREATE probe CONTENT { label: type::string($l), payload: type::string($v) }",
            vars: ["l": "where-probe", "v": matchable])

        let bare = try await client.query("SELECT payload FROM probe WHERE payload = $v",
                                          vars: ["v": matchable], timeout: 5)
        let pinned = try await client.query(
            "SELECT payload FROM probe WHERE payload = type::string($v)",
            vars: ["v": matchable], timeout: 5)

        #expect(bare.first?.rows.isEmpty == true,
                "an unpinned UUID comparison now matches — every id comparison in the persistence layer is wrapped in type::string() because it did not")
        #expect(pinned.first?.rows.count == 1,
                "type::string() no longer rescues the comparison: \(pinned.first?.rows.count ?? -1)")
    }
}
