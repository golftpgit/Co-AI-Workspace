import Testing
import Foundation
@testable import AgentKit

// ─────────────────────────────────────────────────────────────
// Not losing a list file we could not read (P9.2).
//
// The bug this closes is not the decode failure — it is what the app does
// afterwards. Four stores return an empty list so the app keeps working, the
// screen shows nothing, the person adds one entry, and the save writes that one
// entry over a file that had five in it.
// ─────────────────────────────────────────────────────────────

private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "coai-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("File store safety")
struct FileStoreSafetyTests {

    @Test("an unreadable list file is copied aside before anything overwrites it")
    func unreadableFileIsPreserved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "channels.json")
        try "[{ this was five accounts }]".write(to: file, atomically: true, encoding: .utf8)

        let backup = try #require(FileStoreSafety.preserveUnreadable(file))
        #expect(backup.lastPathComponent == "channels.unreadable.backup.json")
        #expect(try String(contentsOf: backup, encoding: .utf8)
            == "[{ this was five accounts }]")

        // The original is untouched by the copy itself.
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    /// The rule that makes the backup worth having. By the second failed load
    /// the live file may already be the one-entry version somebody just saved,
    /// so the copy worth keeping is the oldest — not the newest.
    @Test("a second failure does not overwrite the first backup")
    func theOldestCopyIsKept() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "mcp-servers.json")

        try "the original five".write(to: file, atomically: true, encoding: .utf8)
        _ = FileStoreSafety.preserveUnreadable(file)

        try "just the one somebody re-added".write(to: file, atomically: true, encoding: .utf8)
        _ = FileStoreSafety.preserveUnreadable(file)

        #expect(try String(contentsOf: FileStoreSafety.backupLocation(for: file), encoding: .utf8)
                == "the original five")
    }

    @Test("nothing to preserve when there is no file")
    func missingFileIsNotAnError() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FileStoreSafety.preserveUnreadable(directory.appending(path: "nope.json")) == nil)
    }

    @Test("the backup keeps the original extension, so it is obvious what it is")
    func backupNaming() {
        let backup = FileStoreSafety.backupLocation(for: URL(fileURLWithPath: "/tmp/templates.json"))
        #expect(backup.path == "/tmp/templates.unreadable.backup.json")
    }
}
