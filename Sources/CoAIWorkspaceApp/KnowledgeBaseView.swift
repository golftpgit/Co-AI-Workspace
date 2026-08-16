import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// The Knowledge Base screen (ARCHITECTURE §14.2, P2.7): what is in the
// library, what it answers, and where every answer came from.
//
// Every row shows its tier, because a result whose credibility is invisible is
// a result the user has to take on faith (§11.3).
// ─────────────────────────────────────────────────────────────

/// Renamed from `KnowledgeView` when §21.2's domain type arrived with the same
/// name (P12.2). Inside the app target the local type shadows the imported one,
/// so any future `KnowledgeView(...)` here would have silently built a SwiftUI
/// screen where a retrieval filter was meant. The name belongs to the concept
/// the architecture defines; this is the tab that shows the library.
struct KnowledgeBaseView: View {
    @Bindable var model: KnowledgeViewModel
    @State private var selection: String?
    /// What the next upload will be filed as (§12.4, P6.7). Beside the button
    /// rather than in a sheet afterwards: the answer is known at the moment
    /// somebody picks the file, and a question asked later is a question
    /// answered "other" forever.
    @State private var ingestKind: DocumentKind = .other
    @State private var editingChunk: IndexedChunk?
    /// Deleting takes the document, its chunks, its entities and its graph
    /// edges, and the file it came from is not kept — so the menu item asks
    /// first rather than doing it on the way past.
    @State private var pendingDeletion: DocumentSummary?

    var body: some View {
        NavigationSplitView {
            documentList
        } detail: {
            searchPane
        }
        .task { model.refresh() }
        .sheet(item: $editingChunk) { chunk in
            EntityEditor(chunk: chunk) { entities in
                Task { await model.updateEntities(chunkID: chunk.id, to: entities) }
            }
        }
        .confirmationDialog("ลบ “\(pendingDeletion?.title ?? "")” ออกจากคลัง?",
                            isPresented: .init(get: { pendingDeletion != nil },
                                               set: { if !$0 { pendingDeletion = nil } }),
                            presenting: pendingDeletion) { document in
            Button("ลบเอกสาร", role: .destructive) {
                Task { await model.delete(documentID: document.documentID) }
            }
            Button("ยกเลิก", role: .cancel) { pendingDeletion = nil }
        } message: { document in
            Text("ทั้ง \(document.chunkCount) ส่วน entity และความสัมพันธ์ในกราฟของเอกสารนี้"
                 + "จะถูกลบไปด้วย และย้อนกลับไม่ได้ — ต้องเพิ่มไฟล์ต้นฉบับเข้ามาใหม่")
        }
    }

    // MARK: - documents

    private var documentList: some View {
        VStack(spacing: 0) {
            ShelfBar(model: model)
            Divider()
            List(model.shelvedDocuments, selection: $selection) { document in
                DocumentRow(document: document,
                            classification: model.classification(of: document))
                    .contextMenu { rowMenu(for: document) }
                    .accessibilityAction(named: "ลบเอกสารนี้") {
                        pendingDeletion = document
                    }
                    // The same corrections as the context menu, one action each:
                    // a right-click is a mouse, and every class in the menu has
                    // to be reachable from the rotor as well.
                    .accessibilityActions {
                        ForEach(Classifier.commonSubjects, id: \.self) { code in
                            Button("จัดหมวดเป็น \(code)") { model.reclassify(document, to: [code]) }
                        }
                        Button("ทำเครื่องหมายว่ายังจัดหมวดไม่ได้") {
                            model.reclassify(document, to: [])
                        }
                    }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.shelvedDocuments.isEmpty, !model.documents.isEmpty {
                    ContentUnavailableView("ไม่มีเอกสารในหมวดนี้", systemImage: "tray",
                                           description: Text("กด “ทั้งหมด” เพื่อกลับไปดูทั้งคลัง"))
                } else if model.documents.isEmpty {
                    ContentUnavailableView("ยังไม่มีเอกสารในคลัง", systemImage: "books.vertical",
                                           description: Text("กด “เพิ่มเอกสาร” เพื่ออัปโหลด PDF, รูปสแกน, Word หรือข้อความ"))
                }
            }

            Divider()
            toolbar
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 320)
    }

