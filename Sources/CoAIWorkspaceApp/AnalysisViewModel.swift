import Foundation
import Observation
import AgentKit
import Analysis
import CoreEngine
import Persistence
import Observability

// ─────────────────────────────────────────────────────────────
// The analysis screen's state (ARCHITECTURE §12.5, §14.2, P6.8).
//
// This is the row of §2.6 that says a person may skip the agents entirely:
// notebook cells and a DB explorer, driven by hand. Nothing on this screen asks
// a model anything.
//
// One thing worth being explicit about: the mutating-statement confirmation is
// **not implemented here**. `NotebookRunner` refuses to run an unconfirmed
// mutating cell and hands back the assessment; this file only shows what it was
// handed and calls back with `confirmed: true`. That is the whole point of
// P6.5 — the notebook and the explorer share one guard, and neither screen owns
// a copy of the rule.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class AnalysisViewModel {
    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    /// What a cell is doing, and what came back last time it ran.
    public enum CellState: Equatable {
        case idle
        case running
        case done(CellOutcome, seconds: Double)
        case failed(String)
    }

    /// A pending "are you sure": what would run, and which surface asked.
    public struct Confirmation: Equatable, Identifiable {
        public enum Source: Equatable {
            case cell(String)
            case explorer
            /// An import overwrites a table of the same name, so it goes
            /// through the guard like anything else that overwrites.
            case importFile(URL, table: String)
        }

        public let assessment: SQLAssessment
        public let source: Source
        public var id: String { assessment.summary + "\(source)" }
    }

    public enum KernelState: Equatable {
        case unavailable(String)
        case stopped
        case starting
        case ready(version: String)
        case busy
    }

    public struct TableSummary: Identifiable, Equatable {
        public let name: String
        // Qualified: `Persistence` has a `QueryResult` of its own, and this
        // file needs both modules.
        public let columns: [Analysis.QueryResult.Column]
        public let rowCount: Int?
        public var id: String { name }
    }

    // MARK: - notebook

    public private(set) var notebooks: [Notebook] = []
    public private(set) var notebook: Notebook?
    public private(set) var cellStates: [String: CellState] = [:]
    public private(set) var kernelState: KernelState = .stopped

    // MARK: - explorer

    public var explorerSQL = ""
    public private(set) var explorerResults: [StatementResult] = []
    public private(set) var explorerError: String?
    public private(set) var tables: [TableSummary] = []
    public private(set) var attached: [String] = []

    // MARK: - the analysis plan (§12.4)

    public private(set) var plans: [AnalysisPlan] = []
    public private(set) var plan: AnalysisPlan?
    /// The proposal being read. Pasted for now — reading it straight out of
    /// the knowledge base needs a `doc_type` the ingest pipeline does not
    /// record yet.
    public var proposalText = ""
    public var planTitle = ""
    public private(set) var isReadingProposal = false

    // MARK: - shared

    public var confirmation: Confirmation?
    public private(set) var status: Status?
    /// Nil when the `.duckdb` file could not be opened — the screen says so
    /// instead of showing an empty explorer that looks like an empty database.
    public private(set) var storeIsOpen = false

    private var runner: NotebookRunner?
    private var kernel: NotebookKernel?
    private var store: AnalysisStore?
    private var library: NotebookStore?
    private var planStore: AnalysisPlanStore?
    private var detector: GapDetector?
    private var scope: Scope = .central
    private let log = AppLog.logger("analysis-ui")

    public init() {}

    public func attach(plans store: AnalysisPlanStore, detector: GapDetector,
                       scope: Scope = .central) async {
        self.planStore = store
        self.detector = detector
        self.scope = scope
        await loadPlans()
    }

    public func attach(store: AnalysisStore?, kernel: NotebookKernel?, library: NotebookStore) async {
        self.store = store
        self.kernel = kernel
        self.library = library
        self.storeIsOpen = store != nil
        if let store {
            runner = NotebookRunner(store: store, kernel: kernel)
        }
        if kernel == nil {
            kernelState = .unavailable("ไม่พบ Python บนเครื่องนี้ — เซลล์ SQL ยังใช้ได้ตามปกติ")
        } else if let kernel, await kernel.isRunning {
            kernelState = .ready(version: await kernel.pythonVersion ?? "?")
        }
        notebooks = library.list()
        if notebook == nil { notebook = notebooks.first }
        await refresh()
    }

    /// Re-reads the catalogue. Called when the screen opens and after anything
    /// that could have changed it, because a table created in a cell should
    /// appear in the explorer without a restart.
    public func refresh() async {
        guard let store else { return }
        do {
            var summaries: [TableSummary] = []
            for name in try await store.tables() {
                let columns = try await store.schema(of: name)
                let count = try? await store.query(
                    "SELECT count(*) AS n FROM \(AnalysisStore.quoted(name))")
                summaries.append(TableSummary(
                    name: name,
                    columns: columns,
                    rowCount: count?.rows.first?.first.flatMap { $0 }.flatMap { Int($0) }))
            }
            tables = summaries
            // The store itself is always in this list; an external database
            // shows up here the moment it is attached (§12.2).
            attached = try await store.attachedDatabases()
        } catch {
            log.error("catalogue: \(error)")
            status = Status(message: "อ่านรายชื่อตารางไม่ได้: \(error)", isError: true)
        }
    }

    // MARK: - notebooks

    public func newNotebook() {
        let created = Notebook()
        notebook = created
        save()
    }

    public func open(_ selected: Notebook) {
        save()
        notebook = selected
        cellStates = [:]
    }

    public func delete(_ target: Notebook) {
        try? library?.delete(target.id)
        if notebook?.id == target.id { notebook = nil }
        notebooks = library?.list() ?? []
        notebook = notebook ?? notebooks.first
    }

    /// Writes the open notebook out. Called on every structural change rather
    /// than on a timer: a notebook that loses the cell you just typed is a
    /// notebook you stop trusting.
    public func save() {
        guard let library, let notebook else { return }
        do {
            let saved = try library.save(notebook)
            self.notebook = saved
            notebooks = library.list()
        } catch {
            log.error("save notebook: \(error)")
            status = Status(message: "บันทึกสมุดงานไม่ได้: \(error)", isError: true)
        }
    }

    public func rename(_ title: String) {
        notebook?.title = title
        save()
    }

    public func setScope(_ scope: Scope) {
        notebook?.scope = scope
        save()
    }

    public func addCell(kind: NotebookCell.Kind) {
        notebook?.cells.append(NotebookCell(kind: kind))
        save()
    }

    public func removeCell(_ id: String) {
        notebook?.cells.removeAll { $0.id == id }
        cellStates[id] = nil
        save()
    }

    public func setKind(_ kind: NotebookCell.Kind, for id: String) {
        guard let index = notebook?.cells.firstIndex(where: { $0.id == id }) else { return }
        notebook?.cells[index].kind = kind
        cellStates[id] = .idle
        save()
    }

    public func source(for id: String) -> String {
        notebook?.cells.first { $0.id == id }?.source ?? ""
    }

    public func setSource(_ text: String, for id: String) {
        guard let index = notebook?.cells.firstIndex(where: { $0.id == id }) else { return }
        notebook?.cells[index].source = text
    }

    public func state(for id: String) -> CellState { cellStates[id] ?? .idle }

    /// What the cell would do, for the label next to the run button. The same
    /// call the runner will make when it decides whether to refuse.
    public func effect(for cell: NotebookCell) -> SQLAssessment? {
        runner?.assess(cell)
    }

    // MARK: - running cells

    public func run(_ id: String, confirmed: Bool = false) async {
        guard let runner, let cell = notebook?.cells.first(where: { $0.id == id }) else { return }
        save()
        cellStates[id] = .running
        let startedAt = Date()
        do {
            let outcome = try await runner.run(cell, confirmed: confirmed)
            cellStates[id] = .done(outcome, seconds: Date().timeIntervalSince(startedAt))
            if case .sql(let results) = outcome,
               results.contains(where: { $0.statement.effect > .read }) {
                await refresh()
            }
        } catch let error as NotebookError {
            if case .needsConfirmation(let assessment) = error {
                cellStates[id] = .idle
                confirmation = Confirmation(assessment: assessment, source: .cell(id))
            } else {
                cellStates[id] = .failed("\(error)")
            }
        } catch {
            cellStates[id] = .failed("\(error)")
        }
    }

    /// Runs every cell in order, stopping at the first failure — a notebook is
    /// a sequence, and running cell 5 after cell 4 failed produces results that
    /// look real and are not.
    public func runAll() async {
        guard let cells = notebook?.cells else { return }
        for cell in cells {
            await run(cell.id)
            if case .failed = state(for: cell.id) { break }
            // A cell waiting for confirmation stops the run too: the answer is
            // the user's, and the cells after it depend on it.
            if confirmation != nil { break }
        }
    }

    // MARK: - the kernel

    public func startKernel() async {
        guard let kernel else { return }
        kernelState = .starting
        do {
            try await kernel.start()
            kernelState = .ready(version: await kernel.pythonVersion ?? "?")
        } catch {
            log.error("kernel start: \(error)")
            kernelState = .unavailable("\(error)")
        }
    }

    public func restartKernel() async {
        guard let kernel else { return }
        kernelState = .starting
        do {
            try await kernel.restart()
            kernelState = .ready(version: await kernel.pythonVersion ?? "?")
            // Say it plainly: a restart is how the state goes away, and that is
            // usually the reason for pressing it.
            status = Status(message: "เริ่มเคอร์เนลใหม่แล้ว — ตัวแปรทั้งหมดหายไป", isError: false)
        } catch {
            kernelState = .unavailable("\(error)")
        }
    }

    public func stopKernel() async {
        await kernel?.stop()
        kernelState = .stopped
    }

    public func interruptKernel() async {
        await kernel?.interrupt()
    }

    // MARK: - the explorer

    /// The explorer runs through the same runner as a notebook cell — a
    /// throwaway cell, but the same code path, so there is exactly one place
    /// that decides whether a statement needs confirming (P6.5).
    public func runExplorer(confirmed: Bool = false) async {
        guard let runner else { return }
        explorerError = nil
        let cell = NotebookCell(kind: .sql, source: explorerSQL)
        do {
            let outcome = try await runner.run(cell, confirmed: confirmed)
            guard case .sql(let results) = outcome else { return }
            explorerResults = results
            if results.contains(where: { $0.statement.effect > .read }) { await refresh() }
        } catch let error as NotebookError {
            explorerResults = []
            if case .needsConfirmation(let assessment) = error {
                confirmation = Confirmation(assessment: assessment, source: .explorer)
            } else if case .emptyCell = error {
                return
            } else {
                explorerError = "\(error)"
            }
        } catch {
            explorerResults = []
            explorerError = "\(error)"
        }
    }

    /// Reads a CSV or Parquet file in. It goes through the runner too, because
    /// an import is `CREATE OR REPLACE` over whatever already had that name,
    /// which is exactly what the guard is for.
    public func importFile(_ url: URL, confirmed: Bool = false) async {
        guard let runner else { return }
        let table = url.deletingPathExtension().lastPathComponent
        let cell = NotebookCell(kind: .sql,
                                source: AnalysisStore.importStatement(url, into: table))
        do {
            _ = try await runner.run(cell, confirmed: confirmed)
            await refresh()
            status = Status(message: "นำเข้า \(url.lastPathComponent) เป็นตาราง \(table) แล้ว",
                            isError: false)
        } catch let error as NotebookError {
            if case .needsConfirmation(let assessment) = error {
                confirmation = Confirmation(assessment: assessment,
                                            source: .importFile(url, table: table))
            } else {
                status = Status(message: "นำเข้าไม่สำเร็จ: \(error)", isError: true)
            }
        } catch {
            status = Status(message: "นำเข้าไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: - the analysis plan

    public func loadPlans() async {
        guard let planStore else { return }
        do {
            plans = try await planStore.load(scope: scope).map(\.plan)
            if let current = plan?.id { plan = plans.first { $0.id == current } ?? plan }
            else { plan = plans.first }
        } catch {
            log.error("load plans: \(error)")
        }
    }

    /// Nil goes back to the proposal box — "new plan" is "read another
    /// proposal", because §12.4 does not have a blank plan in it.
    public func open(plan selected: AnalysisPlan?) {
        plan = selected
        if selected == nil { proposalText = ""; planTitle = "" }
    }

    public func deletePlan(_ target: AnalysisPlan) async {
        guard let planStore else { return }
        try? await planStore.delete(target.id)
        if plan?.id == target.id { plan = nil }
        await loadPlans()
    }

    /// Reads a proposal and turns it into a plan plus a Gap Report (§12.4).
    ///
    /// The model reads the prose; the gaps are then found by comparing what it
    /// read against the columns that actually exist in the analysis store. If
    /// the model cannot be reached the plan is not built at all — a plan with
    /// no gaps because nothing was read is the worst possible output.
    public func readProposal() async {
        guard let detector else { return }
        let text = proposalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 40 else {
            status = Status(message: "วางข้อความโครงร่างก่อน (ยาวกว่านี้)", isError: true)
            return
        }
        isReadingProposal = true
        defer { isReadingProposal = false }

        guard let reading = await detector.read(proposal: text) else {
            status = Status(message: "อ่านโครงร่างไม่สำเร็จ — โมเดลตอบไม่ได้ ยังไม่สร้างแผน "
                            + "(แผนที่ว่างเพราะอ่านไม่ได้ อันตรายกว่าไม่มีแผน)", isError: true)
            return
        }
        await refresh()
        let snapshot = SchemaSnapshot(fields: tables.flatMap { table in
            table.columns.map { SchemaSnapshot.Field(table: table.name, name: $0.name,
                                                     type: $0.type) }
        })
        let built = GapDetector.plan(
            title: planTitle.isEmpty ? "แผนวิเคราะห์จากโครงร่าง" : planTitle,
            scope: scope, reading: reading, proposalText: text, schema: snapshot)
        plan = built
        await savePlan()
        status = Status(message: "อ่านโครงร่างแล้ว — พบช่องว่าง \(built.openGaps.count) จุด",
                        isError: false)
    }

    public func confirm(decision id: String, value: String? = nil) async {
        plan?.confirm(id, value: value)
        await savePlan()
    }

    public func resolve(gap id: String, with answer: String) async {
        plan?.resolve(gap: id, with: answer)
        await savePlan()
    }

    /// Approves the plan as a block (§12.4). The refusal is the type's, not
    /// this screen's: `approve(by:)` throws while an `agent_suggested` decision
    /// or a blocking gap is still there.
    public func approvePlan() async {
        guard plan != nil else { return }
        do {
            try plan?.approve(by: "ผู้ใช้")
            await savePlan()
            status = Status(message: "อนุมัติแผนแล้ว — การแก้แผนหลังจากนี้จะถอนการอนุมัติเอง",
                            isError: false)
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    private func savePlan() async {
        guard let planStore, let plan else { return }
        do {
            try await planStore.save(plan)
            await loadPlans()
        } catch {
            log.error("save plan: \(error)")
            status = Status(message: "บันทึกแผนไม่ได้: \(error)", isError: true)
        }
    }

    // MARK: - the confirmation

    public func confirm() async {
        guard let pending = confirmation else { return }
        confirmation = nil
        switch pending.source {
        case .cell(let id): await run(id, confirmed: true)
        case .explorer: await runExplorer(confirmed: true)
        case .importFile(let url, let table):
            _ = table
            await importFile(url, confirmed: true)
        }
    }

    public func cancelConfirmation() {
        confirmation = nil
    }

    public func clearStatus() { status = nil }
}
