import SwiftUI
import AgentKit
import ToolBelt

// ─────────────────────────────────────────────────────────────
// File Viewer/Editor (ARCHITECTURE §14.2, P8.6) — the project's folder, in the
// app. Sits beside the notebook in "Script + console" because it answers the
// question the notebook creates: the cell wrote a file, so where is it.
//
// The rules live in `WorkspaceFiles` (ToolBelt), which `swift test` can reach.
// This file draws what that type returns and owns nothing else — a decision
// taken here would be a decision nothing checks, which is the mistake P11.3
// wrote down after `ConflictDetector` passed seven tests without ever being
// constructed.
//
// Two things the screen is responsible for on its own, both about honesty:
//
// - **The save button is disabled with the reason beside it, not hidden.** A
//   rule you cannot see reads as a broken screen (the P11 "delete this draft"
//   lesson). A `.docx` shows its extracted text *and* says why it cannot be
//   written back.
// - **Unsaved edits are visible before you leave.** Selecting another file
//   with a dirty buffer asks first, because the alternative is losing typing
//   silently, which is U20-1 in a new place.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class FilesViewModel {
    private(set) var entries: [FileEntry] = []
    private(set) var breadcrumb: [URL] = []
    private(set) var selected: FileEntry?
    private(set) var content: FileContent?
    private(set) var problem: String?
    /// The buffer the editor types into. Separate from what was loaded so
    /// "changed" is a comparison, not a guess.
    var draft: String = ""
    private(set) var loaded: String = ""
    private(set) var saving = false

    private var files: WorkspaceFiles?
    private var token: SaveToken?

    var isDirty: Bool { token != nil && draft != loaded }
    var canSave: Bool { token != nil && isDirty && !saving }

    var root: URL? { files?.root }

    func attach(root: URL) {
        let files = WorkspaceFiles(root: root)
        self.files = files
        breadcrumb = [files.root]
        reload()
    }

    func reload() {
        guard let files, let here = breadcrumb.last else { return }
        do {
            entries = try files.list(here)
            problem = nil
        } catch {
            entries = []
            problem = ReadableFailure.message(for: error, doing: t("listing the files", "Names the action that failed, in a sentence like “could not …”."))
        }
    }

    /// P8.6 — the three things the viewer could not do. Every one goes
    /// through `WorkspaceFiles`, which holds them to the workspace root, so
    /// this is a screen calling a rule rather than a screen with a rule of its
    /// own.
    func create(named name: String, directory: Bool) {
        guard let files, let here = breadcrumb.last else { return }
        do {
            _ = directory ? try files.createDirectory(named: name, in: here)
                          : try files.create(named: name, in: here)
            reload()
            problem = nil
        } catch {
            problem = ReadableFailure.message(for: error, doing: t("creating the file", "Names the action that failed."))
        }
    }

    func rename(_ entry: FileEntry, to name: String) {
        guard let files else { return }
        do {
            _ = try files.rename(entry.url, to: name)
            // The open file may be the one that moved, and a save token
            // pointing at a path that no longer exists would fail on the next
            // save with a confusing error.
            if selected?.url == entry.url { closeSelection() }
            reload()
        } catch {
            problem = ReadableFailure.message(for: error, doing: t("renaming it", "Names the action that failed."))
        }
    }

    func remove(_ entry: FileEntry) {
        guard let files else { return }
        do {
            try files.remove(entry.url)
            if selected?.url == entry.url { closeSelection() }
            reload()
        } catch {
            problem = ReadableFailure.message(for: error, doing: t("deleting it", "Names the action that failed."))
        }
    }

    private func closeSelection() {
        selected = nil
        token = nil
        draft = ""
        loaded = ""
    }

    func enter(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        breadcrumb.append(entry.url)
        reload()
    }

    func jump(to index: Int) {
        guard index < breadcrumb.count else { return }
        breadcrumb = Array(breadcrumb.prefix(index + 1))
        reload()
    }

    func select(_ entry: FileEntry) {
        guard let files, !entry.isDirectory else { return }
        selected = entry
        token = nil
        do {
            let opened = try files.open(entry.url)
            content = opened
            switch opened {
            case .editable(let text, let saveToken):
                draft = text; loaded = text; token = saveToken
            case .readOnly(let text, _):
                draft = text; loaded = text
            case .image, .cannotShow:
                // Nothing editable, so the buffer is emptied rather than left
                // holding the last file's text under a picture.
                draft = ""; loaded = ""
            }
            problem = nil
        } catch {
            content = nil
            draft = ""; loaded = ""
            problem = ReadableFailure.message(for: error, doing: t("opening this file", "Names the action that failed."))
        }
    }

    func save() {
        guard let files, let current = token else { return }
        saving = true
        defer { saving = false }
        do {
            token = try files.save(draft, using: current)
            loaded = draft
            problem = nil
            reload()
        } catch {
            // Includes the "somebody else wrote this file" refusal, which is
            // the message that matters most here — so `message(for:)` passes our
            // own sentences straight through and only translates the OS's
            // (a full disk, a folder we may not write to · P9.4).
            problem = ReadableFailure.message(for: error, doing: t("saving this file", "Names the action that failed."))
        }
    }

    /// Throws the buffer away and shows what is on disk now — the way out of a
    /// refused save.
    func revert() {
        guard let entry = selected else { return }
        select(entry)
    }
}

