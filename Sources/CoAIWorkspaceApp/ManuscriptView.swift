import SwiftUI
import UniformTypeIdentifiers
import AgentKit
import DocGen
import Persistence

// ─────────────────────────────────────────────────────────────
// Assembling the five-chapter manuscript (ARCHITECTURE §20.8, P11.9).
//
// The screen is organised around the one thing that separates this from a text
// editor: **a number is inserted, never typed.** "เพิ่มตัวเลขจากการรัน" opens a
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
                    "ยังไม่ได้เลือกต้นฉบับ",
                    systemImage: "doc.text",
                    // One literal, not a concatenation: SwiftUI parses markdown
                    // only in a string literal, and `"a" + "b"` prints its own
                    // asterisks (the rule check.sh enforces).
                    description: Text("ต้นฉบับ 5 บทเก็บ **ตัวเลขที่ผูกกับเซลล์ที่รันจริง** ไม่ใช่ตัวเลขที่พิมพ์เข้าไป — รันวิเคราะห์ใหม่แล้วเล่มเปลี่ยนตาม"))
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
            Text("ต้นฉบับ 5 บท").font(.headline)
            HStack {
                TextField("ชื่อเล่ม", text: $newTitle)
                Button("สร้าง") {
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
                            Text("ตัวเลขที่รายงาน \(manuscript.references.count) ค่า")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(manuscript.id == model.selected?.id
                                ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contextMenu {
                        Button("ลบเล่มนี้", role: .destructive) {
                            Task { await model.delete(manuscript) }
                        }
                    }
                    .accessibilityAction(named: "ลบต้นฉบับเล่มนี้") {
                        Task { await model.delete(manuscript) }
                    }
                    .accessibilityLabel("\(manuscript.title) · ตัวเลขที่รายงาน "
                                        + "\(manuscript.references.count) ค่า")
                }
            }
            if let status = model.status {
                Text(status).font(.caption)
                    .foregroundStyle(model.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
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
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func header(_ manuscript: Manuscript) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(manuscript.title).font(.title2.bold())
            Spacer()
            Button("ตรวจใหม่") { Task { await model.refreshPreview() } }
            Button("ส่งออก .docx") { exporting = true }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isExportable)
                .help(model.isExportable
                      ? "ตัวเลขทุกตัวผูกกับการรันจริงแล้ว"
                      : "ยังมีตัวเลขที่ผูกไม่ได้ — ดูรายการด้านล่าง")
        }
    }

    @ViewBuilder private var problems: some View {
        if let preview = model.preview {
            if preview.isExportable {
                Label("ตัวเลขทุกตัวในเล่มผูกกับเซลล์ที่รันจริงแล้ว", systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("ยังส่งออกไม่ได้", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                    ForEach(preview.failures) { failure in
                        Text("• \(failure.text)").font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(preview.unfilled, id: \.self) { name in
                        Text("• ช่อง “{\(name)}” ยังไม่มีผลรองรับ").font(.caption)
                    }
                    Text("เอกสารถูกปฏิเสธแทนที่จะพิมพ์ช่องว่างหรือเลขเก่า — "
                         + "เล่มที่มีรูโหว่คือเล่มที่ถูกส่งต่อไปอยู่ดี")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func chapterBlock(_ chapter: ManuscriptChapter,
                              manuscript: Manuscript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chapter.title).font(.headline)
                Spacer()
                Button("เพิ่มหัวข้อ") { Task { await model.addSection(to: chapter) } }
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityLabel("เพิ่มหัวข้อใน\(chapter.title)")
            }
            let sections = manuscript.sections[chapter] ?? []
            if sections.isEmpty {
                Text("ยังไม่มีหัวข้อในบทนี้").font(.caption).foregroundStyle(.secondary)
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
                TextField("หัวข้อ", text: Binding(
                    get: { section.heading },
                    set: { heading in
                        var updated = section
                        updated.heading = heading
                        Task { await model.update(updated, at: index, in: chapter) }
                    }))
                .textFieldStyle(.roundedBorder)
                Button("ลบหัวข้อ", role: .destructive) {
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
            .accessibilityLabel("ย่อหน้าของ\(section.heading)")

            ForEach(Array(section.reported.enumerated()), id: \.offset) { position, sentence in
                sentenceRow(position, sentence)
            }

            Button("เพิ่มประโยคที่มีตัวเลข") {
                var updated = section
                updated.reported.append(ReportedSentence("", references: []))
                Task { await model.update(updated, at: index, in: chapter) }
            }
            .buttonStyle(.borderless).font(.caption)
            .accessibilityLabel("เพิ่มประโยคที่มีตัวเลขใน\(section.heading)")
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sentenceRow(_ position: Int, _ sentence: ReportedSentence) -> some View {
        let composer = SentenceComposer(sentence)
        return VStack(alignment: .leading, spacing: 4) {
            TextField("ประโยค — ตัวเลขจะถูกใส่ให้เอง ไม่ต้องพิมพ์เอง", text: Binding(
                get: { sentence.text },
                set: { text in
                    var updated = section
                    updated.reported[position] = ReportedSentence(
                        text, references: sentence.references)
                    Task { await model.update(updated, at: index, in: chapter) }
                }))
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("เพิ่มตัวเลขจากการรัน") { picking = true; editingSentence = position }
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
                    .accessibilityLabel("เอา \(reference.label) ออกจากประโยคนี้")
                }
                Button("ลบประโยค", role: .destructive) {
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
            Text("เลือกตัวเลขจากเซลล์ที่รันแล้ว").font(.headline)
            if runs.isEmpty {
                Text("ยังไม่มีเซลล์ไหนถูกรัน — ตัวเลขในเล่มต้องมาจากการรันจริง "
                     + "ไปรันสมุดงานก่อนแล้วกลับมา")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("เซลล์", selection: $selectedRunID) {
                    Text("— เลือก —").tag(String?.none)
                    ForEach(runs) { run in
                        Text(preview(run)).tag(String?.some(run.id))
                    }
                }
                if let run = selectedRun {
                    Picker("คอลัมน์", selection: $column) {
                        ForEach(run.columns, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("แถวที่ \(row) (มี \(run.rows.count) แถว)", value: $row,
                            in: 0...max(0, run.rows.count - 1))
                    if let value = value(in: run) {
                        Text("ค่าที่จะถูกใส่: \(value)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("ชื่อของตัวเลขนี้") {
                    TextField("ค่าเฉลี่ยอายุ", text: $label)
                }
                Text("ชื่อนี้คือสิ่งที่ปรากฏในข้อความแจ้ง เมื่อวันหนึ่งเซลล์ถูกแก้แล้วผูกไม่ได้ — "
                     + "“ค่าเฉลี่ยอายุ” อ่านง่ายกว่า “คอลัมน์ที่ 2”")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("ยกเลิก", role: .cancel) { dismiss() }
                Button("ใส่ลงประโยค") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedRun == nil
                              || label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
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
        return run.rows[row][index] ?? "(ว่าง)"
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

/// The "ผลลัพธ์ + เอกสาร" sub-tab: the pre-registered method and the manuscript
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
    let scope: Scope
    @ViewBuilder let analysisView: () -> AnalysisContent

    @State private var showing = Half.plan

    enum Half: String, CaseIterable, Identifiable {
        case plan, manuscript
        var id: String { rawValue }
        var label: String {
            switch self {
            case .plan: "แผนวิเคราะห์"
            case .manuscript: "ต้นฉบับ 5 บท"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("มุมมอง", selection: $showing) {
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
                    // Same identity rule as Chat and Analysis: switching
                    // workspace has to rebuild the screen, or it keeps showing
                    // the drafts of the project you just left (§19.1).
                    .id(scope.storageKey)
                    .task {
                        manuscripts.attach(store: ManuscriptStore(client: engine.client),
                                           analysis: analysis, scope: scope)
                        await manuscripts.load()
                    }
            }
        }
    }
}
