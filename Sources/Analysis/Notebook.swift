import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// The notebook itself (ARCHITECTURE §12.5, §2.6 "ข้ามหัวหน้าทีม/ข้าม agent
// ทั้งหมด", P6.4).
//
// This is the row of §2.6 that says a person may skip the team entirely and do
// the work themselves. So the notebook is not an agent surface: nothing here
// asks a model anything. A cell is SQL or Python, it runs, and what comes back
// is what the engine said.
//
// The one rule the runner enforces rather than suggests: **a SQL cell that
// changes data cannot be run without confirmation.** The check is not the
// screen's to remember — the runner refuses, the same way `ToolGateway` keeps
// tools private so no caller can reach around the hook chain (§5.3). One guard
// (P6.5), two callers, no copies.
// ─────────────────────────────────────────────────────────────

public struct NotebookCell: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case sql
        case python

        public var label: String {
            switch self {
            case .sql: "SQL"
            case .python: "Python"
            }
        }
    }

    public let id: String
    public var kind: Kind
    public var source: String

    public init(id: String = OpaqueID.make("cell"), kind: Kind, source: String = "") {
        self.id = id
        self.kind = kind
        self.source = source
    }
}

public struct Notebook: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var title: String
    /// §12.5: scope per notebook. A notebook belonging to one project has no
    /// business being listed under another.
    public var scope: Scope
    public var cells: [NotebookCell]
    public var updatedAt: Date

    public init(id: String = OpaqueID.make("nb"),
                // Defaulted to nil rather than to the looked-up name: a default
                // argument cannot call an internal function, and the catalogue
                // helper is internal.
                title: String? = nil,
                scope: Scope = .central,
                cells: [NotebookCell] = [NotebookCell(kind: .sql)],
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title ?? localised("Untitled notebook", "Default name for a new notebook.")
        self.scope = scope
        self.cells = cells
        self.updatedAt = updatedAt
    }
}

/// One statement's answer. A cell that runs three statements shows three
/// tables — the alternative is a screen that quietly drops two results, which
/// is why `AnalysisStore.query` takes one statement at a time.
public struct StatementResult: Sendable, Equatable, Identifiable {
    public let statement: SQLStatement
    public let result: QueryResult
    public var id: String { statement.text }
}

public enum CellOutcome: Sendable, Equatable {
    case sql([StatementResult])
    case python(CellOutput)
}

public enum NotebookError: Error, CustomStringConvertible, Equatable {
    /// The cell mutates and nobody has said yes yet. Carries the assessment so
    /// the caller can show exactly what is about to happen.
    case needsConfirmation(SQLAssessment)
    case emptyCell

    public var description: String {
        switch self {
        case .needsConfirmation(let assessment):
            localised("needs confirming before it runs: \(assessment.summary)", "Why a cell did not run. Placeholder: what the statements would do.")
        case .emptyCell: localised("the cell is empty", "Why a cell did not run.")
        }
    }
}

extension CellOutcome {
    /// The record a manuscript can bind a number to (§20.8, P11.9).
    ///
    /// `nil` for a Python cell: a manuscript number points at a column and a
    /// row, and a Python cell's answer is a stream of text. That is a real gap
    /// and it is left visible rather than papered over by parsing stdout —
    /// P11.9's promise is that a reported figure is traceable, and a number
    /// scraped out of print() is traceable to nothing.
    public func run(notebookID: String, cell: NotebookCell) -> CellRun? {
        guard case .sql(let results) = self, let first = results.first else { return nil }
        return CellRun(notebookID: notebookID, cellID: cell.id, source: cell.source,
                       columns: first.result.columns.map(\.name),
                       rows: first.result.rows)
    }
}

/// Runs cells. Holds the two engines and the guard between them.
public struct NotebookRunner: Sendable {
    public let store: AnalysisStore
    public let kernel: NotebookKernel?

    public init(store: AnalysisStore, kernel: NotebookKernel? = nil) {
        self.store = store
        self.kernel = kernel
    }

    /// What this cell would do, for the screen to show before anyone presses
    /// run. Nil for a Python cell: §12.5's guard is about SQL statements, and a
    /// dialog on every Python cell would be a dialog nobody reads.
    public nonisolated func assess(_ cell: NotebookCell) -> SQLAssessment? {
        guard cell.kind == .sql else { return nil }
        return SQLGuard.assess(cell.source)
    }

    public func run(_ cell: NotebookCell, confirmed: Bool = false) async throws -> CellOutcome {
        switch cell.kind {
        case .python:
            guard let kernel else { throw KernelError.notRunning }
            guard !cell.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NotebookError.emptyCell
            }
            return .python(try await kernel.execute(cell.source))

        case .sql:
            let assessment = SQLGuard.assess(cell.source)
            guard !assessment.isEmpty else { throw NotebookError.emptyCell }
            // The refusal lives here, not in the view. A second screen that
            // forgot to ask is exactly how v1's two copies of this check
            // drifted apart.
            guard confirmed || !assessment.needsConfirmation else {
                throw NotebookError.needsConfirmation(assessment)
            }
            var results: [StatementResult] = []
            for statement in assessment.statements {
                results.append(StatementResult(statement: statement,
                                               result: try await store.query(statement.text)))
            }
            return .sql(results)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Where notebooks live.
//
// Files rather than rows: a notebook is a document, the analysis directory is
// already where the `.duckdb` sits, and a person who wants to send one to a
// colleague should be able to. Losing one file must not cost the others, so
// listing skips what it cannot read instead of failing.
// ─────────────────────────────────────────────────────────────

public struct NotebookStore: Sendable {
    public let directory: URL
    private let log = AppLog.logger("notebook")

    public init(directory: URL) {
        self.directory = directory
    }

    public func list() -> [Notebook] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let notebook = try? Self.decoder.decode(Notebook.self, from: data) else {
                    log.error("unreadable notebook: \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                return notebook
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func save(_ notebook: Notebook) throws -> Notebook {
        var saved = notebook
        saved.updatedAt = Date()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(saved).write(to: file(for: notebook.id), options: .atomic)
        return saved
    }

    public func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: file(for: id))
    }

    private func file(for id: String) -> URL {
        // The id is generated by OpaqueID, so it cannot contain a path
        // separator; the last component is taken anyway, because a name that
        // reaches out of its directory is the kind of thing that only has to
        // work once.
        directory.appending(path: (id as NSString).lastPathComponent + ".json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
