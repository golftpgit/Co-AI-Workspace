import Testing
import Foundation
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// The shared SQL guard (ARCHITECTURE §12.5, P6.5).
//
// The tests that matter here are the ones about text that *looks* like a
// statement boundary and is not — a semicolon inside a string, a table named
// `delete`, a DELETE hiding inside a CTE. A guard that only handles tidy SQL is
// the guard v1 had.
// ─────────────────────────────────────────────────────────────

@Suite("SQL guard")
struct SQLGuardTests {

    @Test("a select runs without asking")
    func readsAreNotConfirmed() {
        let assessment = SQLGuard.assess("SELECT * FROM patients WHERE a1c > 7")
        #expect(assessment.effect == .read)
        #expect(!assessment.needsConfirmation)
        #expect(assessment.mutating.isEmpty)
    }

    /// The whole reason a guard exists. A WHERE that was meant to be typed and
    /// was not is the difference between a row and a table.
    @Test("DELETE without a WHERE is reported as destructive, with the table named")
    func deleteWithoutWhere() {
        let bare = SQLGuard.assess("DELETE FROM patients").statements[0]
        #expect(bare.effect == .destructive)
        #expect(bare.target == "patients")
        #expect(bare.note?.contains("ทุกแถว") == true)

        let filtered = SQLGuard.assess("DELETE FROM patients WHERE id = 3").statements[0]
        #expect(filtered.effect == .write)
        #expect(filtered.note?.contains("เงื่อนไข") == true)
    }

