import Testing
import Foundation
@testable import ToolBelt

// The File Viewer's rules (ARCHITECTURE §14.2, P8.6). Every test here is a way
// somebody loses work if the rule stops holding, which is why they are pinned
// rather than left to the screen to remember.

private func makeRoot() throws -> URL {
    let root = URL.temporaryDirectory
        .appending(path: "coai-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ text: String, _ name: String, in root: URL) throws -> URL {
    let url = root.appending(path: name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Suite("Workspace files — what may be read")
struct WorkspaceFileReadingTests {

    @Test("a text file opens editable and comes back byte for byte")
    func opensEditable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("บรรทัดไทย\nline two\n", "notes.md", in: root)

        let files = WorkspaceFiles(root: root)
        guard case .editable(let text, _) = try files.open(root.appending(path: "notes.md"))
        else { Issue.record("expected an editable file"); return }

        #expect(text == "บรรทัดไทย\nline two\n")
    }

    @Test("listing puts directories first, then names in order")
    func listingOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("a", "beta.txt", in: root)
        _ = try write("a", "alpha.txt", in: root)
        _ = try write("a", "sub/inner.txt", in: root)

        let names = try WorkspaceFiles(root: root).list().map(\.name)
        #expect(names == ["sub", "alpha.txt", "beta.txt"])
    }

    @Test("a file that is not UTF-8 says which assumption failed, not 'binary'")
    func nonUTF8() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "latin.txt")
        try Data([0xFF, 0xFE, 0x41]).write(to: url)

        guard case .cannotShow(let why) = try WorkspaceFiles(root: root).open(url)
        else { Issue.record("expected cannotShow"); return }
        #expect(why.contains("UTF-8"))
    }
}

@Suite("Workspace files — the four rules")
struct WorkspaceFileRuleTests {

    // Rule 1. Clamping instead of refusing would show one file while naming
    // another, which is the worst available outcome for a viewer.
    @Test("a path above the root is refused, not clamped")
    func refusesEscapeViaDotDot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try write("secret", "outside.txt", in: root.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: outside) }

        let files = WorkspaceFiles(root: root)
        #expect(throws: FileAccessError.self) {
            try files.open(root.appending(path: "../\(outside.lastPathComponent)"))
        }
    }

    // The escape that matters is the one that does not look like an escape.
    @Test("a symlink pointing out of the root is refused too")
    func refusesEscapeViaSymlink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try write("secret", "target.txt", in: root.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = root.appending(path: "looks-local.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: FileAccessError.self) { try WorkspaceFiles(root: root).open(link) }
    }

    // Rule 2. Text pulled out of a .docx is a rendering. Writing it back would
    // replace a formatted document with a flat one, so there must be no way to
    // reach `save` from it — enforced by `.readOnly` carrying no token.
    @Test("an extracted document is read-only, and carries nothing that could save it")
    func documentsAreReadOnly() throws {
        #expect(WorkspaceFiles.kind(of: URL(filePath: "/x/report.docx")) == .document)
        #expect(WorkspaceFiles.kind(of: URL(filePath: "/x/slides.pptx")) == .document)
        #expect(WorkspaceFiles.kind(of: URL(filePath: "/x/paper.pdf")) == .document)
        #expect(WorkspaceFiles.kind(of: URL(filePath: "/x/paper.pdf")).isEditable == false)
    }

    // Rule 3. Truncating is the dangerous option: edit what looks whole, save,
    // and the tail is gone. The error carries the size so it is actionable.
    @Test("a file past the limit is refused with its size, never truncated")
    func refusesOversize() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = String(repeating: "x", count: WorkspaceFiles.editableByteLimit + 1)
        let url = try write(big, "huge.txt", in: root)

        let files = WorkspaceFiles(root: root)
        do {
            _ = try files.open(url)
            Issue.record("expected the open to be refused")
        } catch let error as FileAccessError {
            guard case .tooLarge(_, let bytes, let limit) = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(bytes > limit)
        }
    }

    // Rule 4. The agent writes into this folder while a person has it open.
    // Last-writer-wins throws away whichever of them was slower and tells
    // neither — so the save is refused and the person is told why.
    @Test("saving is refused when the file changed on disk after it was read")
    func refusesStaleSave() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("original\n", "shared.txt", in: root)

        let files = WorkspaceFiles(root: root)
        guard case .editable(_, let token) = try files.open(url)
        else { Issue.record("expected editable"); return }

        // Somebody else — an agent's `run_shell`, say — writes it meanwhile.
        try "written by someone else\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: FileAccessError.self) { try files.save("mine\n", using: token) }
        // And the other writer's work is still there, which is the point.
        #expect(try String(contentsOf: url, encoding: .utf8) == "written by someone else\n")
    }

    @Test("a save with a current token writes, and returns a token that still works")
    func savesAndRefreshes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("one\n", "doc.md", in: root)

        let files = WorkspaceFiles(root: root)
        guard case .editable(_, let token) = try files.open(url)
        else { Issue.record("expected editable"); return }

        let next = try files.save("two\n", using: token)
        #expect(try String(contentsOf: url, encoding: .utf8) == "two\n")

        // Saving twice in a row must work — otherwise every edit needs a
        // reopen, and people stop using the editor.
        _ = try files.save("three\n", using: next)
        #expect(try String(contentsOf: url, encoding: .utf8) == "three\n")
    }
}

@Suite("Workspace files — classification")
struct WorkspaceFileKindTests {

    @Test("code and prose are editable")
    func editableKinds() {
        for name in ["a.swift", "b.py", "c.json", "d.md", "e.csv", "f.yaml", "g.sql"] {
            #expect(WorkspaceFiles.kind(of: URL(filePath: "/x/\(name)")) == .editable,
                    "\(name) should be editable")
        }
    }

    // Guessing "text" for an unknown extension is the expensive way to be
    // wrong: it offers an editor for something that is not text, and the save
    // is what destroys it.
    @Test("an unknown or extensionless file is opaque, not assumed to be text")
    func unknownIsOpaque() {
        #expect(WorkspaceFiles.kind(of: URL(filePath: "/x/README")).isEditable == false)
        #expect(WorkspaceFiles.kind(of: URL(filePath: "/x/model.safetensors")).isEditable == false)
        #expect(WorkspaceFiles.kind(of: URL(filePath: "/x/thing.qqq")).isEditable == false)
    }

    // The database file is the one people will click first in a project folder,
    // and "binary" would be a dead end. It says where the right screen is.
    @Test("a database file points at the tab that can actually open it")
    func databasePointsAtItsTab() {
        guard case .opaque(let why) = WorkspaceFiles.kind(of: URL(filePath: "/x/analysis.duckdb"))
        else { Issue.record("expected opaque"); return }
        #expect(why.contains("ฐานข้อมูลภายใน"))
    }
}
