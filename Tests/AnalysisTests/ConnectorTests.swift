import Testing
import Foundation
import AgentKit
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// Saved connectors (ARCHITECTURE §12.2, P6.3).
//
// P6.2 proved the mechanism against a real SQLite file. What is tested here is
// everything around it: that a connection survives being saved, that it belongs
// to a scope, and — the part worth having tests for — that the password is
// neither written to disk nor leaked into an error message.
// ─────────────────────────────────────────────────────────────

private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "coai-connectors-\(UUID().uuidString)/\(name)")
}

private func makeSQLiteFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "coai-connector-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "lab.sqlite")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [file.path(percentEncoded: false), """
    CREATE TABLE specimens (id INTEGER, patient TEXT, a1c REAL);
    INSERT INTO specimens VALUES (1, 'ก', 7.2), (2, 'ข', 6.1);
    """]
    try process.run()
    process.waitUntilExit()
    return file
}

@Suite("DB connectors")
struct ConnectorTests {

    @Test("a connector survives being saved, with its scope")
    func connectorsPersist() throws {
        let file = temporaryFile("connectors.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConnectorStore(file: file)

        try store.add(DBConnector(alias: "lab", kind: .sqlite, target: "/tmp/lab.sqlite",
                                  scope: .project(ProjectID("diabetes"))))
        try store.add(DBConnector(alias: "warehouse", kind: .postgres,
                                  target: "host=db.example.org dbname=research user=readonly",
                                  secretVariable: "PGPASSWORD"))

        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded[0].scope == .project(ProjectID("diabetes")))
        #expect(loaded[1].readOnly)          // §12.2's default

        // A project sees its own connectors and the shared ones, not another
        // project's.
        let projectView = store.load(scope: .project(ProjectID("diabetes")))
        #expect(projectView.map(\.alias) == ["lab", "warehouse"])
        #expect(store.load(scope: .project(ProjectID("cancer"))).map(\.alias) == ["warehouse"])
    }

    /// The file has to be something a person can open and see that their
    /// password is not in it.
    @Test("the password is not what gets written to disk")
    func secretsAreNotStored() throws {
        let file = temporaryFile("connectors.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConnectorStore(file: file)

        try store.add(DBConnector(alias: "warehouse", kind: .postgres,
                                  target: "host=db.example.org dbname=research user=readonly",
                                  secretVariable: "COAI_TEST_PGPASSWORD"))

        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("COAI_TEST_PGPASSWORD"))
        #expect(!written.lowercased().contains("password="))
    }

    @Test("a missing password is reported before connecting, not by the driver")
    func missingSecretIsCaughtEarly() async throws {
        let connector = DBConnector(alias: "warehouse", kind: .postgres,
                                    target: "host=db.example.org dbname=research",
                                    secretVariable: "COAI_DEFINITELY_UNSET_VARIABLE")
        #expect(!connector.secretIsAvailable)

        let store = try AnalysisStore()
        await #expect(throws: ConnectorError.secretMissing(
            variable: "COAI_DEFINITELY_UNSET_VARIABLE")) {
            try await store.attach(connector)
        }
    }

    /// `AnalysisError.queryFailed` carries its SQL on purpose, and DuckDB
    /// quotes the failing statement back inside its message — which for an
    /// ATTACH on a connection string would put a live credential into a log, a
    /// span and a screen.
    @Test("a failed connection does not carry the password anywhere")
    func failuresRedactTheSecret() async throws {
        let connector = DBConnector(alias: "warehouse", kind: .postgres,
                                    target: "host=db.example.org dbname=research",
                                    secretVariable: "COAI_TEST_PGPASSWORD")
        let full = AnalysisStore.connectionString(for: connector, secret: "hunter2")
        #expect(full.contains("password=hunter2"))

        // The way DuckDB actually reports it: the statement, verbatim.
        let raw = "Binder Error: ATTACH '\(full)' AS warehouse (TYPE postgres) failed"
        let shown = AnalysisStore.redact(raw, secret: "hunter2")
        #expect(!shown.contains("hunter2"))
        #expect(shown.contains("••••"))

        // And through the real path: a connector whose secret is set but whose
        // host does not exist. The error that comes back is the one the user
        // sees, and it must not contain the password.
        SecretStore.override("COAI_TEST_PGPASSWORD", "hunter2")
        defer { SecretStore.override("COAI_TEST_PGPASSWORD", nil) }
        let store = try AnalysisStore()
        do {
            try await store.attach(connector)
            Issue.record("attaching a database that does not exist should not succeed")
        } catch {
            #expect(!"\(error)".contains("hunter2"))
        }
    }

    @Test("SQLite takes a path, and no password is appended to it")
    func sqliteNeedsNoSecret() {
        let connector = DBConnector(alias: "lab", kind: .sqlite, target: "/tmp/lab.sqlite")
        #expect(AnalysisStore.connectionString(for: connector, secret: "hunter2")
                == "/tmp/lab.sqlite")
        #expect(connector.secretIsAvailable)
    }

    /// The Done-when, on the one kind that can be proven on a laptop: a saved
    /// connector is attached from its stored form and its schema is readable.
    @Test("a saved connector attaches and its schema can be explored")
    func savedConnectorAttaches() async throws {
        let store = try AnalysisStore()
        do {
            _ = try await store.install(.sqlite)
        } catch {
            print("SKIPPED: sqlite_scanner ไม่พร้อม (ต้องโหลด extension ครั้งแรกผ่านเน็ต) — \(error)")
            return
        }
        let database = try makeSQLiteFile()
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }

        let file = temporaryFile("connectors.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let connectors = ConnectorStore(file: file)
        try connectors.add(DBConnector(alias: "lab", kind: .sqlite,
                                       target: database.path(percentEncoded: false)))

        // Reloaded from disk, the way the app will use it after a restart.
        let saved = try #require(connectors.load().first)
        let attached = try await store.attach(saved)
        #expect(attached.readOnly)

        #expect(try await store.tables(in: "lab") == ["specimens"])
        let rows = try await store.query("SELECT count(*) AS n FROM lab.specimens")
        #expect(rows.rows == [["2"]])

        // And pulling a copy in is the other half of §12.2.
        try await store.pull("specimens", from: "lab", into: "lab_specimens")
        #expect(try await store.tables().contains("lab_specimens"))
    }

    /// The two kinds §12.2 lists that are not reachable from here are named,
    /// with the reason. A picker with two silent failures in it is worse.
    @Test("the connectors that are not supported yet say why")
    func unsupportedKindsAreNamed() {
        #expect(UnsupportedConnector.allCases.count == 2)
        for kind in UnsupportedConnector.allCases {
            #expect(!kind.reason.isEmpty)
        }
        #expect(UnsupportedConnector.mongoDB.reason.contains("native"))
    }
}
