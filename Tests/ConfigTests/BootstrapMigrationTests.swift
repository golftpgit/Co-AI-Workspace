import Testing
import Foundation
import AgentKit
@testable import Config

// ─────────────────────────────────────────────────────────────
// Migrating the bootstrap file (ARCHITECTURE §15, P9.2 / v1 bug D5).
//
// Every test here is about somebody's settings surviving. The Done-when is
// "an old config loads without losing what was in it", and the reason it needs
// a test is that the previous behaviour was the opposite in the most ordinary
// case there is: a file written before `schemaVersion` existed could not be
// decoded, took the repair path, and had defaults written over it.
// ─────────────────────────────────────────────────────────────

private func workspace() -> AppPaths {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "coai-config-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AppPaths(root: root)
}

/// Writes a plist by hand, which is the only way to produce the shape an older
/// version wrote — the current encoder cannot.
private func writePlist(_ pairs: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: pairs,
                                                  format: .xml, options: 0)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url)
}

@Suite("Bootstrap migration")
struct BootstrapMigrationTests {

    /// **The Done-when.** A file from before versioning, with a real endpoint
    /// in it, and the endpoint is still there afterwards.
    @Test("a config written before schemaVersion existed keeps its settings")
    func versionZeroFileIsMigratedNotDiscarded() throws {
        let paths = workspace()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writePlist([
            "surrealPort": 18_000,
            "searxngPort": 18_080,
            "logLevel": "debug",
            "selfHostedEndpoint": "http://127.0.0.1:1234/v1",
            "selfHostedModel": "qwen3-9b",
            "localModel": "Qwen3-VL-4B",
            "modelQuotaGigabytes": 30,
        ], to: paths.bootstrapFile)

        let store = BootstrapStore(paths: paths)
        let (config, outcome) = try store.load()

        #expect(outcome == .migrated(from: 0, steps: [1]))
        // Nothing the person set was dropped.
        #expect(config.logLevel == .debug)
        #expect(config.localModel == "Qwen3-VL-4B")
        #expect(config.modelQuotaGigabytes == 30)
        // And the endpoint moved into the registry rather than vanishing.
        let endpoint = try #require(config.endpointRegistry?.endpoints.first)
        #expect(endpoint.baseURL == "http://127.0.0.1:1234/v1")
        #expect(endpoint.model == "qwen3-9b")
        #expect(endpoint.kind == .selfHosted)

        // Written back at the current version, so the migration happens once.
        let (again, secondOutcome) = try store.load()
        #expect(secondOutcome == .loaded)
        #expect(again.schemaVersion == BootstrapConfig.currentSchemaVersion)
        #expect(again.endpointRegistry?.endpoints.count == 1)
    }

    /// The old shape is still readable afterwards. A person who has to check
    /// what their endpoint was should be able to.
    @Test("migrating keeps a copy of the file it replaced")
    func migrationLeavesABackup() throws {
        let paths = workspace()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writePlist(["surrealPort": 18_000, "searxngPort": 18_080,
                        "logLevel": "info",
                        "selfHostedEndpoint": "http://example.invalid/v1",
                        "selfHostedModel": "m"], to: paths.bootstrapFile)

        let store = BootstrapStore(paths: paths)
        _ = try store.load()

        let backup = store.backupFile(suffix: "v0")
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
        let text = try String(contentsOf: backup, encoding: .utf8)
        #expect(text.contains("http://example.invalid/v1"))
    }

    /// Downgrade. Overwriting here would take the settings away from the newer
    /// version too, which is the version they will go back to.
    @Test("a file from a newer version is left exactly as it was")
    func newerFilesAreNotTouched() throws {
        let paths = workspace()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writePlist(["schemaVersion": 99,
                        "surrealPort": 19_000,
                        "searxngPort": 19_080,
                        "logLevel": "warning",
                        "somethingFromTheFuture": "keep me"], to: paths.bootstrapFile)
        let before = try Data(contentsOf: paths.bootstrapFile)

        let (config, outcome) = try BootstrapStore(paths: paths).load()

        #expect(outcome == .newerThanExpected(version: 99))
        #expect(!outcome.rewroteFile)
        // Defaults for this session…
        #expect(config.surrealPort == BootstrapConfig.default.surrealPort)
        // …and the file untouched, including the field this build knows nothing
        // about.
        #expect(try Data(contentsOf: paths.bootstrapFile) == before)
        #expect(try String(contentsOf: paths.bootstrapFile, encoding: .utf8)
            .contains("keep me"))
    }

    @Test("an unreadable file is replaced, but a copy of it is kept")
    func corruptFilesAreBackedUp() throws {
        let paths = workspace()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try "this is not a plist".write(to: paths.bootstrapFile, atomically: true, encoding: .utf8)

        let store = BootstrapStore(paths: paths)
        let (config, outcome) = try store.load()

        guard case .repairedInvalid = outcome else {
            Issue.record("ควรเป็น repairedInvalid: \(outcome)")
            return
        }
        #expect(config == .default)
        let backup = store.backupFile(suffix: "unreadable")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "this is not a plist")
    }

    /// A version bumped with no migration written is a settings loss waiting
    /// for the next release. Checked mechanically rather than remembered.
    @Test("every schema version between 1 and the current one has a migration step")
    func noVersionIsUnhandled() {
        #expect(BootstrapMigration.missingSteps.isEmpty,
                "ไม่มี migration สำหรับเวอร์ชัน: \(BootstrapMigration.missingSteps)")
    }

    /// Migration must not invent an endpoint for somebody who never had one,
    /// and must not overwrite a registry that already exists.
    @Test("migration adds nothing when there was nothing, and does not overwrite a registry")
    func migrationIsConservative() {
        var empty = BootstrapConfig(schemaVersion: 0, surrealPort: 18_000,
                                    searxngPort: 18_080, logLevel: .info)
        let migratedEmpty = BootstrapMigration.migrate(empty).config
        #expect(migratedEmpty.endpointRegistry == nil)
        #expect(migratedEmpty.schemaVersion == BootstrapConfig.currentSchemaVersion)

        var registry = EndpointRegistry()
        registry.upsert(InferenceEndpoint(id: "mine", name: "Mine",
                                          baseURL: "http://mine.invalid/v1",
                                          model: "m", kind: .selfHosted))
        empty.endpointRegistry = registry
        empty.selfHostedEndpoint = "http://old.invalid/v1"
        empty.selfHostedModel = "old"
        let migrated = BootstrapMigration.migrate(empty).config
        #expect(migrated.endpointRegistry?.endpoints.map(\.id) == ["mine"])
    }

    /// A file at the current version is loaded and left alone — the common
    /// case, and the one a migration bug would break every launch.
    @Test("a current file is loaded untouched")
    func currentFilesAreLeftAlone() throws {
        let paths = workspace()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = BootstrapStore(paths: paths)
        var config = BootstrapConfig.default
        config.localModel = "some-model"
        try store.save(config)
        let before = try Data(contentsOf: paths.bootstrapFile)

        let (loaded, outcome) = try store.load()
        #expect(outcome == .loaded)
        #expect(loaded.localModel == "some-model")
        #expect(try Data(contentsOf: paths.bootstrapFile) == before)
    }
}