    /// The row's own actions, extracted so the menu call site stays short
    /// enough to read — and so its accessibility mirror sits next to it rather
    /// than a screenful below, which is what the audit checks for. (Naming the
    /// modifier here would trip that audit on a comment, which is a fair
    /// trade: it matches text, and text is what a reviewer reads too.)
    @ViewBuilder
    private func rowMenu(for document: DocumentSummary) -> some View {
        // §11.9: a class the system guessed has to be correctable, and this is
        // where somebody notices it is wrong — looking at the shelf.
        Menu("จัดหมวดใหม่") {
            ForEach(Classifier.commonSubjects, id: \.self) { code in
                Button(code) { model.reclassify(document, to: [code]) }
            }
            Divider()
            Button("ยังจัดหมวดไม่ได้") { model.reclassify(document, to: []) }
        }
        Button("ลบเอกสารนี้…", role: .destructive) { pendingDeletion = document }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("ขอบเขต", selection: Binding(
                get: { ScopeChoice(model.scope) },
                set: { choice in
                    // A project scope needs a project. Before P10.1 this read
                    // `ProjectID("default")`, which meant every project's
                    // documents landed in one pile.
                    guard let scope = choice.scope(of: model.currentProject) else { return }
                    Task { await model.changeScope(to: scope) }
                })) {
                ForEach(ScopeChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                        .disabled(choice == .project && model.currentProject == nil)
                }
            }
            .pickerStyle(.segmented)
            // A segmented picker still lays out its label, and the sidebar has
            // no width to give it: "ขอบเขต" was being squeezed into a 20pt
            // column and broken across three lines mid-word. The accessibility
            // label below is what carries the name.
            .labelsHidden()
            .accessibilityLabel("เลือกขอบเขตของคลังความรู้")

            HStack {
                Button {
                    chooseFilesToIngest()
                } label: {
                    Label("เพิ่มเอกสาร", systemImage: "plus")
                }
                .accessibilityLabel("เพิ่มเอกสารเข้าคลัง")

                Picker("ชนิดเอกสาร", selection: $ingestKind) {
                    ForEach(DocumentKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("ชนิดของเอกสารที่กำลังจะเพิ่ม")
                .accessibilityHint("โครงร่างวิจัยคือชนิดที่หน้าวิเคราะห์ใช้ตั้งต้นแผนการวิเคราะห์")

                Spacer()

                Menu {
                    Button("ส่งออกคลัง…") { exportArchive() }
                    Button("นำเข้าคลัง…") { importArchive() }
                } label: {
                    Label("จัดการ", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("ส่งออกหรือนำเข้าคลังความรู้")
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text("\(model.documentCount) เอกสาร · \(model.chunkCount) ส่วน")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Space.box)
        .disabled(model.isWorking)
    }

    // MARK: - search

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("ค้นในคลังความรู้", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.search() } }
                    .accessibilityLabel("คำค้น")
                Button("ค้น") { Task { await model.search() } }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(Space.box)

            if let status = model.status {
                Label(status.message, systemImage: status.isError
                      ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(status.isError ? .orange : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .textSelection(.enabled)
            }

            Divider()

            List(model.results, id: \.chunk.id) { result in
                ResultRow(result: result) { editingChunk = result.chunk }
            }
            .overlay {
                if model.results.isEmpty {
                    ContentUnavailableView("ยังไม่มีผลค้นหา", systemImage: "magnifyingglass",
                                           description: Text("พิมพ์คำค้นแล้วกด Enter"))
                }
            }
        }
        .overlay {
            if model.isWorking { ProgressView().controlSize(.large) }
        }
    }

    // MARK: - panels

    private func chooseFilesToIngest() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "เลือกเอกสารที่จะเพิ่มเข้าคลัง"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        // T3 by default, editable afterwards — §11.3 says an upload must not
        // skip the credibility question, not that the user answers it twice.
        // The kind is asked here rather than inferred later (§12.4): the
        // person choosing the file is the only one who knows whether it is a
        // proposal, and `อื่น ๆ` is a real answer.
        Task { await model.ingest(urls, tier: .t3, kind: ingestKind) }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "knowledge-base.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(to: url) }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importArchive(from: url) }
    }
}

// MARK: - rows

private struct DocumentRow: View {
    let document: DocumentSummary
    let classification: Classification

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.title).font(.body).lineLimit(2)
            HStack(spacing: 6) {
                TierBadge(tier: document.tier, origin: document.origin)
                ShelfBadge(classification: classification)
                Text("\(document.chunkCount) ส่วน")
                if !document.hasVectors {
                    Label("ไม่มี vector", systemImage: "exclamationmark.circle")
                        .help("เอกสารนี้ถูก index ตอนที่โมเดล embedding ใช้ไม่ได้ — ค้นได้เฉพาะแบบข้อความ")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !document.entities.isEmpty {
                Text(document.entities.prefix(4).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.chunk.text)
                .font(.body)
                .lineLimit(4)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                TierBadge(tier: result.tier, origin: result.chunk.provenance.origin)
                Text(result.provenance.title).lineLimit(1)
                if let page = result.provenance.page { Text("น. \(page)") }
                if result.provenance.section == "OCR" {
                    Label("OCR", systemImage: "text.viewfinder")
                        .help("ข้อความนี้มาจากการอ่านภาพ อาจมีความคลาดเคลื่อน")
                }
                Spacer()
                // Why this row is here at all — a ranking nobody can explain is
                // a ranking nobody trusts.
                Text(rankExplanation).foregroundStyle(.tertiary)
                Button("แก้ entity", action: edit)
                    .buttonStyle(.link)
                    .accessibilityLabel("แก้ไข entity ของส่วนนี้")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var rankExplanation: String {
        switch (result.lexicalRank, result.semanticRank) {
        case (let lexical?, let semantic?): "ข้อความ #\(lexical) · ความหมาย #\(semantic)"
        case (let lexical?, nil): "ข้อความ #\(lexical)"
        case (nil, let semantic?): "ความหมาย #\(semantic)"
        default: ""
        }
    }
}

private struct TierBadge: View {
    let tier: SourceTier?
    /// Needed only to say *why* there is no tier. Two origins legitimately
    /// have none and they are not the same thing: something the system wrote,
    /// and an interview. Saying "ระบบเขียนเอง" over a participant's words —
    /// which is what this did until it was driven — describes the wrong thing
    /// to somebody deciding how much to trust it.
    var origin: Origin?

    var body: some View {
        Text(tier?.rawValue.uppercased() ?? "—")
            .font(.caption2.monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(colour.opacity(0.18), in: Capsule())
            .foregroundStyle(colour)
            .accessibilityLabel(label)
    }

    private var label: String {
        if let tier { return "ระดับความน่าเชื่อถือ \(tier.rawValue.uppercased())" }
        switch origin {
        case .fieldwork:
            // Not "low credibility". Primary data is not on that scale at all
            // (§11.3), and the scale is about published sources.
            return "ข้อมูลปฐมภูมิของโครงการนี้ — ไม่ได้อยู่บนสเกลความน่าเชื่อถือของแหล่งภายนอก"
        case .userAuthored:
            return "ระบบเขียนเอง ไม่มีระดับความน่าเชื่อถือภายนอก"
        default:
            return "ไม่มีระดับความน่าเชื่อถือภายนอก"
        }
    }

    private var colour: Color {
        switch tier {
        case .t1: .green
        case .t2: .teal
        case .t3: .blue
        case .t4: .orange
        case .t5: .red
        case nil: .secondary
        }
    }
}

// MARK: - entity editor

private struct EntityEditor: View {
    let chunk: IndexedChunk
    let save: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(chunk: IndexedChunk, save: @escaping ([String]) -> Void) {
        self.chunk = chunk
        self.save = save
        _text = State(initialValue: chunk.entities.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("แก้ entity ของส่วนนี้").font(.headline)
            Text(chunk.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 140)
                .border(.separator)
                .accessibilityLabel("รายชื่อ entity บรรทัดละหนึ่งรายการ")

            Text("บรรทัดละหนึ่งรายการ — entity ถูก index ไปพร้อมเนื้อความ แก้แล้วผลค้นหาจะเปลี่ยนตาม")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("ยกเลิก") { dismiss() }
                Button("บันทึก") {
                    save(text.components(separatedBy: .newlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.section)
        .frame(width: 460)
    }
}

// MARK: - scope picker

/// Shared with the graph tab: both draw one library and both have to say which
/// one. `private` while there was a single caller, `internal` now that there
/// are two — a second copy would drift and the two tabs would disagree about
/// what "โปรเจกต์" means.
enum ScopeChoice: String, CaseIterable, Identifiable {
    case central, project, policy

    init(_ scope: Scope) {
        switch scope {
        case .central: self = .central
        case .project: self = .project
        case .policy: self = .policy
        // A run's Situation Board is not a library a person browses (§22.5):
        // it exists for the length of one run and is read by the teams in it.
        // Shown as the central library rather than adding a picker option
        // nobody could usefully choose.
        case .board: self = .central
        }
    }

    var id: String { rawValue }

    /// `nil` when the choice cannot be made yet: "โปรเจกต์" with no project
    /// selected is not a scope, and inventing an id for it is exactly the bug
    /// this replaced.
    func scope(of project: ProjectID?) -> Scope? {
        switch self {
        case .central: .central
        case .project: project.map { Scope.project($0) }
        case .policy: .policy
        }
    }

    var label: String {
        switch self {
        case .central: "ส่วนกลาง"
        case .project: "โปรเจกต์"
        case .policy: "นโยบาย"
        }
    }
}


// ─────────────────────────────────────────────────────────────
// The shelf (§11.9, P18.4)

/// What is in the library, by class, with the unclassified counted rather than
/// hidden. Filtering is the point of showing it: a proportion nobody can click
/// into is a chart.
private struct ShelfBar: View {
    @Bindable var model: KnowledgeViewModel

    var body: some View {
        let shelf = model.shelf
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(code: nil, label: "ทั้งหมด", count: model.documents.count)
                ForEach(shelf.byCode, id: \.code) { entry in
                    chip(code: entry.code, label: "\(entry.code) \(entry.label)",
                         count: entry.count)
                }
                if shelf.unclassified > 0 {
                    // Its own chip, not a gap in the chart: "what could nothing
                    // be filed under" is the question the shelf exists to make
                    // askable, and sweeping these into A would answer it wrongly.
                    chip(code: KnowledgeViewModel.unclassifiedFilter,
                         label: "ยังจัดหมวดไม่ได้", count: shelf.unclassified)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 34)
    }

    private func chip(code: String?, label: String, count: Int) -> some View {
        let isSelected = model.shelfFilter == code
        return Button {
            model.shelfFilter = code
        } label: {
            Text("\(label) · \(count)").font(.caption)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary),
                    in: Capsule())
        .accessibilityLabel("\(label) — \(count) เอกสาร"
                            + (isSelected ? " · กำลังกรองด้วยหมวดนี้" : " · กดเพื่อกรอง"))
    }
}

/// The class on a document row, and whether anybody agreed to it.
private struct ShelfBadge: View {
    let classification: Classification

    var body: some View {
        if classification.isClassified {
            Text(classification.subjects.map(\.code).joined(separator: "/"))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.control))
                // §11.9: a guess that cannot be told from a decision is a guess
                // nobody will ever correct.
                .help(classification.assignedBy == .user
                      ? "จัดหมวดโดยผู้ใช้"
                      : "ระบบเดา — \(classification.reason)")
                .accessibilityLabel(
                    "หมวด \(classification.subjects.map(\.code).joined(separator: " และ "))"
                    + (classification.assignedBy == .user ? " · ผู้ใช้จัดเอง" : " · ระบบเดา"))
        } else {
            Text("ยังจัดหมวดไม่ได้")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("ยังจัดหมวดไม่ได้")
        }
    }
}
