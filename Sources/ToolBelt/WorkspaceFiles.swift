import Foundation
import Knowledge
import Observability

// ─────────────────────────────────────────────────────────────
// File Viewer/Editor (ARCHITECTURE §14.2, P8.6) — the folder a project owns,
// readable from inside the app.
//
// **Why this exists at all.** `run_shell` writes into the project's `files/`
// and DocGen writes into its `documents/`, and until now the only way to look
// at what came out was to leave the app. A workspace that can produce a file
// it cannot show you is one where the agent's output is taken on trust, which
// is the thing this project keeps refusing to do everywhere else.
//
// **Why the logic is here and not in the view.** The app target is an
// executable with no unit tests, so a decision that lives in a SwiftUI file is
// a decision nothing checks. The rules below — what may be edited, what may be
// saved, what counts as inside the root — are exactly the rules that must not
// rot, so they live where `swift test` can reach them. The screen's only job
// is to draw what these types return.
//
// Four rules, each of which is a way to lose someone's work:
//
// 1. **A path outside the root is refused, never clamped.** Same rule the
//    plugin manifests get (P8.4): a viewer that quietly resolves `../../..`
//    to somewhere safe is a viewer that shows one file while naming another.
//    Symlinks are resolved before the check, because the escape that matters
//    is the one that does not look like `..`.
//
// 2. **Editable and viewable are different types, not a flag.** Text
//    extracted from a `.docx` is a *rendering*, not the document; writing it
//    back would replace a formatted file with a flat one. So the extracted
//    text arrives as `.readOnly` and there is no code path that saves it —
//    the guarantee is the absence of a function, not a disabled button.
//
// 3. **A file too large to load is refused with its size, not truncated.**
//    Truncating is the dangerous option: the person edits what looks like the
//    whole file, saves, and the tail is gone. Refusing costs them nothing.
//
// 4. **Saving checks the file has not changed since it was read.** The agent
//    writes into this same folder while a person has it open. Last-writer-wins
//    silently discards whichever of them was slower, and neither is told.
//    This is `WorkspaceStoreCache`'s "two writers" lesson at file granularity.
// ─────────────────────────────────────────────────────────────

/// What the app can do with a file, decided by extension.
public enum FileKind: Sendable, Equatable {
    /// Text we can show *and* write back byte for byte.
    case editable
    /// A document we can render as text but must not write back (§14.2:
    /// `.docx`/`.pptx`/`.pdf` are view-only).
    case document
    case image
    /// Anything else, with the reason to show beside it.
    case opaque(String)

    public var isEditable: Bool { self == .editable }
}

public struct FileEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int
    public let modified: Date
    public let kind: FileKind

    public var id: String { url.path(percentEncoded: false) }
}

/// A file opened for the screen. `editable` is the only case carrying a token,
/// and `save` is the only thing that accepts one — so "which files can be
/// written" is answered by the type system rather than by the caller's memory.
public enum FileContent: Sendable, Equatable {
    case editable(text: String, token: SaveToken)
    case readOnly(text: String, because: String)
    case cannotShow(String)
}

/// Proof that a specific version of a specific file was read. Has no public
/// initialiser: the only way to get one is to open a file, which is what makes
/// rule 4 above impossible to skip. Same shape as `PublishedInstrument` and
/// `BoundResult` (§20.6, P11.9).
public struct SaveToken: Sendable, Equatable {
    let url: URL
    let modified: Date
    let size: Int
}

public enum FileAccessError: Error, CustomStringConvertible, Equatable {
    case outsideRoot(String)
    case notFound(String)
    case tooLarge(name: String, bytes: Int, limit: Int)
    case notEditable(String)
    case changedOnDisk(String)
    case unreadable(String)
    /// Something is already there. Separate from every other failure because
    /// the answer is different: pick another name, and nothing has been lost.
    case alreadyExists(String)
    /// A name that is not a name — empty, hidden, or carrying a path.
    case badName(String)

