import SwiftUI
import UniformTypeIdentifiers
import AgentKit
import DocGen
import Persistence

// ─────────────────────────────────────────────────────────────
// Assembling the five-chapter manuscript (ARCHITECTURE §20.8, P11.9).
//
// The screen is organised around the one thing that separates this from a text
// editor: **a number is inserted, never typed.** "Insert a number from a run" opens a
// picker over cells that have actually run, and choosing one writes both the
// placeholder and the reference — see `SentenceComposer` for why that is one
// action rather than two fields.
//
// The problems panel is deliberately always visible rather than appearing at
// export. §20.8's failure mode is a number that goes stale weeks after it was
// written; the author needs to meet that on the day the analysis is re-run,
// not on the day the draft is due.
// ─────────────────────────────────────────────────────────────

struct ManuscriptPane: View {
    @Bindable var model: ManuscriptViewModel
    @State private var newTitle = ""
    @State private var exporting = false

    var body: some View {
        HSplitView {
            list.frame(minWidth: 220, idealWidth: 260)
            if model.selected != nil {
                editor.frame(minWidth: 420)
            } else {
                ContentUnavailableView(
                    t("No manuscript selected", "Empty state on the manuscript screen."),
                    systemImage: "doc.text",
                    // One literal, not a concatenation: SwiftUI parses markdown
                    // only in a string literal, and `"a" + "b"` prints its own
                    // asterisks (the rule check.sh enforces).
                    description: Text(localised: "A five-chapter manuscript holds **numbers bound to cells that really ran**, not numbers somebody typed — re-run the analysis and the manuscript follows",
                                      "Empty-state explanation of what makes this manuscript editor different."))
                    .frame(maxWidth: .infinity)
            }
        }
        .task { await model.load() }
        .fileExporter(isPresented: $exporting, document: EmptyDocument(),
                      contentType: .init(filenameExtension: "docx") ?? .data,
                      defaultFilename: model.selected?.title ?? "manuscript") { result in
            if case .success(let url) = result {
                Task { await model.export(to: url) }
            }
        }
    }

