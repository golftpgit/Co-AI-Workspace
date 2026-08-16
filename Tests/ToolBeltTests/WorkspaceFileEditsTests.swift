import Testing
import Foundation
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// P8.6's outstanding item — the file viewer could read and save and nothing
// else.
//
// Anything that needed a new file needed `run_shell`, which made "add a note"
// and "run arbitrary code" the same decision for the person approving it. The
// operations are here now, and the interesting part is what they refuse.
// ─────────────────────────────────────────────────────────────

private func workspace() -> (WorkspaceFiles, URL) {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "files-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (WorkspaceFiles(root: root), root)
}

@Suite("Making and removing files (P8.6)")
struct WorkspaceFileEditsTests {

    @Test("a new file appears in the listing, empty")
    func createsFiles() throws {
        let (files, root) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try files.create(named: "บันทึก.md")
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(try files.list().map(\.name) == ["บันทึก.md"])
    }

    /// A "new file" that quietly replaced an existing one would be a deletion
    /// nobody asked for.
    @Test("creating over something that exists is refused, not silent")
    func neverOverwrites() throws {
        let (files, root) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try files.create(named: "notes.txt")
        #expect(throws: FileAccessError.alreadyExists("notes.txt")) {
            try files.create(named: "notes.txt")
        }
        // Same rule for a directory, and for renaming onto an existing name.
        try files.createDirectory(named: "data")
        #expect(throws: FileAccessError.alreadyExists("data")) {
            try files.createDirectory(named: "data")
        }
        #expect(throws: FileAccessError.alreadyExists("notes.txt")) {
            try files.rename(root.appending(path: "data"), to: "notes.txt")
        }
    }

    /// A name is a name. `../` in a filename is how a "new file" lands
    /// somewhere it was never allowed.
    @Test("a name carrying a path is refused")
    func namesAreNotPaths() throws {
        let (files, root) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        for bad in ["../escape.txt", "sub/dir.txt", "  ", ".hidden"] {
            #expect(throws: FileAccessError.self, "accepted \(bad)") {
                try files.create(named: bad)
            }
        }
        // And nothing was created on the way to those refusals.
        #expect(try files.list().isEmpty)
    }

    @Test("renaming moves the file and keeps it inside the workspace")
    func renames() throws {
        let (files, root) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try files.create(named: "draft.md")
        let renamed = try files.rename(url, to: "บทที่ 1.md")
        #expect(renamed.lastPathComponent == "บทที่ 1.md")
        #expect(try files.list().map(\.name) == ["บทที่ 1.md"])
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) == false)
    }

    @Test("a file outside the workspace cannot be renamed or removed")
    func rootIsTheBoundary() throws {
        let (files, root) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = URL(filePath: NSTemporaryDirectory()).appending(path: "outside.txt")
        try Data().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        #expect(throws: FileAccessError.self) { try files.rename(outside, to: "x.txt") }
        #expect(throws: FileAccessError.self) { try files.remove(outside) }
        // Still there: a refused delete deletes nothing.
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
    }

    /// The difference that matters: a file removed here is recoverable from
    /// the Finder, and `rm` in a shell is not.
    @Test("removing a file trashes it rather than unlinking it")
    func removesToTheTrash() throws {
        let (files, root) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try files.create(named: "ลบทิ้ง.txt")
        try files.remove(url)
        #expect(try files.list().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) == false)

        #expect(throws: FileAccessError.notFound("ลบทิ้ง.txt")) {
            try files.remove(url)
        }
    }
}

@Suite("Opening an image (P8.6)")
struct WorkspaceImageTests {

    /// It used to say "ยังไม่มีตัวแสดงรูป", which is honest and still means
    /// somebody has to leave the app to look at a scan they just collected.
    @Test("an image opens as bytes, with its name")
    func imagesOpen() throws {
        let (files, root) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        // A 1×1 PNG, as bytes — the smallest real one.
        let png = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
        try png.write(to: root.appending(path: "scan.png"))

        guard case .image(let data, let name) = try files.open(root.appending(path: "scan.png")) else {
            Issue.record("the image did not open as an image")
            return
        }
        #expect(name == "scan.png")
        #expect(data == png)
    }

    /// The same ceiling as text, for the same reason: a 40 MB scan held in
    /// memory to be looked at once is a screen that stops responding on a
    /// machine that is also running a model.
    @Test("an image over the ceiling is refused rather than loaded")
    func hugeImagesAreRefused() throws {
        let (files, root) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let big = Data(repeating: 0, count: WorkspaceFiles.editableByteLimit + 1)
        try big.write(to: root.appending(path: "huge.png"))
        #expect(throws: FileAccessError.self) {
            _ = try files.open(root.appending(path: "huge.png"))
        }
    }
}
