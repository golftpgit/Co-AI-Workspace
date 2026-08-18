import SwiftUI
import DocGen
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
    /// Which pane the Workbench area asked for (§19.2, P10.12). When set, this
    /// screen stops choosing for itself and hides its own picker — the area's
    /// sub-tabs are the picker, and two of them would be two answers to "where
    /// am I".
    var chosen: Pane?
    /// Which half of the database pane to show. The Workbench splits internal
    /// and external storage into separate sub-tabs because they are different
    /// steps of one data path (§19.2), while the SQL editor and the result table
    /// underneath them are the same tool.
    var explorerFocus: ExplorerFocus = .both

    enum Pane: String, CaseIterable, Identifiable {
        case notebook, explorer, plan
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notebook: t("Notebook", "Console pane: the script and its output.")
            case .explorer: t("Database", "Analysis pane: tables and external sources.")
            case .plan: t("Analysis plan", "Analysis pane: the plan a statistical analysis follows.")
            }
        }
    }

    enum ExplorerFocus {
        case internalStore, external, both

        var showsInternal: Bool { self != .external }
        var showsExternal: Bool { self != .internalStore }
    }

    private var visible: Pane { chosen ?? pane }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if visible == .plan {
                // The plan does not need the store to be open — it is about
                // the method, and it is written before anything runs.
                PlanPane(model: model)
            } else if model.storeIsOpen {
                switch visible {
                case .notebook: NotebookPane(model: model)
                case .explorer: ExplorerPane(model: model, focus: explorerFocus)
                case .plan: EmptyView()
                }
            } else {
                // A closed store is not an empty database, and the screen must
                // not let those look the same.
                ContentUnavailableView(
                    t("The analysis database could not be opened", "Empty state on the analysis screen."),
                    systemImage: "exclamationmark.triangle",
                    description: Text(localised: "analysis.duckdb would not open at start-up — the rest of the app works as usual, and the detail is on the System status screen",
                                      "Empty-state explanation when the analysis store is unavailable."))
            }
        }
        .task { await model.refresh() }
        .sheet(item: $model.confirmation) { pending in
            ConfirmSheet(model: model, pending: pending)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if chosen == nil {
                Picker(t("View", "Picker over the panes of the console sub-tab."), selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            }

            Spacer()

            if let status = model.status {
                // A button rather than a tap gesture: dismissing this is the
                // only way to clear it, and an action that only a mouse can
                // reach is an action some people do not have (§14.4).
                Button { model.clearStatus() } label: {
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(status.isError ? .red : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 420, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityHint(t("dismiss this message", "Screen-reader hint on a dismiss button."))
            }
        }
        .padding(Space.box)
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
                ContentUnavailableView(t("No notebook yet", "Empty state in the notebook list."),
                                       systemImage: "square.grid.3x1.below.line.grid.1x2",
                                       description: Text(localised: "Press + to create the first one",
                                                         "Empty-state instruction in the notebook list."))
                    // Without this the empty state takes its ideal width and the
                    // whole pane centres itself, leaving 390pt of blank white to
                    // the left of the notebook list — which reads as a screen
                    // that failed to draw. Only visible once the pane stopped
                    // being the whole window (P10.12).
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localised: "Notebook", "Heading over the list of notebooks.").font(.subheadline).bold()
                Spacer()
                Button { model.newNotebook() } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel(t("Create a new notebook", "Screen-reader label."))
                    }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            List {
                ForEach(model.notebooks) { notebook in
                    Button { model.open(notebook) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notebook.title).lineLimit(1)
                            Text(localised: "\(notebook.cells.count) cells · \(scopeLabel(notebook.scope))",
                                 "A notebook row. Placeholders: how many cells it holds and which scope it belongs to.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(notebook.id == model.notebook?.id
                                       ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contextMenu {
                        Button(t("Delete", "Context-menu item that removes a notebook."),
                               role: .destructive) { model.delete(notebook) }
                    }
                    // The same action, offered where a context menu is not:
                    // right-click is a mouse, and VoiceOver reaches this
                    // through the actions rotor (§14.4).
                    .accessibilityAction(named: t("Delete this notebook", "Screen-reader action name.")) {
                        model.delete(notebook)
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
                    ForEach(Array(notebook.cells.enumerated()), id: \.element.id) { index, cell in
                        // The number is for the screen reader, not the eye:
                        // three buttons all called "run this cell" are the same
                        // button to somebody who cannot see which cell they
                        // are next to (measured, E.30).
                        CellView(number: index + 1, model: model, cell: cell)
                    }
                    HStack {
                        Button { model.addCell(kind: .sql) } label: {
                            Label(t("Add a SQL cell", "Menu item that appends a SQL cell."), systemImage: "plus")
                        }
                        Button { model.addCell(kind: .python) } label: {
                            Label(t("Add a Python cell", "Menu item that appends a Python cell."), systemImage: "plus")
                        }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
                .padding(Space.box)
            }
        }
    }

    private func notebookBar(_ notebook: Notebook) -> some View {
        HStack(spacing: 10) {
            TextField(t("Notebook name", "Text field holding the notebook's title."), text: Binding(
                get: { notebook.title },
                set: { model.rename($0) }))
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: 280)

            Button { Task { await model.runAll() } } label: {
                Label(t("Run all", "Button that runs every cell in the notebook."), systemImage: "play.fill")
            }

            Spacer()
            KernelBadge(model: model)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func scopeLabel(_ scope: Scope) -> String {
        switch scope {
        case .central: t("shared", "Notebook scope: visible everywhere.")
        case .policy: t("policy", "Notebook scope: belongs to policy work.")
        case .board(let runID): t("board for run \(runID)",
                                  "Notebook scope. Placeholder is the run id.")
        case .project(let id): t("project \(id.rawValue)",
                                 "Notebook scope. Placeholder is the project id.")
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
                Text(localised: "Python kernel: not started", "Kernel status before it is running.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(t("Start the kernel", "Button that boots the Python kernel.")) {
                    Task { await model.startKernel() }
                }
            case .starting:
                ProgressView().controlSize(.small)
                Text(localised: "Starting the kernel…", "Kernel status while it boots.")
                    .font(.caption).foregroundStyle(.secondary)
            case .ready(let version):
                Label("Python \(version)", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.green)
                // Says what it costs before it is pressed: a restart is how the
                // variables go away.
                Button(t("Restart", "Button that restarts the Python kernel.")) {
                    Task { await model.restartKernel() }
                }
                    .help(t("Clears every variable and starts the kernel again",
                            "Tooltip on the restart button."))
                Button(t("Unload", "Button that shuts the kernel down.")) {
                    Task { await model.stopKernel() }
                }
                    .help(t("Gives back the memory the kernel is holding", "Tooltip on the unload button."))
            case .busy:
                ProgressView().controlSize(.small)
                Button(t("Interrupt", "Button that stops the cell the kernel is running.")) {
                    Task { await model.interruptKernel() }
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

private struct CellView: View {
    /// Where this cell sits in the notebook, 1-based. Only ever spoken.
    let number: Int
    @Bindable var model: AnalysisViewModel
    let cell: NotebookCell

    private var isRunning: Bool {
        if case .running = model.state(for: cell.id) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker(t("Kind", "Picker: whether a notebook cell is SQL or Python."), selection: Binding(
                    get: { cell.kind },
                    set: { model.setKind($0, for: cell.id) })) {
                        ForEach(NotebookCell.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .accessibilityLabel(t("Kind of cell \(number)", "Screen-reader label. Placeholder is the cell number."))

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
                    .accessibilityLabel(t("Run cell \(number)", "Screen-reader label. Placeholder is the cell number."))
                }
                Button(role: .destructive) { model.removeCell(cell.id) } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(t("Delete cell \(number)", "Screen-reader label. Placeholder is the cell number."))
            }
            .buttonStyle(.borderless)

            TextEditor(text: Binding(get: { model.source(for: cell.id) },
                                     set: { model.setSource($0, for: cell.id) }))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(Space.row)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: Radius.box))

            CellOutputView(state: model.state(for: cell.id))
        }
        .padding(Space.box)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: Radius.box))
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
                Text(String(format: t("%.2f seconds",
                                      "How long a notebook cell took. Placeholder is a number of seconds."),
                            seconds))
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
    let focus: AnalysisView.ExplorerFocus
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
                    .padding(Space.row)
                    .background(.quaternary.opacity(0.25))

                HStack(spacing: 10) {
                    Button { Task { await model.runExplorer() } } label: {
                        Label(t("Run", "Button that executes the SQL in the editor."), systemImage: "play.fill")
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
                        Label(t("Import CSV/Parquet", "Button that loads a data file into the store."),
                              systemImage: "square.and.arrow.down")
                    }
                }
                .padding(Space.box)

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
                    .padding(Space.box)
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
                Text(localised: "Tables in the store", "Heading over the analysis store's tables.")
                    .font(.subheadline).bold()
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(t("Reload the list of tables", "Screen-reader label."))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            List {
                if focus.showsInternal {
                if model.tables.isEmpty {
                    // Splitting internal from external (P10.12) made this state
                    // reachable for the first time: before, the external
                    // placeholders always filled the column, so an empty store
                    // never looked like a broken screen. §12.2's rule again — a
                    // list that says nothing is worse than one that says why.
                    Text(localised: "No tables in this project's store yet — import a CSV or Parquet file, or pull a table in from an external database",
                         "Shown when the analysis store is empty, naming both ways to fill it.")
                        .font(.caption).foregroundStyle(.secondary)
                        // Wraps rather than truncating: the sidebar is 200pt and
                        // the one-line version ended at "import…", which is half
                        // an instruction.
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                        // The disclosure triangle expands; the name writes a
                        // SELECT into the editor. Two actions, so the second
                        // one is a control rather than a gesture on a label —
                        // otherwise it exists only for a mouse.
                        Button {
                            model.explorerSQL = "SELECT * FROM "
                                + "\(AnalysisStore.quoted(table.name)) LIMIT 100"
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(table.name).font(.callout)
                                Text(table.rowCount.map {
                                    t("\($0) rows", "How many rows a table holds. Placeholder is a count.")
                                } ?? t("row count unavailable", "Shown when a table's rows could not be counted."))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(t("puts a SELECT for this table into the SQL editor",
                                             "Screen-reader hint on a table row."))
                    }
                }
                }
                if focus.showsExternal {
                Section {
                    if model.connectors.isEmpty {
                        Text(localised: "No external source yet — press + to add one",
                             "Shown when no external database has been configured.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.connectors) { connector in
                        ConnectorRow(model: model, connector: connector)
                    }
                    // Named rather than omitted: a list with two silent
                    // failures in it is worse than one that says why (§12.2).
                    ForEach(UnsupportedConnector.allCases) { kind in
                        Label(t("\(kind.label) — not reachable yet",
                                "Shown for a connector kind that cannot be used. Placeholder is its name."),
                              systemImage: "minus.circle")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .help(kind.reason)
                    }
                } header: {
                    HStack {
                        Text(localised: "External sources", "Heading over configured external databases.")
                        Spacer()
                        Button { addingConnector = true } label: {
                                Image(systemName: "plus")
                                    .accessibilityLabel(t("Add an external source", "Screen-reader label."))
                            }
                            .buttonStyle(.borderless)
                    }
                }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 230)
        // Re-read from disk when the sheet closes. Driving this screen by hand
        // (U19, 2026-08-12) found that adding a source left the whole external
        // section rendering *nothing* — not the new row and not the "cannot
        // connect yet" placeholders that were there before — until the pane was
        // left and re-entered. The connector was saved correctly; the view had
        // simply not re-rendered. Reloading here makes the list match the file
        // whatever SwiftUI did with the in-flight update.
        .onChange(of: addingConnector) { _, isPresented in
            if !isPresented { model.reloadConnectors() }
        }
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
                // Connected is green and filled, not-connected is grey and
                // hollow — which is two ways of saying it to someone who can
                // see it and none to anyone else. The state is in the label.
                Image(systemName: model.isConnected(connector) ? "circle.fill" : "circle")
                    .font(.system(size: 7))
                    .foregroundStyle(model.isConnected(connector) ? .green : .secondary)
                    .accessibilityLabel(model.isConnected(connector)
                                        ? t("connected", "Connector status: the database is open.")
                                        : t("not connected", "Connector status: the database is closed."))
                Text(connector.alias).font(.callout)
                Spacer()
                if model.isConnected(connector) {
                    Button(t("Disconnect", "Button that closes an external database.")) {
                        Task { await model.disconnect(connector) }
                    }
                } else {
                    Button(t("Connect", "Button that opens an external database.")) {
                        Task { await model.connect(connector) }
                    }
                        // Says why before it is pressed, rather than failing
                        // with a driver error afterwards.
                        .disabled(!connector.secretIsAvailable)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Text(connector.kind.rawValue + (connector.readOnly
                                            ? t(" · read-only", "Appended to a connector that cannot be written to.")
                                            : t(" · writable", "Appended to a connector that can be written to.")))
                .font(.caption2).foregroundStyle(.secondary)
            if let variable = connector.secretVariable, !connector.secretIsAvailable {
                // Says which of the two it is: never entered, or the Keychain
                // would not open (P9.3).
                Text(SecretPresentation.display(name: variable).text)
                    .font(.caption2).foregroundStyle(.orange)
            }
            ForEach(model.externalTables[connector.alias] ?? [], id: \.self) { table in
                HStack {
                    Button {
                        model.explorerSQL = "SELECT * FROM "
                            + "\(AnalysisStore.quoted(connector.alias))."
                            + "\(AnalysisStore.quoted(table)) LIMIT 100"
                    } label: {
                        Text(table).font(.caption2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(t("puts a SELECT for this table into the SQL editor",
                                         "Screen-reader hint on a table row."))
                    Button(t("Pull it in", "Button that copies an external table into the analysis store.")) {
                        Task { await model.pull(table, from: connector.alias) }
                    }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }
        }
        .contextMenu {
            Button(t("Remove this source", "Button that forgets an external database."),
                   role: .destructive) {
                Task { await model.remove(connector: connector) }
            }
        }
        .accessibilityAction(named: t("Remove this source", "Screen-reader action name.")) {
            Task { await model.remove(connector: connector) }
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
            Text(localised: "Add an external source", "Title of the sheet that defines a connector.")
                .font(.headline)

            Picker(t("Kind", "Picker: which kind of external database this is."), selection: $kind) {
                ForEach(ConnectorKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField(t("Name to use in SQL (for example: lab)",
                        "Text field: the alias this source is referred to by in queries."),
                      text: $alias)
            TextField(kind == .sqlite
                      ? t("path to the .sqlite file", "Placeholder for a SQLite connector.")
                      : t("host=… port=… dbname=… user=… (no password here)",
                          "Placeholder for a Postgres connector, saying plainly not to type the password."),
                      text: $target)
            if kind != .sqlite {
                SecretField(name: $secretVariable,
                            title: t("Password name", "Label on the field naming the stored password."),
                            placeholder: "PGPASSWORD")
                Text(localised: "The password is not written to the source's file — the file holds only the name, the value lives in the Keychain and is read only when connecting",
                     "Explains where a connector password is kept.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle(t("Read-only", "Checkbox that stops this connector writing to the source."),
                   isOn: $readOnly)
            Text(localised: "§12.2 makes read-only the default, because the data at the other end usually belongs to somebody else",
                 "Explains why new connectors are read-only.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(t("Cancel", "Button that closes the connector sheet without saving."),
                       role: .cancel) { isPresented = false }
                Button(t("Save and connect", "Button that stores the connector and opens it.")) {
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
        .padding(Space.section)
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
            if case .success(let url) = result { Task { await model.exportPlan(to: url) } }
        }
        // P7.9 — a template is learned from a document, so this is an import
        // of somebody's own file rather than a form to fill in.
        .fileImporter(isPresented: $importingTemplate,
                      allowedContentTypes: [.init(filenameExtension: "docx") ?? .data]) { result in
            if case .success(let url) = result { model.importTemplate(from: url) }
        }
        .sheet(isPresented: $editingTemplate) {
            if let id = model.selectedTemplateID,
               let template = model.templates.first(where: { $0.id == id }) {
                TemplateEditor(template: template, model: model)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localised: "Analysis plan", "Heading over the list of analysis plans.")
                    .font(.subheadline).bold()
                Spacer()
                Button { model.open(plan: nil) } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel(t("Read a protocol again", "Screen-reader label."))
                    }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            List {
                ForEach(model.plans) { plan in
                    Button { model.open(plan: plan) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.title).lineLimit(1)
                            HStack(spacing: 4) {
                                if plan.isApproved {
                                    Label(t("approved", "Marker on an analysis plan somebody signed off."),
                                          systemImage: "checkmark.seal.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Text(localised: "\(plan.blockers.count) outstanding",
                                         "How many blockers an analysis plan still has. Placeholder is a count.")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(plan.id == model.plan?.id
                                       ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contextMenu {
                        Button(t("Delete", "Context-menu item that removes an analysis plan."),
                               role: .destructive) { Task { await model.deletePlan(plan) } }
                    }
                    .accessibilityAction(named: t("Delete this plan", "Screen-reader action name.")) {
                        Task { await model.deletePlan(plan) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 220)
    }

    private var proposalEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localised: "Read a research protocol", "Title of the panel that ingests a protocol.")
                .font(.headline)
            Text(localised: "Paste the protocol and the research question, population, exposure, outcome, method and time window are extracted, then compared against the columns that really exist in the store to say what is missing (§12.4)",
                 "Explains what reading a protocol does.")
                .font(.caption).foregroundStyle(.secondary)
            TextField(t("Plan name", "Text field holding the analysis plan's title."), text: $model.planTitle)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

            if !model.knowledgeDocuments.isEmpty {
                HStack(spacing: 8) {
                    // §12.4 wants this to key off `doc_type: proposal`; the
                    // ingest pipeline records no document type yet, so the
                    // list is everything and the choice is the user's.
                    Menu(t("Use a document from the knowledge base",
                           "Menu that picks a stored document as the protocol.")) {
                        ForEach(model.knowledgeDocuments, id: \.id) { document in
                            Button(document.title) {
                                Task { await model.useDocument(document.id) }
                            }
                        }
                    }
                    .frame(maxWidth: 260)
                    Text(localised: "or paste the text yourself below",
                         "Alternative to picking a stored document.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $model.proposalText)
                .font(.system(.body, design: .default))
                .frame(minHeight: 180)
                .padding(Space.row)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: Radius.box))
            HStack {
                Button { Task { await model.readProposal() } } label: {
                    Label(t("Read it and find the gaps",
                            "Button that extracts the plan and compares it with the store."),
                          systemImage: "text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isReadingProposal)
                if model.isReadingProposal { ProgressView().controlSize(.small) }
                Spacer()
            }
            Spacer()
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detail(_ plan: AnalysisPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(plan)
                if !plan.openGaps.isEmpty {
                    Text(localised: "Gap report", "Heading over what the protocol asks for and the store lacks.")
                        .font(.subheadline).bold()
                    ForEach(plan.openGaps) { gap in
                        GapRow(model: model, gap: gap)
                    }
                }
                Text(localised: "Decisions in the plan", "Heading over choices recorded in an analysis plan.")
                    .font(.subheadline).bold()
                ForEach(plan.decisions) { decision in
                    DecisionRow(model: model, decision: decision, locked: plan.isApproved)
                }
                // §14.1 reads this plan later to write the document's
                // Limitations. Showing it here means an assumption is seen as
                // the sentence it will become, while there is still time to
                // change it.
                if !model.limitationsPreview.isEmpty {
                    Text(localised: "Limitations that will appear in generated documents (§14.1)",
                         "Heading over limitations carried automatically into writing.")
                        .font(.subheadline).bold()
                    ForEach(model.limitationsPreview.items) { item in
                        Label(item.text, systemImage: "text.append")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(Space.row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.2),
                                        in: RoundedRectangle(cornerRadius: Radius.box))
                    }
                }
                if !plan.revisions.isEmpty {
                    Text(localised: "History of withdrawn approvals",
                         "Heading over times an analysis plan's approval was revoked.")
                        .font(.subheadline).bold()
                    ForEach(Array(plan.revisions.enumerated()), id: \.offset) { _, reason in
                        Label(reason, systemImage: "arrow.uturn.backward")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Space.section)
        }
    }

    @State private var editingTemplate = false

    private func header(_ plan: AnalysisPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.title).font(.headline)
                Spacer()
                // P7.9: the shape it comes out in. "our own layout" is P7.6's
                // layout; the rest are documents this person uploaded.
                Picker(t("Template", "Picker over document templates for export."), selection: Binding(
                    get: { model.selectedTemplateID },
                    set: { model.selectTemplate($0) })) {
                        Text(localised: "our own layout", "Template option: the built-in document shape.")
                            .tag(String?.none)
                        ForEach(model.templates) { template in
                            Text(template.name).tag(String?.some(template.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                Button {
                    importingTemplate = true
                } label: {
                    Label(t("Add a template from a file", "Button that learns a template from a .docx."),
                          systemImage: "doc.badge.plus")
                }
                .help(t("Pick a .docx with all its headings and its structure is remembered",
                        "Tooltip on the add-template button."))
                // P7.9's other half: a template learned from a file with one
                // heading in the wrong place used to be a template you lived
                // with, because the only way to change it was another file.
                if model.selectedTemplateID != nil {
                    Button(t("Edit the template", "Button that opens the template editor.")) {
                        editingTemplate = true
                    }
                        .accessibilityLabel(t("Edit the headings of the selected template", "Screen-reader label."))
                }
                // §14.1: a pre-registration is something you send to somebody.
                Button { exporting = true } label: {
                    Label(t("Export .docx", "Button that writes the document out."),
                          systemImage: "square.and.arrow.up")
                }
                if plan.isApproved {
                    Label(t("approved by \(plan.approvedBy ?? "")",
                            "Marker on an approved analysis plan. Placeholder is who approved it."),
                          systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Button(t("Approve the whole plan", "Button that signs off the analysis plan.")) {
                        Task { await model.approvePlan() }
                    }
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
                Text(localised: "Any edit after this withdraws the approval on its own and it must be approved again — a plan that can be changed quietly is not a pre-registration",
                     "Explains why approval is revoked by editing. 'pre-registration' is the research term.")
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
                    TextField(t("Your answer", "Text field for answering a question the plan raised."),
                              text: $answer)
                        .textFieldStyle(.roundedBorder)
                    Button(t("Save the answer", "Button that records the answer.")) {
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
        .padding(Space.box)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.box))
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
                    Button(t("Confirm", "Button that records the reversal.")) {
                        Task { await model.confirm(decision: decision.id) }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(Space.box)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: Radius.box))
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
                Text(localised: "The statement succeeded · no table came back",
                     "Shown after SQL that returns no rows, so success is not mistaken for an empty result.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    // Pinned left. A `Grid` inside a two-way `ScrollView` takes
                    // its ideal width and centres, which put a three-column
                    // result in the middle of a 1400pt pane with the row count
                    // stranded on the far left — U23-4's shape again.
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
                    .padding(Space.row)
                }
                // A two-way `ScrollView` parks its content in the middle when it
                // is smaller than the viewport, which put a three-column result
                // in the centre of a 1400pt pane with the row count stranded on
                // the far left. Anchoring says which corner it starts in.
                .defaultScrollAnchor(.topLeading)
                .frame(maxHeight: 300)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.box))
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
            ? t("showing \(shown) of \(result.rowCount) rows · \(timing)",
                "Result summary when the table is truncated. Placeholders: rows shown, rows total, and how long it took.")
            : t("\(result.rowCount) rows · \(timing)",
                "Result summary. Placeholders: how many rows and how long it took.")
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
                  ? t("This statement deletes or overwrites data",
                      "Warning above a destructive SQL confirmation.")
                  : t("This statement changes data",
                      "Warning above a data-changing SQL confirmation."),
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
                        .padding(Space.row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.box))
                    }
                }
            }
            .frame(maxHeight: 260)

            HStack {
                Spacer()
                Button(t("Cancel", "Button that abandons running the SQL."),
                       role: .cancel) { model.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Button(pending.assessment.effect == .destructive
                       ? t("Run it even though it deletes data",
                           "Confirming button on a destructive statement — deliberately long to read.")
                       : t("Run", "Confirming button on a statement that changes data.")) {
                    Task { await model.confirm() }
                }
                .buttonStyle(.borderedProminent)
                .tint(pending.assessment.effect == .destructive ? .red : .accentColor)
            }
        }
        .padding(Space.section)
        .frame(width: 520)
    }
}

// ─────────────────────────────────────────────────────────────

/// Editing a learned template (§14.1, P7.9).
///
/// Every section starts required because it was in a document somebody's
/// committee accepted — the only evidence available about what matters. This
/// sheet is where a person disagrees with that evidence, which they are
/// entitled to do; the refusals live on the type, so a rename to nothing or to
/// a name another section already has is turned down wherever it comes from.
private struct TemplateEditor: View {
    let template: DocumentTemplate
    @Bindable var model: AnalysisViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.box) {
            SectionHeading(title: t("Edit the template “\(template.name)”",
                                    "Title of the template editor. Placeholder is the template's name."),
                           help: t("Headings learned from a real document — rename them, reorder them, or say which are not required · whatever the sample file wrote under a heading always travels with it",
                                   "Explains what the template editor changes."))

            ScrollView {
                VStack(alignment: .leading, spacing: Space.row) {
                    ForEach(Array(template.sections.enumerated()), id: \.offset) { index, section in
                        HStack(spacing: Space.row) {
                            TextField(t("Heading name", "Text field holding one template heading."),
                                      text: Binding(
                                get: { renaming[index] ?? section.heading },
                                set: { renaming[index] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    let name = renaming[index] ?? section.heading
                                    model.editTemplate(template.id) { $0.renaming(index, to: name) }
                                    renaming[index] = nil
                                }
                                .accessibilityLabel(t("Name of heading \(index + 1)",
                                                      "Screen-reader label. Placeholder is the heading's position."))

                            Toggle(t("Required", "Checkbox marking a template heading as mandatory."),
                                   isOn: Binding(
                                get: { section.isRequired },
                                set: { required in
                                    model.editTemplate(template.id) {
                                        $0.settingRequired(index, required)
                                    }
                                }))
                                .toggleStyle(.checkbox)

                            Button {
                                model.editTemplate(template.id) { $0.moving(index, to: index - 1) }
                            } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0)
                                .accessibilityLabel(t("Move \(section.heading) up",
                                                      "Screen-reader label. Placeholder is the heading's name."))
                            Button {
                                model.editTemplate(template.id) { $0.moving(index, to: index + 1) }
                            } label: { Image(systemName: "arrow.down") }
                                .disabled(index == template.sections.count - 1)
                                .accessibilityLabel(t("Move \(section.heading) down",
                                                      "Screen-reader label. Placeholder is the heading's name."))
                        }
                        if let guidance = section.guidance {
                            // Kept in front of the person editing: it is the
                            // only record of what the accepted document had
                            // under this heading, and the file may be gone.
                            Text(guidance).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            if let status = model.status, status.isError {
                Text(status.message).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(t("Done", "Button that closes the template editor.")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.section)
        .frame(width: 560)
    }
}
