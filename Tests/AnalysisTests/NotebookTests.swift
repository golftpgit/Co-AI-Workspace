import Testing
import Foundation
import AgentKit
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// The notebook: cells, the runner that refuses, and where notebooks live
// (ARCHITECTURE §12.5, P6.4/P6.5).
// ─────────────────────────────────────────────────────────────

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "coai-nb-\(UUID().uuidString)")
}

@Suite("Notebook")
struct NotebookTests {

    @Test("a read-only cell runs without anyone confirming anything")
    func readingCellJustRuns() async throws {
        let store = try AnalysisStore()
        let runner = NotebookRunner(store: store)
        let outcome = try await runner.run(NotebookCell(kind: .sql, source: "SELECT 1 AS n"))
        guard case .sql(let results) = outcome else { Issue.record("wrong outcome"); return }
        #expect(results.count == 1)
        #expect(results[0].result.rows == [["1"]])
    }

    /// The refusal is the runner's, not the screen's. A view that forgets to
    /// ask is how v1's two copies of this check drifted apart — here there is
    /// nothing to forget, because the unconfirmed call does not run the SQL.
    @Test("a mutating cell will not run until it is confirmed, and nothing happens meanwhile")
    func mutatingCellNeedsConfirmation() async throws {
        let store = try AnalysisStore()
        let runner = NotebookRunner(store: store)
        let cell = NotebookCell(kind: .sql, source: "CREATE TABLE cohort (n INTEGER)")

        do {
            _ = try await runner.run(cell)
            Issue.record("the runner ran a mutating cell without confirmation")
        } catch let error as NotebookError {
            guard case .needsConfirmation(let assessment) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(assessment.effect == .write)
            #expect(assessment.mutating.count == 1)
        }
        // The evidence that it really did not run.
        #expect(try await store.tables().isEmpty)

        _ = try await runner.run(cell, confirmed: true)
        #expect(try await store.tables() == ["cohort"])
    }

    /// `assess` is what the screen shows before anyone presses run. It has to
    /// be the same answer the runner will enforce, because there is only one
    /// guard.
    @Test("what the screen asks about is what the runner enforces")
    func assessMatchesEnforcement() async throws {
        let store = try AnalysisStore()
        let runner = NotebookRunner(store: store)
        let cell = NotebookCell(kind: .sql, source: "DROP TABLE readings")

        let assessment = runner.assess(cell)
        #expect(assessment?.effect == .destructive)
        // A Python cell has no SQL to assess; §12.5's guard is about
        // statements, and a dialog on every Python cell is a dialog nobody
        // reads.
        #expect(runner.assess(NotebookCell(kind: .python, source: "1")) == nil)
    }

    /// A cell with three statements shows three tables. Showing one would hide
    /// two results, which is the reason `AnalysisStore.query` takes a single
    /// statement in the first place.
    @Test("every statement in a cell gets its own result")
    func everyStatementReportsBack() async throws {
        let store = try AnalysisStore()
        let runner = NotebookRunner(store: store)
        let outcome = try await runner.run(
            NotebookCell(kind: .sql, source: """
            CREATE TABLE t (n INTEGER);
            INSERT INTO t VALUES (1), (2);
            SELECT count(*) AS n FROM t
            """),
            confirmed: true)

        guard case .sql(let results) = outcome else { Issue.record("wrong outcome"); return }
        #expect(results.count == 3)
        #expect(results.map(\.statement.verb) == ["CREATE", "INSERT", "SELECT"])
        #expect(results.last?.result.rows == [["2"]])
    }

    @Test("an empty cell is not a query")
    func emptyCell() async throws {
        let runner = NotebookRunner(store: try AnalysisStore())
        await #expect(throws: NotebookError.self) {
            try await runner.run(NotebookCell(kind: .sql, source: "  -- nothing\n"))
        }
    }

    @Test("a Python cell with no kernel says so rather than pretending")
    func pythonWithoutKernel() async throws {
        let runner = NotebookRunner(store: try AnalysisStore())
        await #expect(throws: KernelError.self) {
            try await runner.run(NotebookCell(kind: .python, source: "1 + 1"))
        }
    }

    @Test("a Python cell runs through the same runner as SQL")
    func pythonCell() async throws {
        let kernel: NotebookKernel
        do {
            kernel = try NotebookKernel()
            try await kernel.start()
        } catch {
            print("SKIPPED: ไม่มี Python สำหรับเทสเซลล์ Python — \(error)")
            return
        }
        defer { Task { await kernel.stop() } }

        let runner = NotebookRunner(store: try AnalysisStore(), kernel: kernel)
        let outcome = try await runner.run(NotebookCell(kind: .python, source: "sum([1, 2, 3])"))
        guard case .python(let output) = outcome else { Issue.record("wrong outcome"); return }
        #expect(output.value == "6")
    }

    // MARK: - storage

    @Test("a notebook survives being saved and listed again, scope and all")
    func notebooksPersist() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookStore(directory: directory)

        let notebook = Notebook(
            title: "การวิเคราะห์ HbA1c",
            scope: .project(ProjectID("diabetes")),
            cells: [NotebookCell(kind: .sql, source: "SELECT 1"),
                    NotebookCell(kind: .python, source: "import pandas")])
        try store.save(notebook)

        let listed = store.list()
        #expect(listed.count == 1)
        #expect(listed[0].title == "การวิเคราะห์ HbA1c")
        #expect(listed[0].scope == .project(ProjectID("diabetes")))
        #expect(listed[0].cells.map(\.kind) == [.sql, .python])
        #expect(listed[0].cells[0].source == "SELECT 1")
    }

    @Test("saving twice updates the same notebook rather than making a second one")
    func savingIsIdempotent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookStore(directory: directory)

        var notebook = Notebook(title: "ร่าง")
        try store.save(notebook)
        notebook.title = "แก้แล้ว"
        try store.save(notebook)

        #expect(store.list().count == 1)
        #expect(store.list()[0].title == "แก้แล้ว")

        try store.delete(notebook.id)
        #expect(store.list().isEmpty)
    }

    /// One corrupt file must not cost the others: a notebook is a document, and
    /// documents get truncated by full disks and half-finished copies.
    @Test("an unreadable notebook is skipped, not fatal")
    func corruptFileIsSkipped() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookStore(directory: directory)
        try store.save(Notebook(title: "ดีอยู่"))
        try "{ not json".write(to: directory.appending(path: "broken.json"),
                               atomically: true, encoding: .utf8)

        #expect(store.list().map(\.title) == ["ดีอยู่"])
    }
}
