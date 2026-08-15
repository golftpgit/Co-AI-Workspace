import Testing
import Foundation
@testable import AgentKit

// ─────────────────────────────────────────────────────────────
// P9.4 — the half of "a corrupt file is handled" that was missing.
//
// P9.2 made the handling correct: the file is copied aside before anything can
// overwrite it, and the app carries on with an empty list. What it did not do
// was tell anybody. The report went to the unified log, which nobody has open,
// so the lived experience was a list that was empty one morning for no reason.
// ─────────────────────────────────────────────────────────────

private func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "incident-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("Unreadable files are reported, not only survived", .serialized)
struct FileStoreIncidentTests {

    @Test("a corrupt list file leaves a report naming the backup")
    func reportsWithBackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let incidents = FileStoreIncidents.shared
        incidents.clear()
        defer { incidents.clear() }

        let file = directory.appending(path: "channels.json")
        try "{ this is not json".write(to: file, atomically: true, encoding: .utf8)

        let failure = FileStoreSafety.reportUnreadable(file, describedAs: "รายชื่อบอท")

        // The copy still happens — that is P9.2's promise and it is unchanged.
        #expect(FileManager.default.fileExists(
            atPath: FileStoreSafety.backupLocation(for: file).path(percentEncoded: false)))
        // And now there is something to show a person.
        #expect(incidents.all.count == 1)
        #expect(failure.whatToDo.contains("channels.unreadable.backup.json"))
        #expect(failure.whatToDo.contains("ยังไม่มีอะไรหาย"))
    }

    // A store read on every screen change would otherwise stack up the same
    // sentence until the status screen is nothing else.
    @Test("the same file reported twice appears once")
    func deduplicates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let incidents = FileStoreIncidents.shared
        incidents.clear()
        defer { incidents.clear() }

        let file = directory.appending(path: "connectors.json")
        try "nope".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<5 { FileStoreSafety.reportUnreadable(file, describedAs: "แหล่งข้อมูล") }

        #expect(incidents.all.count == 1)
    }

    // The case where there is no backup — the file vanished between the failed
    // read and the copy — must not claim one.
    @Test("with no backup taken, the advice does not promise a copy that is not there")
    func honestWhenNoBackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let incidents = FileStoreIncidents.shared
        incidents.clear()
        defer { incidents.clear() }

        let missing = directory.appending(path: "gone.json")
        let failure = FileStoreSafety.reportUnreadable(missing, describedAs: "เทมเพลต")

        #expect(failure.whatToDo.contains("สำรอง") == false)
        #expect(failure.whatToDo.contains("อย่าเพิ่งบันทึกทับ"))
    }
}