struct FilesView: View {
    @State private var model = FilesViewModel()
    let root: URL
    @State private var pendingSelection: FileEntry?
    @State private var renaming: FileEntry?
    @State private var deleting: FileEntry?
    @State private var newName = ""
    @State private var creating = false
    @State private var createIsDirectory = false

    var body: some View {
        HSplitView {
            browser.frame(minWidth: 240, idealWidth: 300)
            editor.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: root) { model.attach(root: root) }
        .confirmationDialog(t("Not saved", "Confirmation title when leaving an edited file."),
                            isPresented: .constant(pendingSelection != nil)) {
            Button(t("Discard the edits and open the other file",
                     "Confirming button that abandons unsaved changes."),
                   role: .destructive) {
                if let next = pendingSelection { model.select(next) }
                pendingSelection = nil
            }
            Button(t("Go back to editing", "Button that keeps the unsaved file open."),
                   role: .cancel) { pendingSelection = nil }
        } message: {
            Text(localised: "\(model.selected?.name ?? t("this file", "Stand-in when the file has no name to show.")) has edits that are not saved",
                 "Message in the unsaved-changes confirmation. Placeholder is the file name.")
        }
        .alert(createIsDirectory
               ? t("New folder", "Title of the create-folder prompt.")
               : t("New file", "Title of the create-file prompt."),
               isPresented: $creating) {
            TextField(t("Name", "Text field for the new file or folder's name."), text: $newName)
            Button(t("Create", "Button that creates the project.")) {
                model.create(named: newName, directory: createIsDirectory)
            }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(t("Cancel", "Button that dismisses the create prompt."), role: .cancel) {}
        } message: {
            Text(localised: "Created in the folder that is open · an existing name is not overwritten",
                 "Message under the create-file prompt.")
        }
        .alert(t("Rename", "Title of the rename prompt."), isPresented: .constant(renaming != nil)) {
            TextField(t("New name", "Text field for the new name."), text: $newName)
            Button(t("Rename it", "Button that applies the new name.")) {
                if let entry = renaming { model.rename(entry, to: newName) }
                renaming = nil
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(t("Cancel", "Button that dismisses the rename prompt."),
                   role: .cancel) { renaming = nil }
        } message: {
            Text(renaming.map {
                t("Rename \($0.name)", "Message in the rename prompt. Placeholder is the current name.")
            } ?? "")
        }
        .confirmationDialog(t("Delete \(deleting?.name ?? "")",
                              "Confirmation title. Placeholder is the file name."),
                            isPresented: .constant(deleting != nil)) {
            Button(t("Move it to the Trash", "Confirming button — says where the file goes, not “delete”."),
                   role: .destructive) {
                if let entry = deleting { model.remove(entry) }
                deleting = nil
            }
            Button(t("Cancel", "Button that dismisses the delete confirmation."),
                   role: .cancel) { deleting = nil }
        } message: {
            // Said, because the difference between this and `rm` is the whole
            // reason the button is allowed to exist.
            Text(localised: "It goes to the system Trash — recoverable from the Finder, not erased",
                 "Message in the delete confirmation, stating what actually happens.")
        }
    }

    // MARK: - Left: the folder

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, url in
                    if index > 0 { Text("›").foregroundStyle(.secondary) }
                    Button(index == 0
                           ? t("Workspace", "First crumb of the file path: the workspace root.")
                           : url.lastPathComponent) {
                        model.jump(to: index)
                    }
                    .buttonStyle(.plain)
                    .fontWeight(index == model.breadcrumb.count - 1 ? .semibold : .regular)
                    .accessibilityLabel(Text(index == 0
                                             ? t("Go up to the top folder of the workspace",
                                                 "Screen-reader label on the first path crumb.")
                                             : t("Go up to the folder \(url.lastPathComponent)",
                                                 "Screen-reader label on a path crumb. Placeholder is the folder name.")))
                }
                Spacer()
                Menu {
                    Button(t("New file…", "Menu item that creates a file.")) {
                        createIsDirectory = false; newName = ""; creating = true
                    }
                    Button(t("New folder…", "Menu item that creates a folder.")) {
                        createIsDirectory = true; newName = ""; creating = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel(t("Create a new file or folder", "Screen-reader label."))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    model.reload()
                } label: {
                    // The label sits on the `Image` rather than the `Button`
                    // because that is the form the rest of this app uses and the
                    // one `accessibility-audit.py` checks for.
                    Image(systemName: "arrow.clockwise")
                        .accessibilityLabel(t("Reload the folder", "Screen-reader label."))
                }
                .buttonStyle(.borderless)
                .help(t("Read this folder again", "Tooltip on the reload button."))
            }
            .padding(Space.box)

            Divider()