    public var description: String {
        switch self {
        case .outsideRoot(let p):
            return "อยู่นอกโฟลเดอร์ของพื้นที่ทำงานนี้: \(p)"
        case .notFound(let p):
            return "ไม่พบไฟล์: \(p)"
        case .tooLarge(let name, let bytes, let limit):
            return """
            \(name) ใหญ่ \(bytes.formatted(.byteCount(style: .file))) \
            เกินเพดาน \(limit.formatted(.byteCount(style: .file))) — \
            เปิดไม่ได้ทั้งไฟล์ และจะไม่ตัดให้สั้นลง เพราะการแก้ไฟล์ที่ถูกตัดแล้วบันทึกทับ คือการลบส่วนที่หายไปจริง ๆ
            """
        case .notEditable(let name):
            return "\(name) แก้ในแอปไม่ได้ — เปิดดูได้อย่างเดียว"
        case .changedOnDisk(let name):
            return """
            \(name) ถูกแก้จากที่อื่นหลังจากเปิดไฟล์นี้ขึ้นมา — ยังไม่บันทึกทับให้ \
            เปิดใหม่เพื่อดูของล่าสุดก่อน (สั่งงานที่เขียนไฟล์ในโฟลเดอร์นี้ได้ ระหว่างที่หน้าจอเปิดค้างอยู่)
            """
        case .unreadable(let m):
            return "อ่านไม่ได้: \(m)"
        case .alreadyExists(let name):
            return "มี \(name) อยู่แล้ว — เลือกชื่ออื่น (ไม่เขียนทับให้ เพราะไฟล์ใหม่ที่ทับของเดิมคือการลบที่ไม่มีใครสั่ง)"
        case .badName(let name):
            return "ชื่อ '\(name)' ใช้ไม่ได้ — ต้องเป็นชื่อไฟล์ ไม่ใช่พาธ และห้ามขึ้นต้นด้วยจุด"
        }
    }
}

public struct WorkspaceFiles: Sendable {
    /// Text bigger than this is refused rather than shown. A source file this
    /// large is already something no editor should be asked to hold.
    public static let editableByteLimit = 2 * 1024 * 1024

    public let root: URL
    private let reader: DocumentReader
    private let log = AppLog.logger("files")

