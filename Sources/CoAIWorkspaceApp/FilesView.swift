import SwiftUI
import AgentKit
import ToolBelt

// ─────────────────────────────────────────────────────────────
// File Viewer/Editor (ARCHITECTURE §14.2, P8.6) — the project's folder, in the
// app. Sits beside the notebook in "สคริปต์ + คอนโซล" because it answers the
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
//   rule you cannot see reads as a broken screen (the P11 "ลบร่างเครื่องมือ"
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
            problem = ReadableFailure.message(for: error, doing: "อ่านรายการไฟล์")
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
            problem = ReadableFailure.message(for: error, doing: "สร้างไฟล์")
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
            problem = ReadableFailure.message(for: error, doing: "เปลี่ยนชื่อ")
        }
    }

    func remove(_ entry: FileEntry) {
        guard let files else { return }
        do {
            try files.remove(entry.url)
            if selected?.url == entry.url { closeSelection() }
            reload()
        } catch {
            problem = ReadableFailure.message(for: error, doing: "ลบ")
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
            problem = ReadableFailure.message(for: error, doing: "เปิดไฟล์นี้")
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
            problem = ReadableFailure.message(for: error, doing: "บันทึกไฟล์นี้")
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
        .confirmationDialog("ยังไม่ได้บันทึก", isPresented: .constant(pendingSelection != nil)) {
            Button("ทิ้งการแก้ไข แล้วเปิดไฟล์ใหม่", role: .destructive) {
                if let next = pendingSelection { model.select(next) }
                pendingSelection = nil
            }
            Button("กลับไปแก้ต่อ", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("\(model.selected?.name ?? "ไฟล์นี้") มีการแก้ที่ยังไม่ได้บันทึก")
        }
        .alert(createIsDirectory ? "โฟลเดอร์ใหม่" : "ไฟล์ใหม่", isPresented: $creating) {
            TextField("ชื่อ", text: $newName)
            Button("สร้าง") { model.create(named: newName, directory: createIsDirectory) }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("ยกเลิก", role: .cancel) {}
        } message: {
            Text("สร้างในโฟลเดอร์ที่เปิดอยู่ · ถ้ามีชื่อนี้แล้วจะไม่เขียนทับให้")
        }
        .alert("เปลี่ยนชื่อ", isPresented: .constant(renaming != nil)) {
            TextField("ชื่อใหม่", text: $newName)
            Button("เปลี่ยน") {
                if let entry = renaming { model.rename(entry, to: newName) }
                renaming = nil
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("ยกเลิก", role: .cancel) { renaming = nil }
        } message: {
            Text(renaming.map { "เปลี่ยนชื่อ \($0.name)" } ?? "")
        }
        .confirmationDialog("ลบ \(deleting?.name ?? "")", isPresented: .constant(deleting != nil)) {
            Button("ย้ายไปถังขยะ", role: .destructive) {
                if let entry = deleting { model.remove(entry) }
                deleting = nil
            }
            Button("ยกเลิก", role: .cancel) { deleting = nil }
        } message: {
            // Said, because the difference between this and `rm` is the whole
            // reason the button is allowed to exist.
            Text("ย้ายไปถังขยะของเครื่อง — กู้คืนจาก Finder ได้ ไม่ได้ลบทิ้งถาวร")
        }
    }

    // MARK: - Left: the folder

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, url in
                    if index > 0 { Text("›").foregroundStyle(.secondary) }
                    Button(index == 0 ? "พื้นที่ทำงาน" : url.lastPathComponent) {
                        model.jump(to: index)
                    }
                    .buttonStyle(.plain)
                    .fontWeight(index == model.breadcrumb.count - 1 ? .semibold : .regular)
                    .accessibilityLabel(Text(index == 0
                                             ? "ขึ้นไปที่โฟลเดอร์บนสุดของพื้นที่ทำงาน"
                                             : "ขึ้นไปที่โฟลเดอร์ \(url.lastPathComponent)"))
                }
                Spacer()
                Menu {
                    Button("ไฟล์ใหม่…") { createIsDirectory = false; newName = ""; creating = true }
                    Button("โฟลเดอร์ใหม่…") { createIsDirectory = true; newName = ""; creating = true }
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel("สร้างไฟล์หรือโฟลเดอร์ใหม่")
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
                        .accessibilityLabel("อ่านโฟลเดอร์ใหม่")
                }
                .buttonStyle(.borderless)
                .help("อ่านโฟลเดอร์นี้ใหม่")
            }
            .padding(Space.box)

            Divider()

            if model.entries.isEmpty {
                ContentUnavailableView("โฟลเดอร์นี้ว่าง", systemImage: "folder",
                                       description: Text("ไฟล์ที่คำสั่งในสมุดงานหรือ `run_shell` เขียนไว้ จะมาโผล่ที่นี่"))
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
                Text("อ่านอย่างเดียว").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        // P8.6 — renaming and deleting live on the row, where the thing being
        // renamed is. An `.accessibilityAction` for each, because a context
        // menu is a gesture and a menu somebody cannot reach is not a feature.
        .contextMenu {
            Button("เปลี่ยนชื่อ…") { renaming = entry; newName = entry.name }
            Button("ลบ", role: .destructive) { deleting = entry }
        }
        .accessibilityAction(named: "เปลี่ยนชื่อ") { renaming = entry; newName = entry.name }
        .accessibilityAction(named: "ลบ") { deleting = entry }
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
        entry.isDirectory ? "โฟลเดอร์ \(entry.name)" : "ไฟล์ \(entry.name)"
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
                    .accessibilityLabel("เนื้อหาไฟล์ \(model.selected?.name ?? "")")
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
                    .accessibilityLabel("รูป \(name)")
                    // Said, because a picture is the one thing on this screen
                    // a screen reader cannot describe: the app knows the file
                    // name and the size and nothing about what is in it.
                    .accessibilityHint("แอปไม่ทราบว่าในรูปมีอะไร — แสดงไฟล์ตามที่อยู่บนดิสก์")
                } else {
                    ContentUnavailableView("เปิดรูปนี้ไม่ได้", systemImage: "photo.badge.exclamationmark",
                                           description: Text("ไฟล์นามสกุลรูป แต่ระบบถอดรหัสไม่ได้ — "
                                                             + "อาจเป็นไฟล์เสียหรือชนิดที่ macOS ไม่รองรับ"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .cannotShow(let why):
                ContentUnavailableView("เปิดในหน้านี้ไม่ได้", systemImage: "doc.questionmark",
                                       description: Text(why))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ContentUnavailableView("ยังไม่ได้เลือกไฟล์", systemImage: "sidebar.left",
                                       description: Text("เลือกไฟล์จากรายการทางซ้ายเพื่อเปิดดู"))
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
                Text("แก้แล้วยังไม่บันทึก").font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            // The reason a save is impossible sits next to the button rather
            // than replacing it: a rule nobody can see reads as a bug.
            if case .readOnly(_, let because) = model.content {
                Text(because).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .trailing)
            }
            if model.isDirty {
                Button("ย้อนกลับ") { model.revert() }
            }
            Button("บันทึก") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSave)
        }
        .padding(Space.box)
    }
}
