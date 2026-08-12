import Foundation
import Observation
import AgentKit
import Analysis
import CoreEngine
import DocGen
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
    /// Saved connections to other people's databases (§12.2, P6.3).
    public private(set) var connectors: [DBConnector] = []
    /// Tables of each attached database, filled in as they are connected.
    public private(set) var externalTables: [String: [String]] = [:]

    // MARK: - the analysis plan (§12.4)

    public private(set) var plans: [AnalysisPlan] = []
    public private(set) var plan: AnalysisPlan?
    /// §14.1 / P7.9 — templates parsed from documents the user uploaded, and
    /// which one the next export should be poured into. Nil means "our own
    /// layout", which is what P7.6 already produced.
    public private(set) var templates: [DocumentTemplate] = []
    public private(set) var selectedTemplateID: String?
    /// The proposal being read. Pasted for now — reading it straight out of
    /// the knowledge base needs a `doc_type` the ingest pipeline does not
    /// record yet.
    public var proposalText = ""
    public var planTitle = ""
    public private(set) var isReadingProposal = false
    /// Documents already in the knowledge base, so a proposal that was
    /// ingested does not have to be pasted a second time.
    public private(set) var knowledgeDocuments: [(id: String, title: String)] = []
    /// Which document the open plan was read from, when it came from the KB.
    public private(set) var proposalDocumentID: String?

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
    private var connectorStore: ConnectorStore?
    private var knowledge: KnowledgeStore?
    private var planStore: AnalysisPlanStore?
    private var templateStore: TemplateStore?
    private var detector: GapDetector?
    private var scope: Scope = .central
    private let log = AppLog.logger("analysis-ui")

    public init() {}

    public func attach(plans store: AnalysisPlanStore, detector: GapDetector,
                       knowledge: KnowledgeStore? = nil, scope: Scope = .central) async {
        self.planStore = store
        self.detector = detector
        self.knowledge = knowledge
        self.scope = scope
        await loadPlans()
        await loadKnowledgeDocuments()
    }

    /// §14.1 / P7.9 — the templates learned from documents the user already
    /// had. Attached here rather than read at export time so the picker beside
    /// the export button has something in it before anybody clicks.
    public func attach(templates store: TemplateStore) {
        self.templateStore = store
        templates = store.load()
    }

    /// Learns a template from a document somebody uploads, and keeps it.
    ///
    /// The failure is worth reporting rather than swallowing: a file with no
    /// headings cannot be a template, and "nothing happened" is the least
    /// useful thing to show someone who just chose a file.
    public func importTemplate(from url: URL) {
        guard let templateStore else { return }
        // A file chosen from a panel is outside the sandbox until it is
        // opened this way; without the scope the read fails with a permission
        // error that reads like a corrupt file.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let template = try TemplateParser.parse(docx: url)
            templates = try templateStore.add(template)
            selectedTemplateID = template.id
            status = Status(message: "อ่านแม่แบบ '\(template.name)' แล้ว — "
                            + "\(template.sections.count) หัวข้อ", isError: false)
        } catch {
            status = Status(message: "ใช้ไฟล์นี้เป็นแม่แบบไม่ได้: "
                            + ((error as? TemplateError)?.description ?? "\(error)"),
                            isError: true)
        }
    }

    public func removeTemplate(_ id: String) {
        guard let templateStore else { return }
        try? templateStore.remove(id)
        templates = templateStore.load()
        if selectedTemplateID == id { selectedTemplateID = nil }
    }

    public func selectTemplate(_ id: String?) { selectedTemplateID = id }

    /// The documents that could be a proposal.
    ///
    /// §12.4 says the trigger is `doc_type: proposal`, and the ingest pipeline
    /// does not record a document type yet — so this lists everything and lets
    /// a person point at the right one, rather than filtering on a field that
    /// does not exist and quietly showing nothing.
    public func loadKnowledgeDocuments() async {
        guard let knowledge else { return }
        let chunks = (try? await knowledge.load(scope: scope)) ?? []
        var seen: [String: String] = [:]
        for chunk in chunks where seen[chunk.provenance.documentID] == nil {
            seen[chunk.provenance.documentID] = chunk.provenance.title
        }
        knowledgeDocuments = seen.map { (id: $0.key, title: $0.value) }
            .sorted { $0.title < $1.title }
    }

    /// Loads a document out of the knowledge base into the proposal box, in
    /// the order its chunks were written.
    public func useDocument(_ documentID: String) async {
        guard let knowledge else { return }
        let chunks = ((try? await knowledge.load(scope: scope)) ?? [])
            .filter { $0.provenance.documentID == documentID }
        guard !chunks.isEmpty else {
            status = Status(message: "อ่านเอกสารนี้จากคลังความรู้ไม่ได้", isError: true)
            return
        }
        proposalText = chunks.map(\.text).joined(separator: "\n")
        proposalDocumentID = documentID
        if planTitle.isEmpty { planTitle = chunks[0].provenance.title }
    }

    public func attach(connectors store: ConnectorStore) {
        connectorStore = store
        connectors = store.load(scope: scope)
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
        // A sandboxed app reaches a file the user chose **only inside this
        // scope**, and DuckDB opens the path itself — so without this the
        // import fails with a raw `IO Error: Cannot open file`, which is what
        // it did until somebody drove this screen by hand (U19, 2026-08-12).
        // Held across the confirmation round-trip too: the second call is the
        // one that actually reads.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

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
                status = Status(message: Self.importFailure(error, file: url), isError: true)
            }
        } catch {
            status = Status(message: Self.importFailure(error, file: url), isError: true)
        }
    }

    /// What went wrong, in words rather than in a nested `Optional(...)`.
    ///
    /// The raw description of a DuckDB failure is `connectionQueryError(reason:
    /// Optional("IO Error: Cannot open file \"…` — which the status line then
    /// truncates, so the one useful sentence is the part that gets cut. The
    /// most common cause has a fix a person can act on, so it is named.
    static func importFailure(_ error: any Error, file: URL) -> String {
        let raw = "\(error)"
        if raw.contains("Cannot open file") || raw.contains("IO Error") {
            return "อ่านไฟล์ \(file.lastPathComponent) ไม่ได้ — "
                + "แอปเข้าถึงไฟล์นี้ไม่ได้ (สิทธิ์ของ sandbox) ลองเลือกไฟล์ใหม่อีกครั้ง "
                + "หรือย้ายไฟล์ไปโฟลเดอร์เอกสารก่อน"
        }
        return "นำเข้า \(file.lastPathComponent) ไม่สำเร็จ: \(raw)"
    }

    // MARK: - external databases (§12.2)

    public func isConnected(_ connector: DBConnector) -> Bool {
        attached.contains(connector.alias)
    }

    /// Re-reads the saved sources. Called when the add sheet closes — see the
    /// note at that call site.
    public func reloadConnectors() {
        guard let connectorStore else { return }
        connectors = connectorStore.load(scope: scope)
    }

    public func save(connector: DBConnector) {
        guard let connectorStore else { return }
        do {
            connectors = try connectorStore.add(connector).filter {
                $0.scope == scope || $0.scope == .central
            }
        } catch {
            status = Status(message: "บันทึกแหล่งข้อมูลไม่ได้: \(error)", isError: true)
        }
    }

    public func remove(connector: DBConnector) async {
        guard let connectorStore else { return }
        if isConnected(connector) { await disconnect(connector) }
        connectors = ((try? connectorStore.remove(connector.id)) ?? []).filter {
            $0.scope == scope || $0.scope == .central
        }
    }

    /// Connects on request rather than at boot.
    ///
    /// Deliberately not automatic: attaching a remote database reaches across
    /// the network and can want a password, and neither belongs in the path of
    /// opening a screen. What the screen does instead is show plainly which
    /// connections are live.
    public func connect(_ connector: DBConnector) async {
        guard let store else { return }
        do {
            try await store.attach(connector)
            externalTables[connector.alias] = try await store.tables(in: connector.alias)
            await refresh()
            status = Status(message: "ต่อ \(connector.alias) แล้ว — "
                            + "\(externalTables[connector.alias]?.count ?? 0) ตาราง", isError: false)
        } catch {
            // Whatever comes back here has already had any password scrubbed
            // out of it (P6.3).
            status = Status(message: "\(error)", isError: true)
        }
    }

    public func disconnect(_ connector: DBConnector) async {
        guard let store else { return }
        try? await store.detach(connector.alias)
        externalTables[connector.alias] = nil
        await refresh()
    }

    /// Copies a remote table in. Goes through the runner like every other
    /// statement, so `CREATE OR REPLACE` over an existing local table is
    /// confirmed rather than assumed (P6.5).
    public func pull(_ table: String, from alias: String) async {
        guard let runner else { return }
        let sql = """
        CREATE OR REPLACE TABLE \(AnalysisStore.quoted("\(alias)_\(table)")) AS
        SELECT * FROM \(AnalysisStore.quoted(alias)).\(AnalysisStore.quoted(table))
        """
        do {
            _ = try await runner.run(NotebookCell(kind: .sql, source: sql))
            await refresh()
            status = Status(message: "ดึง \(alias).\(table) เข้ามาแล้ว", isError: false)
        } catch let error as NotebookError {
            if case .needsConfirmation(let assessment) = error {
                confirmation = Confirmation(assessment: assessment, source: .explorer)
                explorerSQL = sql
            } else {
                status = Status(message: "\(error)", isError: true)
            }
        } catch {
            status = Status(message: "\(error)", isError: true)
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
    /// What §14.1 will write into the document's Limitations section, from
    /// this plan alone. Shown while the plan is still being settled, because
    /// an assumption reads differently once you can see the sentence it turns
    /// into.
    public var limitationsPreview: LimitationsSection {
        LimitationsBuilder.build(plan: plan)
    }

    /// The plan as a document (§14.1, P7.6).
    ///
    /// A pre-registration is a thing you send to somebody — an ethics
    /// committee, a supervisor, a co-author — so it has to leave the app as a
    /// file. Built from the plan itself: every decision with the tag that says
    /// where it came from, and the Limitations section §14.1 writes out of the
    /// assumptions.
    public func exportPlan(to url: URL) {
        guard let plan else { return }
        let decisions = plan.decisions.map { decision in
            "\(decision.question): \(decision.value) — \(decision.origin.label)"
                + (decision.note.map { " (\($0))" } ?? "")
        }
        var sections = [Section(heading: "การตัดสินใจในแผน",
                                paragraphs: [.bullets(decisions)])]
        if !plan.openGaps.isEmpty {
            sections.append(Section(heading: "ช่องว่างที่ยังเปิดอยู่", paragraphs: [
                .bullets(plan.openGaps.map { "\($0.severity.label): \($0.subject) — \($0.detail)" }),
            ]))
        }
        sections.append(Section(heading: "สถานะการอนุมัติ", paragraphs: [
            .plain(plan.isApproved
                   ? "อนุมัติแล้วโดย \(plan.approvedBy ?? "-") — การแก้แผนหลังจากนี้จะถอนการอนุมัติเอง"
                   : "ยังไม่อนุมัติ: " + plan.blockers.joined(separator: " · ")),
        ]))

        var draft = DocumentDraft(title: plan.title,
                                  sections: sections,
                                  limitations: limitationsPreview)

        // P7.9 — poured into the shape somebody's own document had, if they
        // chose one. What is missing from it is said out loud: the reason to
        // use a template is usually that a committee expects those headings,
        // and finding out which ones are empty after sending it is too late.
        var note = ""
        if let selectedTemplateID,
           let template = templates.first(where: { $0.id == selectedTemplateID }) {
            let applied = TemplateFiller.apply(template, to: draft)
            draft = applied.draft
            note = " · แม่แบบ '\(template.name)'"
            if !applied.missing.isEmpty {
                note += " — ยังไม่มีเนื้อหาใน: " + applied.missing.joined(separator: ", ")
            }
        }

        do {
            // Nothing is cited from the knowledge base in this document, so the
            // audit has nothing to refuse; it still runs, because the rule
            // belongs to the builder rather than to each caller.
            let rendered = try DocumentBuilder.render(draft)
            try OfficeWriter.docx(rendered).write(to: url)
            status = Status(message: "บันทึกเอกสารที่ \(url.lastPathComponent) แล้ว" + note,
                            isError: false)
        } catch {
            status = Status(message: "สร้างเอกสารไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func open(plan selected: AnalysisPlan?) {
        plan = selected
        if selected == nil { proposalText = ""; planTitle = ""; proposalDocumentID = nil }
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
            scope: scope, reading: reading, proposalText: text,
            proposalDocumentID: proposalDocumentID, schema: snapshot)
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
