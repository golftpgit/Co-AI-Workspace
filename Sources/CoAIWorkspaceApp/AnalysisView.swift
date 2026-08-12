import SwiftUI
import UniformTypeIdentifiers
import AgentKit
import Analysis
import CoreEngine

// ─────────────────────────────────────────────────────────────
// Notebook and DB explorer (ARCHITECTURE §12.5, §14.2, P6.8).
//
// Two surfaces on one screen because they are one job: look at what is in the
// store, then write the analysis. They share the store, the result table and —
// the part §12.5 is emphatic about — the same SQL guard.
//
// The DB explorer is full read/write and deliberately outside the approval gate
// (§14.2): it is a person typing SQL at their own database, not an agent asking
// for permission. The confirmation sheet is the only thing between a DROP and a
// dropped table, which is why it shows the statements verbatim.
// ─────────────────────────────────────────────────────────────

struct AnalysisView: View {
    @Bindable var model: AnalysisViewModel
    @State private var pane = Pane.notebook

    enum Pane: String, CaseIterable, Identifiable {
        case notebook, explorer, plan
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notebook: "สมุดงาน"
            case .explorer: "ฐานข้อมูล"
            case .plan: "แผนวิเคราะห์"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if pane == .plan {
                // The plan does not need the store to be open — it is about
                // the method, and it is written before anything runs.
                PlanPane(model: model)
            } else if model.storeIsOpen {
                switch pane {
                case .notebook: NotebookPane(model: model)
                case .explorer: ExplorerPane(model: model)
                case .plan: EmptyView()
                }
            } else {
                // A closed store is not an empty database, and the screen must
                // not let those look the same.
                ContentUnavailableView(
                    "เปิดฐานข้อมูลวิเคราะห์ไม่ได้",
                    systemImage: "exclamationmark.triangle",
                    description: Text("ไฟล์ analysis.duckdb เปิดไม่ได้ตอนเริ่มแอป — "
                                      + "ส่วนอื่นของแอปยังทำงานตามปกติ ดูรายละเอียดที่หน้าสถานะระบบ"))
            }
        }
        .task { await model.refresh() }
        .sheet(item: $model.confirmation) { pending in
            ConfirmSheet(model: model, pending: pending)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("มุมมอง", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            Spacer()

            if let status = model.status {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.isError ? .red : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .trailing)
                    .onTapGesture { model.clearStatus() }
            }
        }
        .padding(12)
    }
}

// ─────────────────────────────────────────────────────────────
// The notebook
// ─────────────────────────────────────────────────────────────

private struct NotebookPane: View {
    @Bindable var model: AnalysisViewModel