    public init(root: URL, reader: DocumentReader = DocumentReader()) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.reader = reader
    }

    // MARK: - Making, renaming, removing (§14.2, P8.6)
    //
    // The viewer could read and save and nothing else, so anything that needed
    // a new file needed `run_shell` — which is a high-risk tool asked to do a
    // thing a person should just be able to do, and it made "add a note" and
    // "run arbitrary code" the same decision.
    //
    // Every one of these goes through `resolve`, so the root is the boundary
    // for creating and deleting exactly as it is for reading. A name is a name
    // and not a path: `../` in a filename is how a "new file" lands somewhere
    // it was never allowed.

    /// Creates an empty file. Refuses to overwrite: a "new file" that quietly
    /// replaced an existing one would be a deletion nobody asked for.
    @discardableResult
    public func create(named name: String, in directory: URL? = nil) throws -> URL {
        let target = try resolve(directory ?? root)
        let url = try child(named: name, of: target)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw FileAccessError.alreadyExists(url.lastPathComponent)
        }
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Creates a directory, and says so when it is already there rather than
    /// reporting a success that did nothing.
    @discardableResult
    public func createDirectory(named name: String, in directory: URL? = nil) throws -> URL {
        let target = try resolve(directory ?? root)
        let url = try child(named: name, of: target)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw FileAccessError.alreadyExists(url.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    public func rename(_ url: URL, to name: String) throws -> URL {
        let source = try resolve(url)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw FileAccessError.notFound(source.lastPathComponent)
        }
        let destination = try child(named: name, of: source.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw FileAccessError.alreadyExists(destination.lastPathComponent)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// Moves to the trash rather than unlinking.
    ///
    /// The difference is the whole point: a file removed from this screen is
    /// recoverable from the Finder, and a `run_shell` `rm` is not. Deleting is
    /// the one operation here that cannot be undone by retyping.
    public func remove(_ url: URL) throws {
        let target = try resolve(url)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw FileAccessError.notFound(target.lastPathComponent)
        }
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }

    /// A name, resolved against a directory — and checked twice.
    ///
    /// `lastPathComponent` strips any path a name was carrying, and `resolve`
    /// then holds the result to the root anyway. Two checks because the first
    /// is about what somebody typed and the second is about where it landed,
    /// and a symlink makes those different questions.
    private func child(named name: String, of directory: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(".") else {
            throw FileAccessError.badName(name)
        }
        let leaf = URL(filePath: trimmed).lastPathComponent
        guard leaf == trimmed else { throw FileAccessError.badName(name) }
        return try resolve(directory.appending(path: leaf))
    }

    // MARK: - Listing

    /// Directories first, then files, each group by name — the order a person
    /// scans. `directory` must already be inside the root.
    public func list(_ directory: URL? = nil) throws -> [FileEntry] {
        let target = try resolve(directory ?? root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: target, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])
        } catch {
            throw FileAccessError.unreadable("\(error.localizedDescription)")
        }

        let entries = contents.map(entry(for:))
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func entry(for url: URL) -> FileEntry {
        // `URL` caches resource values it has already fetched, so asking the
        // same instance twice can answer with what was true before a write.
        // That is not a detail: it made the token handed back by `save` carry
        // the *pre-write* timestamp, so the second save in a row always looked
        // like somebody else had edited the file. Ask the filesystem each time.
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                       .contentModificationDateKey])
        let isDirectory = values?.isDirectory ?? false
        return FileEntry(url: url,
                         name: url.lastPathComponent,
                         isDirectory: isDirectory,
                         size: values?.fileSize ?? 0,
                         modified: values?.contentModificationDate ?? .distantPast,
                         kind: isDirectory ? .opaque("โฟลเดอร์") : Self.kind(of: url))
    }

    // MARK: - Opening

    public func open(_ url: URL) throws -> FileContent {
        let target = try resolve(url)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw FileAccessError.notFound(target.lastPathComponent)
        }
        let info = entry(for: target)

        switch info.kind {
        case .editable:
            guard info.size <= Self.editableByteLimit else {
                throw FileAccessError.tooLarge(name: info.name, bytes: info.size,
                                               limit: Self.editableByteLimit)
            }
            guard let text = try? String(contentsOf: target, encoding: .utf8) else {
                // Not UTF-8. Saying "binary" would be a guess; saying which
                // assumption failed is what lets someone fix it.
                return .cannotShow("ไฟล์นี้ไม่ได้เข้ารหัสเป็น UTF-8 — แอปเปิดเป็นข้อความไม่ได้")
            }
            return .editable(text: text,
                             token: SaveToken(url: target, modified: info.modified,
                                              size: info.size))

        case .document:
            do {
                let document = try reader.read(target)
                return .readOnly(text: document.text,
                                 because: "แสดงเป็นข้อความที่สกัดจากเอกสาร — แก้ในแอปไม่ได้ "
                                        + "เพราะการเขียนกลับจะทำให้รูปแบบของเอกสารหายไป")
            } catch {
                return .cannotShow("อ่านเอกสารไม่ได้: \(error)")
            }

        case .image:
            return .cannotShow("ไฟล์รูป — ยังไม่มีตัวแสดงรูปในหน้านี้")

        case .opaque(let why):
            return .cannotShow(why)
        }
    }

    // MARK: - Saving

    /// Writes `text` back. The token is what proves the caller read this exact
    /// version; if the file moved on since, nothing is written.
    @discardableResult
    public func save(_ text: String, using token: SaveToken) throws -> SaveToken {
        let target = try resolve(token.url)
        let now = entry(for: target)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw FileAccessError.notFound(now.name)
        }
        guard now.modified == token.modified, now.size == token.size else {
            throw FileAccessError.changedOnDisk(now.name)
        }
        guard now.kind.isEditable else { throw FileAccessError.notEditable(now.name) }

        do {
            // Atomic: a half-written file is worse than an unsaved one.
            try text.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            throw FileAccessError.unreadable("บันทึกไม่สำเร็จ: \(error.localizedDescription)")
        }
        let saved = entry(for: target)
        return SaveToken(url: target, modified: saved.modified, size: saved.size)
    }

    // MARK: - Rules

    /// Resolves symlinks first, then requires the result to sit under the root.
    /// Both halves matter: `..` is the obvious escape and a symlink is the one
    /// that does not look like an escape at all.
    func resolve(_ url: URL) throws -> URL {
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path(percentEncoded: false)
        let path = candidate.path(percentEncoded: false)
        guard path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        else {
            throw FileAccessError.outsideRoot(path)
        }
        return candidate
    }

    /// Extension decides. Content sniffing would be cleverer and would also
    /// mean the answer changes as a file is edited, which is not a property a
    /// person can predict.
    static func kind(of url: URL) -> FileKind {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown", "rst", "csv", "tsv", "json", "yaml", "yml",
             "toml", "ini", "conf", "cfg", "log", "plist", "xml", "html", "css",
             "swift", "py", "js", "mjs", "ts", "tsx", "jsx", "sh", "bash", "zsh",
             "c", "h", "cpp", "hpp", "cc", "m", "mm", "rb", "go", "rs", "java",
             "kt", "sql", "r", "jl", "lua", "pl", "php", "gradle", "cmake":
            return .editable
        case "pdf", "docx", "pptx":
            return .document
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp":
            return .image
        case "duckdb", "sqlite", "db", "wal", "shm":
            return .opaque("ไฟล์ฐานข้อมูล — เปิดที่แท็บฐานข้อมูลภายใน")
        case "safetensors", "gguf", "bin", "mlmodelc", "metallib":
            return .opaque("ไฟล์น้ำหนักโมเดล/ไบนารี")
        case "zip", "gz", "tar", "dmg":
            return .opaque("ไฟล์บีบอัด")
        case "":
            // Extensionless files are usually text (README, Makefile, LICENSE)
            // but guessing wrong in the editable direction is the expensive
            // way to be wrong, so they open read-only-by-absence-of-a-token.
            return .opaque("ไม่มีนามสกุลไฟล์ — แอปเดาไม่ได้ว่าเป็นข้อความหรือไบนารี")
        default:
            return .opaque("แอปยังไม่รู้จักนามสกุล .\(url.pathExtension)")
        }
    }
}