    @Test("UPDATE is judged the same way as DELETE")
    func updateWithoutWhere() {
        #expect(SQLGuard.assess("UPDATE visits SET a1c = 0").statements[0].effect == .destructive)
        #expect(SQLGuard.assess("UPDATE visits SET a1c = 0 WHERE id = 1")
            .statements[0].effect == .write)
    }

    /// A WHERE belonging to a subquery is not the statement's own.
    @Test("a WHERE inside a subquery does not count as the statement's WHERE")
    func nestedWhereDoesNotCount() {
        let statement = SQLGuard.assess(
            "DELETE FROM patients USING (SELECT id FROM old WHERE year < 2020) o").statements[0]
        #expect(statement.effect == .destructive)
    }

    @Test("CREATE OR REPLACE is destructive; a plain CREATE is not")
    func replaceIsDestructive() {
        #expect(SQLGuard.assess("CREATE TABLE cohort (id INTEGER)").statements[0].effect == .write)
        let replaced = SQLGuard.assess("CREATE OR REPLACE TABLE cohort AS SELECT 1").statements[0]
        #expect(replaced.effect == .destructive)
        #expect(replaced.target == "cohort")
    }

    @Test("DROP and TRUNCATE are destructive and say what they take")
    func dropAndTruncate() {
        let dropped = SQLGuard.assess("DROP TABLE IF EXISTS readings").statements[0]
        #expect(dropped.effect == .destructive)
        #expect(dropped.target == "readings")

        let truncated = SQLGuard.assess("TRUNCATE readings").statements[0]
        #expect(truncated.effect == .destructive)
        #expect(truncated.target == "readings")
    }

    /// A semicolon inside a string literal is data, not a statement boundary.
    /// Splitting on `;` would hand DuckDB `SELECT 'a` and then run the rest of
    /// the user's text as if it were SQL.
    @Test("a semicolon inside a string does not end the statement")
    func semicolonInsideString() {
        let statements = SQLGuard.split("SELECT 'a;b' AS s, 'it''s; fine' AS t")
        #expect(statements.count == 1)
        #expect(statements[0].contains("a;b"))
    }

    @Test("semicolons in comments are ignored, in both comment styles")
    func semicolonInsideComments() {
        let statements = SQLGuard.split("""
        -- DELETE FROM patients;
        SELECT 1;
        /* DROP TABLE x; /* nested */ still a comment; */
        SELECT 2
        """)
        #expect(statements.count == 2)
        #expect(SQLGuard.assess(statements.joined(separator: ";\n")).effect == .read)
    }

    @Test("a dollar-quoted string keeps its semicolons")
    func dollarQuoting() {
        let statements = SQLGuard.split("SELECT $$one; two$$ AS s; SELECT 2")
        #expect(statements.count == 2)
    }

    /// A table may legitimately be called `delete`, as long as it is quoted.
    /// Reading a quoted name as a keyword is how a guard fires on a select and
    /// teaches the user to click through it.
    @Test("a quoted identifier is a name, whatever it spells")
    func quotedIdentifierIsNotAVerb() {
        let assessment = SQLGuard.assess(#"SELECT * FROM "delete" WHERE "drop" = 1"#)
        #expect(assessment.effect == .read)
    }

    /// The mutating verb of a CTE sits inside the parentheses; a guard that
    /// only reads the first keyword calls this a read.
    @Test("a CTE that deletes is not a read")
    func mutatingCTE() {
        let statement = SQLGuard.assess("""
        WITH gone AS (DELETE FROM patients WHERE id = 1 RETURNING *)
        SELECT count(*) FROM gone
        """).statements[0]
        #expect(statement.verb == "DELETE")
        #expect(statement.effect == .write)
    }

    @Test("a plain CTE over a select is still a read")
    func readingCTE() {
        #expect(SQLGuard.assess("""
        WITH recent AS (SELECT * FROM visits WHERE month > 3)
        SELECT avg(a1c) FROM recent
        """).effect == .read)
    }

    /// EXPLAIN plans a statement without running it.
    @Test("EXPLAIN of a delete is a read")
    func explainIsRead() {
        #expect(SQLGuard.assess("EXPLAIN DELETE FROM patients").effect == .read)
    }

    /// The rule from §5.3, applied to SQL: what the guard cannot name is
    /// assumed to change something.
    @Test("a verb the guard does not know is treated as mutating")
    func unknownVerbIsMutating() {
        let statement = SQLGuard.assess("REINDEX something_new").statements[0]
        #expect(statement.effect == .write)
        #expect(statement.note?.contains("ยังไม่รู้จัก") == true)
    }

    /// A buffer is confirmed as a whole: stopping to ask between statements two
    /// and three leaves the data in a state nobody chose.
    @Test("a buffer is judged by its worst statement")
    func worstStatementWins() {
        let assessment = SQLGuard.assess("""
        SELECT count(*) FROM patients;
        DROP TABLE patients;
        SELECT 1
        """)
        #expect(assessment.statements.count == 3)
        #expect(assessment.effect == .destructive)
        #expect(assessment.mutating.count == 1)
        #expect(assessment.summary.contains("3 คำสั่ง"))
    }

    @Test("an empty buffer has nothing to confirm")
    func emptyBuffer() {
        #expect(SQLGuard.assess("   \n -- nothing here \n ").isEmpty)
        #expect(SQLGuard.assess("").needsConfirmation == false)
    }

    /// §12.2 attaches read-only by default because the data on the other end is
    /// usually somebody else's; a statement that opts out should say so.
    @Test("attaching a writable external database is called out")
    func writableAttach() {
        let readOnly = SQLGuard.assess("ATTACH 'lab.db' AS lab (TYPE sqlite, READ_ONLY)")
        #expect(readOnly.statements[0].note?.contains("อ่านอย่างเดียว") == true)
        let writable = SQLGuard.assess("ATTACH 'lab.db' AS lab (TYPE sqlite)")
        #expect(writable.statements[0].note?.contains("เขียนได้") == true)
    }

    /// The split has to hand back statements DuckDB accepts — no trailing
    /// semicolon, no leading blank line — because that is how the notebook runs
    /// a multi-statement cell.
    @Test("split statements run one at a time against a real store")
    func splitStatementsExecute() async throws {
        let store = try AnalysisStore()
        let buffer = """
        CREATE TABLE t (n INTEGER, label VARCHAR);
        INSERT INTO t VALUES (1, 'a;b'), (2, 'ค');
        SELECT count(*) AS n FROM t;
        """
        var last: QueryResult?
        for statement in SQLGuard.split(buffer) {
            last = try await store.query(statement)
        }
        #expect(last?.rows == [["2"]])
    }
}
