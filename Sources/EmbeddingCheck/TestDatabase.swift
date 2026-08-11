import Foundation
import Config
import Sidecar
import Persistence

// ─────────────────────────────────────────────────────────────
// A throwaway SurrealDB for the screen flows: its own port, its own directory,
// torn down afterwards — the same shape the persistence tests use, because
// checking storage against anything but the real engine is how v1's hardest
// bugs stayed hidden (ARCHITECTURE App. C).
// ─────────────────────────────────────────────────────────────

struct TestDatabase {
    let manager: SidecarManager
    let client: SurrealClient
    private let paths: AppPaths

    static func start(port: Int) async throws -> TestDatabase? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = root.appending(path: "vendor/helpers/surreal")
        guard FileManager.default.isExecutableFile(
            atPath: binary.path(percentEncoded: false)) else { return nil }

        let paths = AppPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coai-flow-db-\(UUID().uuidString)"))
        try paths.createDirectories()

        let manager = SidecarManager(paths: paths)
        try await manager.start(SidecarSpec(
            id: "surreal",
            executableURL: binary,
            arguments: ["start", "--user", "root", "--pass", "root",
                        "--bind", "127.0.0.1:\(port)",
                        "surrealkv://\(paths.databaseDirectory.path(percentEncoded: false))"],
            healthURL: URL(string: "http://127.0.0.1:\(port)/health")))

        let client = SurrealClient(url: URL(string: "ws://127.0.0.1:\(port)/rpc")!)
        try await client.connect()
        // Connect, authenticate, select the namespace and apply the schema —
        // the same call the app makes on every launch.
        try await client.bootstrap(user: "root", password: "root")

        return TestDatabase(manager: manager, client: client, paths: paths)
    }

    func stop() async {
        await client.close()
        await manager.stopAll()
        try? FileManager.default.removeItem(at: paths.root)
    }
}
