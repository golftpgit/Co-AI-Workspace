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
        .confirmationDialog(t("Remove “\(pendingDeletion?.title ?? "")” from the knowledge base?",
                              "Confirmation title. Placeholder is the document's title."),
                            isPresented: .init(get: { pendingDeletion != nil },
                                               set: { if !$0 { pendingDeletion = nil } }),
                            presenting: pendingDeletion) { document in
            Button(t("Delete the document", "Confirming button that removes a document."),
                   role: .destructive) {
                Task { await model.delete(documentID: document.documentID) }
            }
            Button(t("Cancel", "Button that dismisses the delete confirmation."),
                   role: .cancel) { pendingDeletion = nil }
        } message: { document in
            Text(localised: "All \(document.chunkCount) passages, the entities and this document's edges in the graph go too, and it cannot be undone — the original file would have to be added again",
                 "Says exactly what deleting a document takes with it. Placeholder is how many passages.")
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
                    .accessibilityAction(named: t("Delete this document", "Screen-reader action name.")) {
                        pendingDeletion = document
                    }
                    // The same corrections as the context menu, one action each:
                    // a right-click is a mouse, and every class in the menu has
                    // to be reachable from the rotor as well.
                    .accessibilityActions {
                        ForEach(Classifier.commonSubjects, id: \.self) { code in
                            Button(t("Classify as \(code)",
                                     "Menu item that files a document under a subject code. Placeholder is the code.")) {
                                model.reclassify(document, to: [code])
                            }
                        }
                        Button(t("Mark it as not classifiable yet",
                                 "Menu item that records that no subject code fits.")) {
                            model.reclassify(document, to: [])
                        }
                    }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.shelvedDocuments.isEmpty, !model.documents.isEmpty {
                    ContentUnavailableView(t("No document in this category", "Empty state while a filter is on."),
                                           systemImage: "tray",
                                           description: Text(localised: "Press “All” to see the whole base again",
                                                             "Empty-state instruction while a filter is on."))
                } else if model.documents.isEmpty {
                    ContentUnavailableView(t("No documents in the knowledge base yet", "Empty state on the knowledge screen."),
                                           systemImage: "books.vertical",
                                           description: Text(localised: "Press “Add document” to upload a PDF, a scan, a Word file or plain text",
                                                             "Empty-state instruction on the knowledge screen."))
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
        Menu(t("Reclassify", "Context menu for changing a document's subject code.")) {
            ForEach(Classifier.commonSubjects, id: \.self) { code in
                Button(code) { model.reclassify(document, to: [code]) }
            }
            Divider()
            Button(t("Not classifiable yet", "Menu item that clears a document's subject code.")) {
                model.reclassify(document, to: [])
            }
        }
        Button(t("Delete this document…", "Context-menu item that starts removing a document."),
               role: .destructive) { pendingDeletion = document }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(t("Scope", "Picker: which slice of the knowledge base is showing."),
                   selection: Binding(
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
            // no width to give it: "Scope" was being squeezed into a 20pt
            // column and broken across three lines mid-word. The accessibility
            // label below is what carries the name.
            .labelsHidden()
            .accessibilityLabel(t("Choose the knowledge base scope", "Screen-reader label."))

            HStack {
                Button {
                    chooseFilesToIngest()
                } label: {
                    Label(t("Add document", "Button that ingests a file into the knowledge base."),
                          systemImage: "plus")
                }
                .accessibilityLabel(t("Add a document to the knowledge base", "Screen-reader label."))

                Picker(t("Document kind", "Picker: what kind of document is being added."),
                       selection: $ingestKind) {
                    ForEach(DocumentKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(t("Kind of the document being added", "Screen-reader label."))
                .accessibilityHint(t("a research protocol is the kind the analysis screen builds a plan from",
                                     "Screen-reader hint explaining why the kind matters."))

                Spacer()

                Menu {
                    Button(t("Export the base…", "Menu item that writes the knowledge base to a file.")) {
                        exportArchive()
                    }
                    Button(t("Import a base…", "Menu item that reads a knowledge base from a file.")) {
                        importArchive()
                    }
                } label: {
                    Label(t("Manage", "Overflow menu on the knowledge screen."), systemImage: "ellipsis.circle")
                }
                .accessibilityLabel(t("Export or import the knowledge base", "Screen-reader label."))
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(localised: "\(model.documentCount) documents · \(model.chunkCount) passages",
                 "Size of the knowledge base. Placeholders: how many documents and how many passages.")
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
                TextField(t("Search the knowledge base", "Placeholder in the knowledge search field."),
                          text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.search() } }
                    .accessibilityLabel(t("Search term", "Screen-reader label for the knowledge search field."))
                Button(t("Search", "Button that runs the knowledge search.")) { Task { await model.search() } }
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
                    ContentUnavailableView(t("No results yet", "Empty state in the knowledge search pane."),
                                           systemImage: "magnifyingglass",
                                           description: Text(localised: "Type a search term and press Enter",
                                                             "Empty-state instruction in the search pane."))
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
        panel.message = t("Choose the documents to add to the knowledge base",
                          "Message in the file picker that ingests documents.")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        // T3 by default, editable afterwards — §11.3 says an upload must not
        // skip the credibility question, not that the user answers it twice.
        // The kind is asked here rather than inferred later (§12.4): the
        // person choosing the file is the only one who knows whether it is a
        // proposal, and `other` is a real answer.
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
                Text(localised: "\(document.chunkCount) passages",
                     "How many passages a document was split into. Placeholder is a count.")
                if !document.hasVectors {
                    Label(t("no vectors", "Marker on a document indexed without embeddings."),
                          systemImage: "exclamationmark.circle")
                        .help(t("This document was indexed while the embedding model was unavailable — only text search reaches it",
                                "Tooltip explaining what a missing vector index costs."))
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
                if let page = result.provenance.page {
                    Text(localised: "p. \(page)", "Page number of a passage. Placeholder is the page.")
                }
                if result.provenance.section == "OCR" {
                    Label("OCR", systemImage: "text.viewfinder")
                        .help(t("This text came from reading an image and may contain errors",
                                "Tooltip on a passage recovered by OCR."))
                }
                Spacer()
                // Why this row is here at all — a ranking nobody can explain is
                // a ranking nobody trusts.
                Text(rankExplanation).foregroundStyle(.tertiary)
                Button(t("Edit entities", "Button that opens the entity editor for a passage."), action: edit)
                    .buttonStyle(.link)
                    .accessibilityLabel(t("Edit the entities of this passage", "Screen-reader label."))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var rankExplanation: String {
        switch (result.lexicalRank, result.semanticRank) {
        case (let lexical?, let semantic?):
            t("text #\(lexical) · meaning #\(semantic)",
              "Where a result ranked in each kind of search. Placeholders: its text rank and its semantic rank.")
        case (let lexical?, nil):
            t("text #\(lexical)", "Where a result ranked in text search. Placeholder is its rank.")
        case (nil, let semantic?):
            t("meaning #\(semantic)", "Where a result ranked in semantic search. Placeholder is its rank.")
        default: ""
        }
    }
}

private struct TierBadge: View {
    let tier: SourceTier?
    /// Needed only to say *why* there is no tier. Two origins legitimately
    /// have none and they are not the same thing: something the system wrote,
    /// and an interview. Saying "written by the system" over a participant's words —
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
        if let tier {
            return t("trust tier \(tier.rawValue.uppercased())",
                     "Screen-reader label for a source's trust tier. Placeholder is the tier code.")
        }
        switch origin {
        case .fieldwork:
            // Not "low credibility". Primary data is not on that scale at all
            // (§11.3), and the scale is about published sources.
            return t("primary data from this project — not on the external credibility scale at all",
                     "Explains why fieldwork has no trust tier.")
        case .userAuthored:
            return t("written by the system, with no external trust tier",
                     "Explains why generated text has no trust tier.")
        default:
            return t("no external trust tier", "Screen-reader label when a source has no tier.")
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
            Text(localised: "Edit the entities of this passage", "Title of the entity editor sheet.")
                .font(.headline)
            Text(chunk.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 140)
                .border(.separator)
                .accessibilityLabel(t("Entity list, one per line", "Screen-reader label for the entity editor."))

            Text(localised: "One per line — entities are indexed alongside the text, so editing them changes what search finds",
                 "Explains the consequence of editing entities.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(t("Cancel", "Button that closes the entity editor without saving.")) { dismiss() }
                Button(t("Save", "Button that stores the edited entities.")) {
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
/// what "project" means.
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

    /// `nil` when the choice cannot be made yet: "project" with no project
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
        case .central: t("shared", "Notebook scope: visible everywhere.")
        case .project: t("project", "Knowledge scope: this project only.")
        case .policy: t("policy", "Notebook scope: belongs to policy work.")
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
                chip(code: nil, label: t("All", "Shelf filter that clears the subject filter."),
                     count: model.documents.count)
                ForEach(shelf.byCode, id: \.code) { entry in
                    chip(code: entry.code, label: "\(entry.code) \(entry.label)",
                         count: entry.count)
                }
                if shelf.unclassified > 0 {
                    // Its own chip, not a gap in the chart: "what could nothing
                    // be filed under" is the question the shelf exists to make
                    // askable, and sweeping these into A would answer it wrongly.
                    chip(code: KnowledgeViewModel.unclassifiedFilter,
                         label: t("Not classifiable yet", "Shelf filter for documents with no subject code."),
                         count: shelf.unclassified)
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
        .accessibilityLabel(t("\(label) — \(count) documents\(isSelected ? t(" · filtering by this category", "Appended to a shelf chip that is active.") : t(" · press to filter", "Appended to a shelf chip that is not active."))",
                              "Screen-reader label for a shelf chip. Placeholders: the category, how many documents, and whether it is the active filter."))
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
                      ? t("classified by the user", "How a document got its subject code.")
                      : t("guessed by the system — \(classification.reason)",
                          "How a document got its subject code. Placeholder is the reason given."))
                .accessibilityLabel(
                    t("category \(classification.subjects.map(\.code).joined(separator: " and "))\(classification.assignedBy == .user ? t(" · classified by the user", "Appended when a person set the category.") : t(" · guessed by the system", "Appended when the system set the category."))",
                      "Screen-reader label for a document's category. Placeholder is the list of codes."))
        } else {
            Text(localised: "Not classifiable yet", "Shown on a document with no subject code.")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(t("Not classifiable yet", "Shelf filter for documents with no subject code."))
        }
    }
}