    // MARK: - the list

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localised: "Five-chapter manuscript", "Heading of the manuscript screen.").font(.headline)
            HStack {
                TextField(t("Manuscript title", "Text field for naming a manuscript."), text: $newTitle)
                Button(t("Create", "Button that creates the project.")) {
                    Task { await model.create(title: newTitle); newTitle = "" }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // A `Button` per row, like every other list on this project, rather
            // than `List(data, selection:)`. Driven: clicking a row in the
            // selection version selected nothing — the draft opened only
            // because `create` had already selected it, so returning to an
            // existing manuscript the next day left the editor empty (U33-7).
            // The button shape is also what gives the row an `AXPress`, which
            // is the accessibility rule this project already enforces.
            List {
                ForEach(model.manuscripts) { manuscript in
                    Button {
                        model.selected = manuscript
                        Task { await model.refreshPreview() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manuscript.title).fontWeight(.medium)
                            Text(localised: "\(manuscript.references.count) reported numbers",
                                 "How many bound numbers a manuscript holds. Placeholder is a count.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(manuscript.id == model.selected?.id
                                ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contextMenu {
                        Button(t("Delete this manuscript", "Context-menu item that removes a manuscript."),
                               role: .destructive) {
                            Task { await model.delete(manuscript) }
                        }
                    }
                    .accessibilityAction(named: t("Delete this manuscript", "Screen-reader action name.")) {
                        Task { await model.delete(manuscript) }
                    }
                    .accessibilityLabel(t("\(manuscript.title) · \(manuscript.references.count) reported numbers",
                                          "Screen-reader label for a manuscript row. Placeholders: its title and how many numbers."))
                }
            }
            if let status = model.status {
                Text(status).font(.caption)
                    .foregroundStyle(model.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(Space.box)
    }

    // MARK: - the editor

    @ViewBuilder private var editor: some View {
        if let manuscript = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(manuscript)
                    problems
                    ForEach(ManuscriptChapter.allCases) { chapter in
                        chapterBlock(chapter, manuscript: manuscript)
                    }
                }
                .padding(Space.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func header(_ manuscript: Manuscript) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(manuscript.title).font(.title2.bold())
            Spacer()
            Button(t("Check again", "Button that re-verifies every bound number.")) {
                Task { await model.refreshPreview() }
            }
            Button(t("Export .docx", "Button that writes the document out.")) { exporting = true }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isExportable)
                .help(model.isExportable
                      ? t("every number is bound to a real run", "Manuscript status when export is possible.")
                      : t("some numbers cannot be bound — see the list below",
                          "Manuscript status when export is blocked."))
        }
    }

    @ViewBuilder private var problems: some View {
        if let preview = model.preview {
            if preview.isExportable {
                Label(t("Every number in the manuscript is bound to a cell that really ran",
                        "Shown when the manuscript is ready to export."),
                      systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(t("Not exportable yet", "Shown when the manuscript has unbound numbers."),
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                    ForEach(preview.failures) { failure in
                        Text("• \(failure.text)").font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(preview.unfilled, id: \.self) { name in
                        Text(localised: "• the slot “{\(name)}” has no result behind it",
                             "One unbound placeholder. Placeholder is the slot name.")
                            .font(.caption)
                    }
                    Text(localised: "The document is refused rather than printing a blank or a stale number — a manuscript with a hole in it is a manuscript that gets sent on anyway",
                         "Explains why export is blocked instead of degrading.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.box)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.box))
            }
        }
    }

    private func chapterBlock(_ chapter: ManuscriptChapter,
                              manuscript: Manuscript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chapter.title).font(.headline)
                Spacer()
                Button(t("Add a section", "Button that appends a section to a chapter.")) {
                    Task { await model.addSection(to: chapter) }
                }
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityLabel(t("Add a section to \(chapter.title)",
                                          "Screen-reader label. Placeholder is the chapter title."))
            }
            let sections = manuscript.sections[chapter] ?? []
            if sections.isEmpty {
                Text(localised: "No section in this chapter yet", "Shown for an empty chapter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                SectionEditor(model: model, chapter: chapter, index: index, section: section)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────

/// One section: a heading, prose, and the sentences that carry numbers.
private struct SectionEditor: View {
    @Bindable var model: ManuscriptViewModel
    let chapter: ManuscriptChapter
    let index: Int
    let section: ManuscriptSection

    @State private var picking = false
    @State private var editingSentence: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(t("Section heading", "Text field holding a section's heading."), text: Binding(
                    get: { section.heading },
                    set: { heading in
                        var updated = section
                        updated.heading = heading
                        Task { await model.update(updated, at: index, in: chapter) }
                    }))
                .textFieldStyle(.roundedBorder)
                Button(t("Delete the section", "Button that removes a section."), role: .destructive) {
                    Task { await model.removeSection(at: index, in: chapter) }
                }
                .buttonStyle(.borderless).font(.caption)
            }

            TextEditor(text: Binding(
                get: { section.prose.joined(separator: "\n\n") },
                set: { text in
                    var updated = section
                    updated.prose = text.components(separatedBy: "\n\n")
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    Task { await model.update(updated, at: index, in: chapter) }
                }))
            .frame(minHeight: 60)
            .font(.body)
            .accessibilityLabel(t("Paragraphs of \(section.heading)",
                                  "Screen-reader label. Placeholder is the section heading."))

            ForEach(Array(section.reported.enumerated()), id: \.offset) { position, sentence in
                sentenceRow(position, sentence)
            }

            Button(t("Add a sentence with numbers in it",
                     "Button that appends a sentence able to hold bound numbers.")) {
                var updated = section
                updated.reported.append(ReportedSentence("", references: []))
                Task { await model.update(updated, at: index, in: chapter) }
            }
            .buttonStyle(.borderless).font(.caption)
            .accessibilityLabel(t("Add a sentence with numbers to \(section.heading)",
                                  "Screen-reader label. Placeholder is the section heading."))
        }
        .padding(Space.box)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.box))
    }

    private func sentenceRow(_ position: Int, _ sentence: ReportedSentence) -> some View {
        let composer = SentenceComposer(sentence)
        return VStack(alignment: .leading, spacing: 4) {
            TextField(t("The sentence — numbers are inserted for you, never typed",
                        "Placeholder in the sentence editor, stating the rule the editor enforces."),
                      text: Binding(
                get: { sentence.text },
                set: { text in
                    var updated = section
                    updated.reported[position] = ReportedSentence(
                        text, references: sentence.references)
                    Task { await model.update(updated, at: index, in: chapter) }
                }))
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button(t("Insert a number from a run", "Button that opens the run picker.")) {
                    picking = true; editingSentence = position
                }
                    .buttonStyle(.borderless).font(.caption)
                ForEach(sentence.references) { reference in
                    Button {
                        var updated = section
                        var editing = SentenceComposer(sentence)
                        editing.remove(reference)
                        updated.reported[position] = editing.sentence
                        Task { await model.update(updated, at: index, in: chapter) }
                    } label: {
                        Label(reference.label, systemImage: "xmark.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(t("Remove \(reference.label) from this sentence",
                                          "Screen-reader label. Placeholder is the number's name."))
                }
                Button(t("Delete the sentence", "Button that removes a sentence."), role: .destructive) {
                    var updated = section
                    updated.reported.remove(at: position)
                    Task { await model.update(updated, at: index, in: chapter) }
                }
                .buttonStyle(.borderless).font(.caption2)
            }

            ForEach(composer.problems, id: \.self) { problem in
                Text("• \(problem)").font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: Binding(get: { picking && editingSentence == position },
                                    set: { if !$0 { picking = false; editingSentence = nil } })) {
            ResultPicker(runs: model.runs) { reference in
                var updated = section
                var editing = SentenceComposer(sentence)
                // The refusals live in the composer — a duplicate label here
                // would print one number twice and the other never.
                do {
                    try editing.insert(reference)
                    updated.reported[position] = editing.sentence
                    Task { await model.update(updated, at: index, in: chapter) }
                } catch {
                    // Shown by the picker itself; nothing is written.
                    throw error
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────

/// Picking a number out of a cell that has run.
///
/// Only cells with a recorded run are offered. A picker over every cell in the
/// notebook would let the author build a reference that cannot bind, and they
/// would meet the refusal at export instead of never being able to make the
/// mistake.
private struct ResultPicker: View {
    let runs: [CellRun]
    let insert: (ResultReference) throws -> Void

    @Environment(\.dismiss) private var dismiss
    /// By id rather than by value: `CellRun` carries its whole result table,
    /// and a `Picker` selection has to be `Hashable`.
    @State private var selectedRunID: String?
    @State private var column: String = ""
    @State private var row = 0
    @State private var label = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localised: "Choose a number from a cell that has run", "Title of the run picker sheet.")
                .font(.headline)
            if runs.isEmpty {
                Text(localised: "No cell has run yet — a number in the manuscript has to come from a real run, so run the notebook first and come back",
                     "Shown in the run picker when there is nothing to bind to.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(t("Cell", "Picker: which notebook run to take a number from."),
                       selection: $selectedRunID) {
                    Text(localised: "— choose —", "Picker option before a run is chosen.")
                        .tag(String?.none)
                    ForEach(runs) { run in
                        Text(preview(run)).tag(String?.some(run.id))
                    }
                }
                if let run = selectedRun {
                    Picker(t("Column", "Picker: which column of the result to take."), selection: $column) {
                        ForEach(run.columns, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper(t("Row \(row) (of \(run.rows.count))",
                              "Stepper over result rows. Placeholders: the chosen row and how many there are."),
                            value: $row,
                            in: 0...max(0, run.rows.count - 1))
                    if let value = value(in: run) {
                        Text(localised: "The value that will be inserted: \(value)",
                             "Preview of the number about to be bound. Placeholder is the value.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(t("Name for this number", "Field label: what to call the bound number.")) {
                    TextField(t("mean age", "Example placeholder for a bound number's name."), text: $label)
                }
                Text(localised: "This name is what the warning says on the day the cell changes and the number can no longer be bound — “mean age” reads better than “column 2”",
                     "Explains why the bound number needs a human name.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(t("Cancel", "Button that closes the run picker without inserting anything."),
                       role: .cancel) { dismiss() }
                Button(t("Insert it into the sentence", "Button that binds the number into the text.")) { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedRun == nil
                              || label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.section)
        .frame(width: 460)
        .onChange(of: selectedRunID) { _, _ in
            column = selectedRun?.columns.first ?? ""
            row = 0
        }
    }

    private var selectedRun: CellRun? { runs.first { $0.id == selectedRunID } }

    private func preview(_ run: CellRun) -> String {
        let source = run.source.replacingOccurrences(of: "\n", with: " ")
        return source.count > 60 ? String(source.prefix(60)) + "…" : source
    }

    private func value(in run: CellRun) -> String? {
        guard let index = run.columns.firstIndex(of: column),
              row < run.rows.count, index < run.rows[row].count else { return nil }
        return run.rows[row][index] ?? t("(empty)", "Stand-in for a result cell with no value.")
    }

    private func add() {
        guard let run = selectedRun else { return }
        let reference = ResultReference(notebookID: run.notebookID, cellID: run.cellID,
                                        column: column, row: row,
                                        label: label.trimmingCharacters(in: .whitespaces))
        do {
            try insert(reference)
            dismiss()
        } catch {
            problem = "\(error)"
        }
    }
}

/// The exporter writes the file itself; this is the empty document
/// `fileExporter` needs to give us a destination URL.
private struct EmptyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    init() {}
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

// ─────────────────────────────────────────────────────────────

/// The "Results + documents" sub-tab: the pre-registered method and the manuscript
/// it becomes.
///
/// One picker rather than two sub-tabs because §12.4's plan and §20.8's
/// manuscript are two stages of one document — the method agreed before the
/// numbers are seen, and the numbers written up afterwards — and §19.2 is
/// explicit that the areas hold *steps of a path*, not a list of tools.
struct ResultsPane<AnalysisContent: View>: View {
    let analysis: AnalysisViewModel
    @Bindable var manuscripts: ManuscriptViewModel
    let engine: Engine
    /// The workspace these two belong to (§19.1.1, P21.2) — it is what says
    /// which project's drafts these are, and whether they have been wired up
    /// already.
    let workspace: Workspace
    @ViewBuilder let analysisView: () -> AnalysisContent

    @State private var showing = Half.plan

    enum Half: String, CaseIterable, Identifiable {
        case plan, manuscript
        var id: String { rawValue }
        var label: String {
            switch self {
            case .plan: t("Analysis plan", "Analysis pane: the plan a statistical analysis follows.")
            case .manuscript: t("Five-chapter manuscript", "Heading of the manuscript screen.")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(t("View", "Picker over the panes of the console sub-tab."), selection: $showing) {
                ForEach(Half.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch showing {
            case .plan: analysisView()
            case .manuscript:
                ManuscriptPane(model: manuscripts)
                    // Same identity rule as Chat and Analysis: the view's own
                    // state is this tab's, so it is rebuilt on a switch. The
                    // model is the workspace's and outlives that (§19.1.1).
                    .id(workspace.scope.storageKey)
                    .task {
                        guard workspace.needsWiring("manuscripts") else { return }
                        manuscripts.attach(store: ManuscriptStore(client: engine.client),
                                           analysis: analysis, scope: workspace.scope)
                        await manuscripts.load()
                    }
            }
        }
    }
}
