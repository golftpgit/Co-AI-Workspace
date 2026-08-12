import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// The analysis store against a real DuckDB (ARCHITECTURE §12.1, P6.1).
//
// Nothing is stubbed here: the point of choosing DuckDB was the SQL surface,
// so a test that mocks it away would be testing our own wrapper against
// itself.
// ─────────────────────────────────────────────────────────────

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "coai-analysis-\(UUID().uuidString)/analysis.duckdb")
}

@Suite("Analysis store")
struct AnalysisStoreTests {

    @Test("a table can be created, filled and read back")
    func roundTrip() async throws {
        let store = try AnalysisStore()
        try await store.query("CREATE TABLE patients (id INTEGER, name VARCHAR, a1c DOUBLE)")
        try await store.query("""
        INSERT INTO patients VALUES (1, 'ก', 7.2), (2, 'ข', 6.1), (3, 'ค', NULL)
        """)

        let result = try await store.query("SELECT * FROM patients ORDER BY id")
        #expect(result.columns.map(\.name) == ["id", "name", "a1c"])
        #expect(result.rowCount == 3)
        #expect(result.rows[0] == ["1", "ก", "7.2"])
        // SQL NULL is not the empty string: one is "we do not know", the other
        // is a value someone stored.
        #expect(result.rows[2][2] == nil)
    }

    /// The renderer reads each column through the type DuckDB says it is.
    /// Casting a BIGINT to String in this library does not fail — it yields a
    /// column of nils, which would blank the table rather than error.
    @Test("every column type comes back as readable text, not as blanks")
    func rendersEveryType() async throws {
        let store = try AnalysisStore()
        let result = try await store.query("""
        SELECT 42::INTEGER AS i, 9223372036854775807::BIGINT AS big, 3.5::DOUBLE AS d,
               true AS flag, 'ข้อความ' AS text, DATE '2026-08-12' AS day,
               [1, 2, 3] AS numbers
        """)

        let row = result.rows[0]
        #expect(row[0] == "42")
        #expect(row[1] == "9223372036854775807")
        #expect(row[2] == "3.5")
        #expect(row[3] == "true")
        #expect(row[4] == "ข้อความ")
        #expect(row[5] == "2026-08-12")
        // A list is not a type this renderer models; it still has to print
        // rather than disappear.
        #expect(row[6] != nil)
    }

    @Test("the column types are reported, not just the values")
    func reportsColumnTypes() async throws {
        let store = try AnalysisStore()
        let result = try await store.query("SELECT 1::INTEGER AS n, 'x' AS s")
        #expect(result.columns.map(\.type) == ["integer", "varchar"])
    }

    /// The reason for choosing DuckDB in the first place (§12.1): the analysis
    /// this project does is aggregates and windows, not row lookups.
    @Test("aggregates and window functions work, which is why this store exists")
    func runsAnalyticalSQL() async throws {
        let store = try AnalysisStore()
        try await store.query("CREATE TABLE visits (patient INTEGER, month INTEGER, a1c DOUBLE)")
        try await store.query("""
        INSERT INTO visits VALUES (1, 1, 8.0), (1, 2, 7.5), (1, 3, 7.0),
                                  (2, 1, 6.0), (2, 2, 6.4)
        """)

        let result = try await store.query("""
        SELECT patient,
               avg(a1c) AS mean,
               first_value(a1c) OVER (PARTITION BY patient ORDER BY month) AS first_reading
        FROM visits GROUP BY patient, a1c, month ORDER BY patient, month
        """)
        #expect(result.rowCount == 5)
        #expect(result.columns.map(\.name) == ["patient", "mean", "first_reading"])
    }

    /// An error has to carry the statement. "syntax error at or near" with no
    /// SQL beside it is unactionable by the time it reaches a screen or an
    /// agent.
    @Test("a bad statement fails with the SQL attached")
    func badSQLIsLegible() async throws {
        let store = try AnalysisStore()
        await #expect(throws: AnalysisError.self) {
            try await store.query("SELECT * FROM table_that_does_not_exist")
        }
        do {
            try await store.query("SELCT 1")
        } catch let error as AnalysisError {
            guard case .queryFailed(let sql, let message) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(sql == "SELCT 1")
            #expect(!message.isEmpty)
        }
    }

    @Test("what is written survives closing and reopening the file")
    func persistsToDisk() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let store = try AnalysisStore(fileURL: url)
            try await store.query("CREATE TABLE cohort AS SELECT 1 AS n")
        }
        // The point of a store rather than an in-memory frame: yesterday's
        // pulled tables are still here today.
        let reopened = try AnalysisStore(fileURL: url)
        let tables = try await reopened.tables()
        #expect(tables.contains("cohort"))
        #expect(try await reopened.query("SELECT n FROM cohort").rows == [["1"]])
    }

    @Test("tables and their schemas can be listed, which is what an explorer needs")
    func describesItself() async throws {
        let store = try AnalysisStore()
        try await store.query("CREATE TABLE t (a INTEGER, b VARCHAR)")

        #expect(try await store.tables() == ["t"])
        let schema = try await store.schema(of: "t")
        #expect(schema.map(\.name) == ["a", "b"])
        #expect(schema.map(\.type) == ["INTEGER", "VARCHAR"])
    }

    /// A table name is a name, never a statement. `orders"; DROP TABLE x` has
    /// to survive as an identifier.
    @Test("an identifier with a quote in it stays an identifier")
    func quotesIdentifiers() async throws {
        let store = try AnalysisStore()
        let nasty = #"weird"; DROP TABLE other; --"#
        try await store.query("CREATE TABLE \(AnalysisStore.quoted(nasty)) (n INTEGER)")
        try await store.query("CREATE TABLE other (n INTEGER)")

        let schema = try await store.schema(of: nasty)
        #expect(schema.map(\.name) == ["n"])
        // The second table is still there — the quote never closed the
        // identifier and started a new statement.
        #expect(try await store.tables().contains("other"))
    }

    @Test("a CSV is read in with its types inferred")
    func importsCSV() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "coai-csv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "readings.csv")
        try "patient,a1c\n1,7.2\n2,6.1\n".write(to: file, atomically: true, encoding: .utf8)

        let store = try AnalysisStore()
        try await store.importFile(file, into: "readings")

        let result = try await store.query("SELECT avg(a1c) AS mean FROM readings")
        #expect(result.rows[0][0]?.hasPrefix("6.6") == true)
        // Inferred, not all-varchar: an analysis store that reads every CSV
        // column as text cannot average anything.
        #expect(try await store.schema(of: "readings").map(\.type) == ["BIGINT", "DOUBLE"])
    }
}
