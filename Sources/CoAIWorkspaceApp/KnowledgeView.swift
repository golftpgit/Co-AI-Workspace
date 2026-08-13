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

struct KnowledgeView: View {
    @Bindable var model: KnowledgeViewModel
    @State private var selection: String?
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
            List(model.documents, selection: $selection) { document in
                DocumentRow(document: document)
                    .contextMenu {
                        Button("ลบเอกสารนี้…", role: .destructive) {
                            pendingDeletion = document
                        }
                    }
                    .accessibilityAction(named: "ลบเอกสารนี้") {
                        pendingDeletion = document
                    }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.documents.isEmpty {
                    ContentUnavailableView("ยังไม่มีเอกสารในคลัง", systemImage: "books.vertical",
                                           description: Text("กด “เพิ่มเอกสาร” เพื่ออัปโหลด PDF, รูปสแกน, Word หรือข้อความ"))
                }
            }

            Divider()
            toolbar
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 320)
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
        .padding(12)
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
            .padding(12)

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
        Task { await model.ingest(urls, tier: .t3) }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "knowledge-base.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.title).font(.body).lineLimit(2)
            HStack(spacing: 6) {
                TierBadge(tier: document.tier)
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
                TierBadge(tier: result.tier)
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

    var body: some View {
        Text(tier?.rawValue.uppercased() ?? "—")
            .font(.caption2.monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(colour.opacity(0.18), in: Capsule())
            .foregroundStyle(colour)
            .accessibilityLabel(tier.map { "ระดับความน่าเชื่อถือ \($0.rawValue.uppercased())" }
                                ?? "ระบบเขียนเอง ไม่มีระดับความน่าเชื่อถือภายนอก")
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
        .padding(16)
        .frame(width: 460)
    }
}

// MARK: - scope picker

private enum ScopeChoice: String, CaseIterable, Identifiable {
    case central, project, policy

    init(_ scope: Scope) {
        switch scope {
        case .central: self = .central
        case .project: self = .project
        case .policy: self = .policy
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
