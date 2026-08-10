import Testing
import Foundation
@testable import Config

/// Each test gets a throwaway root so nothing touches the real workspace.
private func tempPaths() -> AppPaths {
    AppPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coai-tests-\(UUID().uuidString)"))
}

@Suite("AppPaths")
struct AppPathsTests {
    @Test("creates every managed directory and is idempotent")
    func createsDirectories() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let firstRun = try paths.createDirectories()
        #expect(firstRun.count == paths.managedDirectories.count)
        for dir in paths.managedDirectories {
            #expect(FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
        }

        // Done-when for P0.3: launching again must not fail or re-create.
        let secondRun = try paths.createDirectories()
        #expect(secondRun.isEmpty)
    }

    @Test("a wiped data directory self-heals on next launch")
    func selfHeals() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        try paths.createDirectories()
        try FileManager.default.removeItem(at: paths.root)
        #expect(!FileManager.default.fileExists(atPath: paths.root.path(percentEncoded: false)))

        let recreated = try paths.createDirectories()
        #expect(recreated.count == paths.managedDirectories.count)
    }
}

@Suite("BootstrapConfig validation")
struct BootstrapValidationTests {
    @Test("defaults are valid")
    func defaultsValid() throws {
        try BootstrapConfig.default.validate()
    }

    @Test("ports outside the allowed range are rejected", arguments: [0, 80, 1023, 65_536, -1])
    func rejectsBadPorts(port: Int) {
        var config = BootstrapConfig.default
        config.surrealPort = port
        #expect(throws: BootstrapError.self) { try config.validate() }
    }

    @Test("two sidecars cannot share a port")
    func rejectsDuplicatePorts() {
        var config = BootstrapConfig.default
        config.searxngPort = config.surrealPort
        #expect(throws: BootstrapError.duplicatePorts(config.surrealPort)) { try config.validate() }
    }
}

@Suite("BootstrapStore")
struct BootstrapStoreTests {
    @Test("first launch writes a default file")
    func createsDefault() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = BootstrapStore(paths: paths)

        let (config, outcome) = try store.load()
        #expect(outcome == .createdDefault)
        #expect(config == .default)
        #expect(FileManager.default.fileExists(atPath: paths.bootstrapFile.path(percentEncoded: false)))
    }

    @Test("saved values survive a reload")
    func roundTrip() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = BootstrapStore(paths: paths)

        var config = BootstrapConfig.default
        config.surrealPort = 19_123
        config.logLevel = .debug
        try store.save(config)

        let (loaded, outcome) = try store.load()
        #expect(outcome == .loaded)
        #expect(loaded.surrealPort == 19_123)
        #expect(loaded.logLevel == .debug)
    }

    @Test("a corrupt file is repaired instead of blocking launch")
    func repairsCorruptFile() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        try Data("this is not a plist".utf8).write(to: paths.bootstrapFile)

        let store = BootstrapStore(paths: paths)
        let (config, outcome) = try store.load()

        if case .repairedInvalid = outcome {} else {
            Issue.record("expected .repairedInvalid, got \(outcome)")
        }
        #expect(config == .default)
    }

    @Test("a file with invalid values is repaired too")
    func repairsInvalidValues() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()

        // Write a structurally valid plist carrying an illegal port.
        let bad = BootstrapConfig(schemaVersion: 1, surrealPort: 18_000,
                                  searxngPort: 18_080, logLevel: .info)
        var dict = try PropertyListSerialization.propertyList(
            from: try PropertyListEncoder().encode(bad), format: nil) as! [String: Any]
        dict["surrealPort"] = 42
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: paths.bootstrapFile)

        let (config, outcome) = try BootstrapStore(paths: paths).load()
        if case .repairedInvalid = outcome {} else {
            Issue.record("expected .repairedInvalid, got \(outcome)")
        }
        #expect(config.surrealPort == BootstrapConfig.default.surrealPort)
    }

    @Test("saving an invalid config is refused")
    func refusesInvalidSave() {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var config = BootstrapConfig.default
        config.surrealPort = 1
        #expect(throws: BootstrapError.self) { try BootstrapStore(paths: paths).save(config) }
    }
}