    var body: some View {
        HStack(spacing: 0) {
            library
            Divider()
            if let notebook = model.notebook {
                cells(of: notebook)
            } else {
                ContentUnavailableView("ยังไม่มีสมุดงาน", systemImage: "square.grid.3x1.below.line.grid.1x2",
                                       description: Text("กด + เพื่อสร้างสมุดงานแรก"))
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("สมุดงาน").font(.subheadline).bold()
                Spacer()
                Button { model.newNotebook() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("สร้างสมุดงานใหม่")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            List {
                ForEach(model.notebooks) { notebook in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notebook.title).lineLimit(1)
                        Text("\(notebook.cells.count) เซลล์ · \(scopeLabel(notebook.scope))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(notebook) }
                    .listRowBackground(notebook.id == model.notebook?.id
                                       ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contextMenu {
                        Button("ลบ", role: .destructive) { model.delete(notebook) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 200)
    }

    @ViewBuilder
    private func cells(of notebook: Notebook) -> some View {
        VStack(spacing: 0) {
            notebookBar(notebook)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(notebook.cells) { cell in
                        CellView(model: model, cell: cell)
                    }
                    HStack {
                        Button { model.addCell(kind: .sql) } label: {
                            Label("เพิ่มเซลล์ SQL", systemImage: "plus")
                        }
                        Button { model.addCell(kind: .python) } label: {
                            Label("เพิ่มเซลล์ Python", systemImage: "plus")
                        }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
                .padding(14)
            }
        }
    }

    private func notebookBar(_ notebook: Notebook) -> some View {
        HStack(spacing: 10) {
            TextField("ชื่อสมุดงาน", text: Binding(
                get: { notebook.title },
                set: { model.rename($0) }))
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: 280)

            Button { Task { await model.runAll() } } label: {
                Label("รันทั้งหมด", systemImage: "play.fill")
            }

            Spacer()
            KernelBadge(model: model)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func scopeLabel(_ scope: Scope) -> String {
        switch scope {
        case .central: "ส่วนกลาง"
        case .policy: "นโยบาย"
        case .project(let id): "โปรเจกต์ \(id.rawValue)"
        }
    }
}

private struct KernelBadge: View {
    @Bindable var model: AnalysisViewModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.kernelState {
            case .unavailable(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            case .stopped:
                Text("เคอร์เนล Python: ยังไม่ได้เริ่ม").font(.caption).foregroundStyle(.secondary)
                Button("เริ่มเคอร์เนล") { Task { await model.startKernel() } }
            case .starting:
                ProgressView().controlSize(.small)
                Text("กำลังเริ่มเคอร์เนล…").font(.caption).foregroundStyle(.secondary)
            case .ready(let version):
                Label("Python \(version)", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.green)
                // Says what it costs before it is pressed: a restart is how the
                // variables go away.
                Button("เริ่มใหม่") { Task { await model.restartKernel() } }
                    .help("ล้างตัวแปรทั้งหมดแล้วเริ่มเคอร์เนลใหม่")
                Button("ปลดออก") { Task { await model.stopKernel() } }
                    .help("คืนหน่วยความจำที่เคอร์เนลถืออยู่")
            case .busy:
                ProgressView().controlSize(.small)
                Button("ขัดจังหวะ") { Task { await model.interruptKernel() } }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

private struct CellView: View {
    @Bindable var model: AnalysisViewModel
    let cell: NotebookCell

    private var isRunning: Bool {
        if case .running = model.state(for: cell.id) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("ชนิด", selection: Binding(
                    get: { cell.kind },
                    set: { model.setKind($0, for: cell.id) })) {
                        ForEach(NotebookCell.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 140)

                // What this cell would do, before it is run. The same
                // assessment the runner will enforce — not a second opinion.
                if let assessment = model.effect(for: cell), assessment.needsConfirmation {
                    Label(assessment.effect.label,
                          systemImage: assessment.effect == .destructive
                              ? "exclamationmark.octagon" : "pencil")
                        .font(.caption)
                        .foregroundStyle(assessment.effect == .destructive ? .red : .orange)
                }

                Spacer()

                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.run(cell.id) } } label: {
                        Image(systemName: "play.fill")
                    }
                    .accessibilityLabel("รันเซลล์นี้")
                }
                Button(role: .destructive) { model.removeCell(cell.id) } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("ลบเซลล์นี้")
            }
            .buttonStyle(.borderless)

            TextEditor(text: Binding(get: { model.source(for: cell.id) },
                                     set: { model.setSource($0, for: cell.id) }))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))

            CellOutputView(state: model.state(for: cell.id))
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CellOutputView: View {
    let state: AnalysisViewModel.CellState

    var body: some View {
        switch state {
        case .idle, .running:
            EmptyView()
        case .failed(let message):
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .done(let outcome, let seconds):
            VStack(alignment: .leading, spacing: 6) {
                switch outcome {
                case .sql(let results):
                    // One table per statement: a cell that ran three
                    // statements and showed one table has hidden two results.
                    ForEach(results) { entry in
                        if results.count > 1 {
                            Text(entry.statement.text)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ResultTable(result: entry.result)
                    }
                case .python(let output):
                    PythonOutputView(output: output)
                }
                Text(String(format: "%.2f วินาที", seconds))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct PythonOutputView: View {
    let output: CellOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !output.stdout.isEmpty {
                Text(output.stdout)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            if !output.stderr.isEmpty {
                Text(output.stderr)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if let value = output.value {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .bold()
                    .textSelection(.enabled)
            }
            if let error = output.error {
                // Verbatim, on purpose: §13's rule that compiler output goes
                // back raw rather than summarised is the same rule.
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// The DB explorer
// ─────────────────────────────────────────────────────────────

private struct ExplorerPane: View {
    @Bindable var model: AnalysisViewModel
    @State private var importing = false
    @State private var addingConnector = false

    var body: some View {
        HStack(spacing: 0) {
            catalogue
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $model.explorerSQL)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.25))

                HStack(spacing: 10) {
                    Button { Task { await model.runExplorer() } } label: {
                        Label("รัน", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)

                    let assessment = SQLGuard.assess(model.explorerSQL)
                    if assessment.needsConfirmation {
                        Label(assessment.summary,
                              systemImage: assessment.effect == .destructive
                                  ? "exclamationmark.octagon" : "pencil")
                            .font(.caption)
                            .foregroundStyle(assessment.effect == .destructive ? .red : .orange)
                    }
                    Spacer()
                    // §14.2 is explicit that this screen is read/write; being
                    // able to get data in is what makes it usable at all.
                    Button { importing = true } label: {
                        Label("นำเข้า CSV/Parquet", systemImage: "square.and.arrow.down")
                    }
                }
                .padding(10)

                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let error = model.explorerError {
                            Text(error)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        ForEach(model.explorerResults) { entry in
                            if model.explorerResults.count > 1 {
                                Text(entry.statement.text)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            ResultTable(result: entry.result)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.commaSeparatedText, .data]) { result in
            if case .success(let url) = result {
                Task { await model.importFile(url) }
            }
        }
    }

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ตารางในสโตร์").font(.subheadline).bold()
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("อ่านรายชื่อตารางใหม่")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            List {
                ForEach(model.tables) { table in
                    DisclosureGroup {
                        ForEach(table.columns, id: \.name) { column in
                            HStack {
                                Text(column.name).font(.caption)
                                Spacer()
                                Text(column.type).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(table.name).font(.callout)
                            Text(table.rowCount.map { "\($0) แถว" } ?? "นับแถวไม่ได้")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.explorerSQL = "SELECT * FROM \(AnalysisStore.quoted(table.name)) LIMIT 100"
                        }
                    }
                }
                Section {
                    ForEach(model.connectors) { connector in
                        ConnectorRow(model: model, connector: connector)
                    }
                    // Named rather than omitted: a list with two silent
                    // failures in it is worse than one that says why (§12.2).
                    ForEach(UnsupportedConnector.allCases) { kind in
                        Label("\(kind.label) — ยังต่อไม่ได้", systemImage: "minus.circle")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .help(kind.reason)
                    }
                } header: {
                    HStack {
                        Text("แหล่งข้อมูลภายนอก")
                        Spacer()
                        Button { addingConnector = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("เพิ่มแหล่งข้อมูลภายนอก")
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 230)
        .sheet(isPresented: $addingConnector) {
            ConnectorSheet(model: model, isPresented: $addingConnector)
        }
    }
}

private struct ConnectorRow: View {
    @Bindable var model: AnalysisViewModel
    let connector: DBConnector

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: model.isConnected(connector) ? "circle.fill" : "circle")
                    .font(.system(size: 7))
                    .foregroundStyle(model.isConnected(connector) ? .green : .secondary)
                Text(connector.alias).font(.callout)
                Spacer()
                if model.isConnected(connector) {
                    Button("ปลด") { Task { await model.disconnect(connector) } }
                } else {
                    Button("ต่อ") { Task { await model.connect(connector) } }
                        // Says why before it is pressed, rather than failing
                        // with a driver error afterwards.
                        .disabled(!connector.secretIsAvailable)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Text(connector.kind.rawValue + (connector.readOnly ? " · อ่านอย่างเดียว" : " · เขียนได้"))
                .font(.caption2).foregroundStyle(.secondary)
            if let variable = connector.secretVariable, !connector.secretIsAvailable {
                Text("ยังไม่ได้ตั้ง \(variable)")
                    .font(.caption2).foregroundStyle(.orange)
            }
            ForEach(model.externalTables[connector.alias] ?? [], id: \.self) { table in
                HStack {
                    Text(table).font(.caption2)
                    Spacer()
                    Button("ดึงเข้ามา") { Task { await model.pull(table, from: connector.alias) } }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.explorerSQL = "SELECT * FROM \(AnalysisStore.quoted(connector.alias))."
                        + "\(AnalysisStore.quoted(table)) LIMIT 100"
                }
            }
        }
        .contextMenu {
            Button("ลบแหล่งนี้", role: .destructive) {
                Task { await model.remove(connector: connector) }
            }
        }
    }
}

/// Adding a connection. The password field is deliberately absent: what is
/// stored is the *name of an environment variable*, the same shape §9.3's
/// endpoint registry settled on, so the file on disk cannot log anybody in.
private struct ConnectorSheet: View {
    @Bindable var model: AnalysisViewModel
    @Binding var isPresented: Bool
    @State private var alias = ""
    @State private var kind = ConnectorKind.sqlite
    @State private var target = ""
    @State private var secretVariable = ""
    @State private var readOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("เพิ่มแหล่งข้อมูลภายนอก").font(.headline)

            Picker("ชนิด", selection: $kind) {
                ForEach(ConnectorKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField("ชื่อที่ใช้ใน SQL (เช่น lab)", text: $alias)
            TextField(kind == .sqlite ? "เส้นทางไฟล์ .sqlite"
                                      : "host=… port=… dbname=… user=… (ไม่ต้องใส่รหัสผ่าน)",
                      text: $target)
            if kind != .sqlite {
                TextField("ชื่อตัวแปรสภาพแวดล้อมที่เก็บรหัสผ่าน (เช่น PGPASSWORD)",
                          text: $secretVariable)
                Text("รหัสผ่านไม่ถูกเก็บลงไฟล์ — เก็บแค่ชื่อตัวแปร และอ่านค่าตอนต่อเท่านั้น")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("อ่านอย่างเดียว", isOn: $readOnly)
            Text("§12.2 ตั้งค่าเริ่มต้นเป็นอ่านอย่างเดียว เพราะข้อมูลปลายทางมักเป็นของคนอื่น")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("ยกเลิก", role: .cancel) { isPresented = false }
                Button("บันทึกและต่อ") {
                    let connector = DBConnector(
                        alias: alias.trimmingCharacters(in: .whitespaces),
                        kind: kind,
                        target: target.trimmingCharacters(in: .whitespaces),
                        secretVariable: secretVariable.isEmpty ? nil : secretVariable,
                        readOnly: readOnly)
                    model.save(connector: connector)
                    isPresented = false
                    Task { await model.connect(connector) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(alias.trimmingCharacters(in: .whitespaces).isEmpty
                          || target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(18)
        .frame(width: 460)
    }
}

// ─────────────────────────────────────────────────────────────
// The Analysis Plan (§12.4)
//
// A pre-registration: the method is agreed before the numbers are seen. The
// screen's job is to make the two things §12.4 cares about impossible to miss —
// which decisions are still only the agent's idea, and what is blocking
// approval — and then to get out of the way. It enforces nothing itself:
// `AnalysisPlan.approve(by:)` throws, and this shows what it threw.
// ─────────────────────────────────────────────────────────────

private struct PlanPane: View {
    @Bindable var model: AnalysisViewModel
    @State private var exporting = false
    @State private var importingTemplate = false

    var body: some View {
        HStack(spacing: 0) {
            list
            Divider()
            if let plan = model.plan {
                detail(plan)
            } else {
                proposalEntry
            }
        }
        .task { await model.loadPlans() }
        .fileExporter(isPresented: $exporting,
                      document: PlanDocument(),
                      contentType: .data,
                      defaultFilename: model.plan?.title ?? "analysis-plan") { result in
            if case .success(let url) = result { model.exportPlan(to: url) }
        }
        // P7.9 — a template is learned from a document, so this is an import
        // of somebody's own file rather than a form to fill in.
        .fileImporter(isPresented: $importingTemplate,
                      allowedContentTypes: [.init(filenameExtension: "docx") ?? .data]) { result in
            if case .success(let url) = result { model.importTemplate(from: url) }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("แผนวิเคราะห์").font(.subheadline).bold()
                Spacer()
                Button { model.open(plan: nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("อ่านโครงร่างใหม่")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            List {
                ForEach(model.plans) { plan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title).lineLimit(1)
                        HStack(spacing: 4) {
                            if plan.isApproved {
                                Label("อนุมัติแล้ว", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text("ค้าง \(plan.blockers.count) ข้อ")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(plan: plan) }
                    .listRowBackground(plan.id == model.plan?.id
                                       ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contextMenu {
                        Button("ลบ", role: .destructive) { Task { await model.deletePlan(plan) } }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 220)
    }

    private var proposalEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("อ่านโครงร่างวิจัย").font(.headline)
            Text("วางข้อความโครงร่างแล้วระบบจะสกัดคำถามวิจัย ประชากร ปัจจัย ผลลัพธ์ วิธี และช่วงเวลา "
                 + "แล้วเทียบกับคอลัมน์ที่มีอยู่จริงในสโตร์ เพื่อบอกว่าอะไรยังขาด (§12.4)")
                .font(.caption).foregroundStyle(.secondary)
            TextField("ชื่อแผน", text: $model.planTitle)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

            if !model.knowledgeDocuments.isEmpty {
                HStack(spacing: 8) {
                    // §12.4 wants this to key off `doc_type: proposal`; the
                    // ingest pipeline records no document type yet, so the
                    // list is everything and the choice is the user's.
                    Menu("ใช้เอกสารจากคลังความรู้") {
                        ForEach(model.knowledgeDocuments, id: \.id) { document in
                            Button(document.title) {
                                Task { await model.useDocument(document.id) }
                            }
                        }
                    }
                    .frame(maxWidth: 260)
                    Text("หรือวางข้อความเองข้างล่าง")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $model.proposalText)
                .font(.system(.body, design: .default))
                .frame(minHeight: 180)
                .padding(6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button { Task { await model.readProposal() } } label: {
                    Label("อ่านและหาช่องว่าง", systemImage: "text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isReadingProposal)
                if model.isReadingProposal { ProgressView().controlSize(.small) }
                Spacer()
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detail(_ plan: AnalysisPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(plan)
                if !plan.openGaps.isEmpty {
                    Text("รายงานช่องว่าง (Gap Report)").font(.subheadline).bold()
                    ForEach(plan.openGaps) { gap in
                        GapRow(model: model, gap: gap)
                    }
                }
                Text("การตัดสินใจในแผน").font(.subheadline).bold()
                ForEach(plan.decisions) { decision in
                    DecisionRow(model: model, decision: decision, locked: plan.isApproved)
                }
                // §14.1 reads this plan later to write the document's
                // Limitations. Showing it here means an assumption is seen as
                // the sentence it will become, while there is still time to
                // change it.
                if !model.limitationsPreview.isEmpty {
                    Text("ข้อจำกัดที่จะขึ้นในเอกสารอัตโนมัติ (§14.1)").font(.subheadline).bold()
                    ForEach(model.limitationsPreview.items) { item in
                        Label(item.text, systemImage: "text.append")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.2),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if !plan.revisions.isEmpty {
                    Text("ประวัติการถอนอนุมัติ").font(.subheadline).bold()
                    ForEach(Array(plan.revisions.enumerated()), id: \.offset) { _, reason in
                        Label(reason, systemImage: "arrow.uturn.backward")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }

    private func header(_ plan: AnalysisPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.title).font(.headline)
                Spacer()
                // P7.9: the shape it comes out in. "แบบของเราเอง" is P7.6's
                // layout; the rest are documents this person uploaded.
                Picker("แม่แบบ", selection: Binding(
                    get: { model.selectedTemplateID },
                    set: { model.selectTemplate($0) })) {
                        Text("แบบของเราเอง").tag(String?.none)
                        ForEach(model.templates) { template in
                            Text(template.name).tag(String?.some(template.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                Button {
                    importingTemplate = true
                } label: {
                    Label("เพิ่มแม่แบบจากไฟล์", systemImage: "doc.badge.plus")
                }
                .help("เลือกไฟล์ .docx ที่มีหัวข้อครบ แล้วระบบจะจำโครงของมันไว้")
                // §14.1: a pre-registration is something you send to somebody.
                Button { exporting = true } label: {
                    Label("ส่งออก .docx", systemImage: "square.and.arrow.up")
                }
                if plan.isApproved {
                    Label("อนุมัติแล้วโดย \(plan.approvedBy ?? "")",
                          systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Button("อนุมัติแผนทั้งก้อน") { Task { await model.approvePlan() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!plan.isReadyForApproval)
                }
            }
            if !plan.isApproved {
                // Not a greyed-out button with no explanation: what is missing
                // is the actionable half.
                ForEach(Array(plan.blockers.enumerated()), id: \.offset) { _, blocker in
                    Label(blocker, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("แก้อะไรหลังจากนี้ การอนุมัติจะถูกถอนเองและต้องอนุมัติใหม่ — "
                     + "แผนที่แก้ได้เงียบๆ ไม่ใช่ pre-registration")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GapRow: View {
    @Bindable var model: AnalysisViewModel
    let gap: AnalysisGap
    @State private var answer = ""

    private var tint: Color {
        switch gap.severity {
        case .critical: .red
        case .ambiguous: .orange
        case .assumptionNeeded: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(gap.severity.label) · \(gap.subject)",
                  systemImage: gap.severity == .critical
                      ? "exclamationmark.octagon" : "questionmark.circle")
                .font(.callout).foregroundStyle(tint)
            Text(gap.detail).font(.caption).foregroundStyle(.secondary)
            if gap.options.isEmpty {
                HStack {
                    TextField("คำตอบของคุณ", text: $answer)
                        .textFieldStyle(.roundedBorder)
                    Button("บันทึกคำตอบ") {
                        Task { await model.resolve(gap: gap.id, with: answer) }
                    }
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack {
                    ForEach(gap.options, id: \.self) { option in
                        Button(option) { Task { await model.resolve(gap: gap.id, with: option) } }
                    }
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct DecisionRow: View {
    @Bindable var model: AnalysisViewModel
    let decision: AnalysisDecision
    let locked: Bool
    @State private var edited = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.question).font(.callout).bold()
                Text(decision.value).font(.body)
                if let note = decision.note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                // The audit tag §12.4 asks for, on every row, always visible.
                Text(decision.origin.label)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(background, in: Capsule())
                if decision.origin == .agentSuggested && !locked {
                    Button("ยืนยัน") {
                        Task { await model.confirm(decision: decision.id) }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    private var background: AnyShapeStyle {
        switch decision.origin {
        case .agentSuggested: AnyShapeStyle(Color.orange.opacity(0.2))
        case .humanConfirmed: AnyShapeStyle(Color.green.opacity(0.18))
        case .proposalStated: AnyShapeStyle(.quaternary)
        }
    }
}

/// A placeholder for the save panel. The bytes are written by
/// `exportPlan(to:)` once a location is chosen: `FileDocument` wants the
/// content up front, and building a document before knowing whether it will be
/// saved is work for nothing.
private struct PlanDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    init() {}
    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

// ─────────────────────────────────────────────────────────────
// Shared pieces
// ─────────────────────────────────────────────────────────────

/// A result, rendered as a table.
///
/// Two promises kept from `AnalysisStore`: NULL is shown as NULL rather than as
/// an empty cell, because one means "not known" and the other is a value
/// someone stored; and the row cap says how many rows were left out instead of
/// quietly ending the list.
private struct ResultTable: View {
    let result: QueryResult
    private let limit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if result.columns.isEmpty {
                Text("คำสั่งสำเร็จ · ไม่มีผลลัพธ์เป็นตาราง")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                        GridRow {
                            ForEach(result.columns, id: \.name) { column in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(column.name).font(.caption).bold()
                                    Text(column.type).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Divider()
                        ForEach(Array(result.rows.prefix(limit).enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                    if let value {
                                        Text(value)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                    } else {
                                        Text("NULL")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 300)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(footer)
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var footer: String {
        let shown = min(result.rowCount, limit)
        let milliseconds = Double(result.duration.components.attoseconds) / 1e15
            + Double(result.duration.components.seconds) * 1_000
        let timing = String(format: "%.0f ms", milliseconds)
        return result.rowCount > limit
            ? "แสดง \(shown) จาก \(result.rowCount) แถว · \(timing)"
            : "\(result.rowCount) แถว · \(timing)"
    }
}

/// The one thing between a typo and a dropped table.
///
/// Shows the statements verbatim rather than a count, for the same reason the
/// Conflict Card shows both sides word for word (§11.6): a summary of what is
/// about to happen is not something a person can check.
private struct ConfirmSheet: View {
    @Bindable var model: AnalysisViewModel
    let pending: AnalysisViewModel.Confirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(pending.assessment.effect == .destructive
                  ? "คำสั่งนี้ลบหรือเขียนทับข้อมูล"
                  : "คำสั่งนี้เปลี่ยนข้อมูล",
                  systemImage: pending.assessment.effect == .destructive
                      ? "exclamationmark.octagon.fill" : "pencil.circle.fill")
                .font(.headline)
                .foregroundStyle(pending.assessment.effect == .destructive ? .red : .orange)

            Text(pending.assessment.summary).font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pending.assessment.mutating) { statement in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statement.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            if let note = statement.note {
                                Label(note, systemImage: "arrow.turn.down.right")
                                    .font(.caption2)
                                    .foregroundStyle(statement.effect == .destructive
                                                     ? .red : .secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(maxHeight: 260)

            HStack {
                Spacer()
                Button("ยกเลิก", role: .cancel) { model.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Button(pending.assessment.effect == .destructive ? "รันทั้งที่ลบข้อมูล" : "รัน") {
                    Task { await model.confirm() }
                }
                .buttonStyle(.borderedProminent)
                .tint(pending.assessment.effect == .destructive ? .red : .accentColor)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}