            if model.entries.isEmpty {
                ContentUnavailableView(t("This folder is empty", "Empty state in the file list."),
                                       systemImage: "folder",
                                       description: Text(localised: "Files written by a notebook cell or by `run_shell` turn up here",
                                                         "Empty-state explanation in the file list."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.entries, selection: .constant(model.selected?.id)) { entry in
                    Button {
                        open(entry)
                    } label: {
                        row(entry)
                    }
                    .buttonStyle(.plain)
                    // Just a label. `.accessibilityElement(children: .ignore)`
                    // was tried here to collapse the row into one element, and
                    // driving the built app showed what it costs: the row came
                    // back with **no AX actions at all**, so the only way left to
                    // open a file was a mouse click — the exact thing rule 2 of
                    // `accessibility-audit.py` exists to forbid. Collapsing a
                    // Button takes its button-ness with it, and `.isButton` adds
                    // the trait back without the action.
                    .accessibilityLabel(label(for: entry))
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ entry: FileEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: entry))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .fontWeight(model.selected?.id == entry.id ? .semibold : .regular)
                if !entry.isDirectory {
                    Text("\(entry.size.formatted(.byteCount(style: .file))) · "
                         + entry.modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.kind == .document {
                Text(localised: "read-only", "Marker on a file that cannot be written back.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        // P8.6 — renaming and deleting live on the row, where the thing being
        // renamed is. An `.accessibilityAction` for each, because a context
        // menu is a gesture and a menu somebody cannot reach is not a feature.
        .contextMenu {
            Button(t("Rename…", "Context-menu item that renames a file.")) {
                renaming = entry; newName = entry.name
            }
            Button(t("Delete", "Context-menu item that removes a file."),
                   role: .destructive) { deleting = entry }
        }
        .accessibilityAction(named: t("Rename", "Title of the rename prompt.")) {
            renaming = entry; newName = entry.name
        }
        .accessibilityAction(named: t("Delete", "Context-menu item that removes a file.")) { deleting = entry }
    }

    private func icon(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder" }
        switch entry.kind {
        case .editable: return "doc.plaintext"
        case .document: return "doc.richtext"
        case .image: return "photo"
        case .opaque: return "shippingbox"
        }
    }

    private func label(for entry: FileEntry) -> String {
        entry.isDirectory
            ? t("folder \(entry.name)", "Screen-reader label for a folder row. Placeholder is its name.")
            : t("file \(entry.name)", "Screen-reader label for a file row. Placeholder is its name.")
    }

    private func open(_ entry: FileEntry) {
        if entry.isDirectory { model.enter(entry); return }
        // Never drop typing on the floor without asking (U20-1's lesson).
        if model.isDirty { pendingSelection = entry } else { model.select(entry) }
    }

    // MARK: - Right: the file

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch model.content {
            case .editable:
                TextEditor(text: $model.draft)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel(t("Contents of \(model.selected?.name ?? "")",
                                          "Screen-reader label for the file editor. Placeholder is the file name."))
            case .readOnly(let text, _):
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.box)
                }
            case .image(let data, let name):
                // Decoded here rather than in ToolBelt: that module has no UI
                // framework in it and should not gain one for a preview.
                if let image = NSImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .padding(Space.box)
                    }
                    .accessibilityLabel(t("image \(name)", "Screen-reader label for an image. Placeholder is its name."))
                    // Said, because a picture is the one thing on this screen
                    // a screen reader cannot describe: the app knows the file
                    // name and the size and nothing about what is in it.
                    .accessibilityHint(t("the app does not know what the image shows — it displays the file as it is on disk",
                                         "Screen-reader hint that no description of the image exists."))
                } else {
                    ContentUnavailableView(t("This image cannot be opened", "Empty state for an undecodable image."),
                                           systemImage: "photo.badge.exclamationmark",
                                           description: Text(localised: "It has an image extension but cannot be decoded — it may be damaged, or a kind macOS does not support",
                                                             "Explains why an image would not open."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .cannotShow(let why):
                ContentUnavailableView(t("This cannot be opened here", "Empty state for a file the viewer cannot show."),
                                       systemImage: "doc.questionmark",
                                       description: Text(why))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ContentUnavailableView(t("No file selected", "Empty state before a file is chosen."),
                                       systemImage: "sidebar.left",
                                       description: Text(localised: "Choose a file from the list on the left to open it",
                                                         "Empty-state instruction in the file viewer."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let problem = model.problem {
                Divider()
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.box)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.selected?.name ?? "—").fontWeight(.semibold)
            if model.isDirty {
                Text(localised: "edited, not saved", "Marker on a file with unsaved changes.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            // The reason a save is impossible sits next to the button rather
            // than replacing it: a rule nobody can see reads as a bug.
            if case .readOnly(_, let because) = model.content {
                Text(because).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .trailing)
            }
            if model.isDirty {
                Button(t("Revert", "Button that discards unsaved edits.")) { model.revert() }
            }
            Button(t("Save", "Button that stores the edited entities.")) { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSave)
        }
        .padding(Space.box)
    }
}
