import Testing
import Foundation
import AgentKit
import DocGen
@testable import Analysis

// The join P11.9 rests on: a cell runs, what it answered is recorded, and a
// manuscript resolves a number out of that record months later.
//
// The two ends are tested apart — the runner in this module, the binding in
// DocGen — so what is checked here is the middle, which is the piece that is
// easy to get subtly wrong: the recorded columns have to be the ones the
// manuscript will name, and the recorded source has to be the text the cell
// held when it ran.

@Suite("recording what a cell answered")
struct CellRunTests {

    private func outcome(columns: [String], rows: [[String?]],
                         statement: String) -> CellOutcome {
        .sql([StatementResult(
            statement: SQLStatement(text: statement, verb: "SELECT", effect: .read,
                                     target: nil, note: nil),
            result: QueryResult(columns: columns.map { QueryResult.Column(name: $0, type: "DOUBLE") },
                                rows: rows, duration: .milliseconds(3)))])
    }

    @Test("a SQL cell's answer becomes a record a manuscript can bind to")
    func sqlCellRecordsItsAnswer() throws {
        let statement = "SELECT avg(age) AS mean_age FROM respondents"
        let cell = NotebookCell(id: "c1", kind: .sql, source: statement)
        let run = try #require(outcome(columns: ["mean_age"], rows: [["34.7"]],
                                       statement: statement)
            .run(notebookID: "nb_1", cell: cell))

        #expect(run.columns == ["mean_age"])
        #expect(run.rows == [["34.7"]])
        // The source is the cell's, not the statement's: what has to be compared
        // later is the text the cell holds, and a cell may hold several
        // statements.
        #expect(run.source == statement)

        // And the far end resolves it.
        let reference = ResultReference(notebookID: "nb_1", cellID: "c1",
                                        column: "mean_age", label: "อายุเฉลี่ย")
        let bound = try BoundResult.bind(reference, to: [run],
                                         currentSources: ["c1": statement]).get()
        #expect(bound.value == "34.7")
    }

    @Test("a Python cell records nothing, and that gap is deliberate")
    func pythonCellRecordsNothing() {
        // A manuscript number points at a column and a row; a Python cell's
        // answer is a stream of text. Scraping a figure out of print() would be
        // a number traceable to nothing, which is the thing P11.9 exists to
        // prevent — so the honest answer is no record at all.
        let cell = NotebookCell(id: "c2", kind: .python, source: "print(mean)")
        let outcome = CellOutcome.python(CellOutput(stdout: "34.7\n", stderr: "", value: nil, error: nil))
        #expect(outcome.run(notebookID: "nb_1", cell: cell) == nil)
    }

    @Test("a cell that answered nothing records nothing")
    func emptyAnswer() {
        let cell = NotebookCell(id: "c3", kind: .sql, source: "SELECT 1")
        #expect(CellOutcome.sql([]).run(notebookID: "nb_1", cell: cell) == nil)
    }

    @Test("re-running an edited cell replaces the number the manuscript sees")
    func rerunSupersedes() throws {
        let first = "SELECT avg(age) AS mean_age FROM respondents"
        let edited = first + " WHERE consented"
        let reference = ResultReference(notebookID: "nb_1", cellID: "c1",
                                        column: "mean_age", label: "อายุเฉลี่ย")

        let before = try #require(outcome(columns: ["mean_age"], rows: [["34.7"]],
                                          statement: first)
            .run(notebookID: "nb_1", cell: NotebookCell(id: "c1", kind: .sql, source: first)))
        // The cell is edited and not re-run: the old number must not resolve,
        // because it answered the earlier question.
        #expect((try? BoundResult.bind(reference, to: [before],
                                       currentSources: ["c1": edited]).get()) == nil)

        let after = try #require(outcome(columns: ["mean_age"], rows: [["35.9"]],
                                         statement: edited)
            .run(notebookID: "nb_1", cell: NotebookCell(id: "c1", kind: .sql, source: edited)))
        let bound = try BoundResult.bind(reference, to: [after],
                                         currentSources: ["c1": edited]).get()
        #expect(bound.value == "35.9")
    }
}
