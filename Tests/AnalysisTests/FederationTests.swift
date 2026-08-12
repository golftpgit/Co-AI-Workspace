import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// Federated query, against a real external database (§12.2, P6.2).
//
// SQLite is the one connector that can be proven on a laptop with nothing
// installed: the file is made here, attached through DuckDB's scanner, and
// joined to a local table. Postgres and MySQL use the same code path and the
// same two statements — what cannot be proven without a server is that those
// *servers* behave, not that this layer does.
//
// The extension is downloaded on first use, so these skip loudly rather than
// failing on a machine with no network.
// ─────────────────────────────────────────────────────────────

private func makeSQLiteFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "coai-federation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "lab.sqlite")

    // Written by the `sqlite3` binary that ships with macOS: a file made by
    // some other tool is exactly the case this feature exists for.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [file.path(percentEncoded: false), """
    CREATE TABLE specimens (id INTEGER, patient TEXT, a1c REAL);
    INSERT INTO specimens VALUES (1, 'ก', 7.2), (2, 'ข', 6.1), (3, 'ค', 9.0);
    """]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw AnalysisError.openFailed("sqlite3 exited \(process.terminationStatus)")
    }
    return file
}

/// The extension repository is on the network. A machine without one is not a
/// broken machine, and this suite says so instead of failing.
private func skipUnlessSQLiteScannerAvailable(_ store: AnalysisStore) async -> Bool {
    do {
        _ = try await store.install(.sqlite)
        return true
    } catch {
        print("SKIPPED: sqlite_scanner ไม่พร้อม (ต้องโหลด extension ครั้งแรกผ่านเน็ต) — \(error)")
        return false
    }
}

@Suite("Federated query", .serialized)
struct FederationTests {

    @Test("an external SQLite file is attached and read in place")
    func attachesAndReads() async throws {
        let store = try AnalysisStore()
        guard await skipUnlessSQLiteScannerAvailable(store) else { return }
        let file = try makeSQLiteFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let attached = try await store.attach(file.path(percentEncoded: false),
                                              as: "lab", kind: .sqlite)
        #expect(attached.readOnly)
        #expect(try await store.attachedDatabases().contains("lab"))
        // Schema exploration before anyone decides to pull anything (§12.2).
        #expect(try await store.tables(in: "lab") == ["specimens"])

        let result = try await store.query("SELECT count(*) AS n FROM lab.specimens")
        #expect(result.rows == [["3"]])
    }

    /// The point of federation rather than copying: one query, both sides.
    @Test("a local table and a remote one can be joined in a single query")
    func joinsAcrossDatabases() async throws {
        let store = try AnalysisStore()
        guard await skipUnlessSQLiteScannerAvailable(store) else { return }
        let file = try makeSQLiteFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        try await store.attach(file.path(percentEncoded: false), as: "lab", kind: .sqlite)
        try await store.query("CREATE TABLE targets (patient VARCHAR, target DOUBLE)")
        try await store.query("INSERT INTO targets VALUES ('ก', 7.0), ('ข', 6.5), ('ค', 7.0)")

        let result = try await store.query("""
        SELECT s.patient, s.a1c, t.target, s.a1c > t.target AS above
        FROM lab.specimens s JOIN targets t ON t.patient = s.patient
        ORDER BY s.id
        """)
        #expect(result.rowCount == 3)
        #expect(result.rows[0] == ["ก", "7.2", "7.0", "true"])
        #expect(result.rows[1][3] == "false")
    }

    @Test("a remote table can be pulled in when a copy is what is wanted")
    func pullsATable() async throws {
        let store = try AnalysisStore()
        guard await skipUnlessSQLiteScannerAvailable(store) else { return }
        let file = try makeSQLiteFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        try await store.attach(file.path(percentEncoded: false), as: "lab", kind: .sqlite)
        try await store.pull("specimens", from: "lab", into: "specimens_local")

        #expect(try await store.tables().contains("specimens_local"))
        // The copy survives detaching the source, which is the whole reason to
        // make one.
        try await store.detach("lab")
        #expect(try await store.query("SELECT count(*) FROM specimens_local").rows == [["3"]])
        #expect(try await store.attachedDatabases().contains("lab") == false)
    }

    /// Attached read-only on purpose: this is somebody else's data far more
    /// often than it is ours (§12.2).
    @Test("an attached database is read-only unless asked otherwise")
    func attachesReadOnly() async throws {
        let store = try AnalysisStore()
        guard await skipUnlessSQLiteScannerAvailable(store) else { return }
        let file = try makeSQLiteFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        try await store.attach(file.path(percentEncoded: false), as: "lab", kind: .sqlite)
        await #expect(throws: AnalysisError.self) {
            try await store.query("INSERT INTO lab.specimens VALUES (4, 'ง', 5.0)")
        }
    }

    @Test("every connector names the extension and attach type DuckDB expects")
    func connectorNames() {
        #expect(ConnectorKind.sqlite.extensionName == "sqlite_scanner")
        #expect(ConnectorKind.postgres.extensionName == "postgres_scanner")
        #expect(ConnectorKind.mysql.extensionName == "mysql_scanner")
        #expect(ConnectorKind.allCases.map(\.attachType) == ["sqlite", "postgres", "mysql"])
    }
}
