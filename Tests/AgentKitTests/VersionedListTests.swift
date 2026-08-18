import Testing
import Foundation
@testable import AgentKit

// ─────────────────────────────────────────────────────────────
// P9.2's remaining half — the four list files had no schema version.
//
// They were made safe (a file that will not decode is copied aside rather than
// overwritten), which stops data being lost today and does nothing about the
// release that adds a field. These are P9.2's own rules, applied to lists:
// no version is version 0, a newer file is never written over, and nothing is
// overwritten without a copy.
// ─────────────────────────────────────────────────────────────

private struct Bot: Codable, Equatable {
    var name: String
    var enabled: Bool
}

private let bots = [Bot(name: "กลุ่มวิจัย", enabled: true),
                    Bot(name: "วอร์ด 5", enabled: false)]

@Suite("Versioned list files (P9.2)")
struct VersionedListTests {

    /// Every file written before this existed is a bare array, and they are
    /// the majority. Reading one as "broken" would empty somebody's bot list
    /// on the morning they upgraded.
    @Test("a bare array is version 0, not a broken file")
    func bareArrayIsVersionZero() throws {
        let legacy = try JSONEncoder().encode(bots)
        guard case .list(let items, let version) = VersionedList.decode(legacy, as: Bot.self) else {
            Issue.record("a legacy list did not read")
            return
        }
        #expect(items == bots)
        #expect(version == 0)
    }

    @Test("what this build writes, this build reads")
    func roundTrip() throws {
        let data = try VersionedList.encode(bots)
        guard case .list(let items, let version) = VersionedList.decode(data, as: Bot.self) else {
            Issue.record("the envelope did not read back")
            return
        }
        #expect(items == bots)
        #expect(version == VersionedList.currentVersion)
        // The version is in the file, in a form somebody reading it can see.
        #expect(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\" : 1"))
    }

    /// Running on defaults for one session is recoverable. Overwriting is not,
    /// and the build they would go back to is the one that lost the settings.
    @Test("a file from a newer build is reported, not read and not written")
    func newerFilesAreLeftAlone() throws {
        let future = Data("""
        {"schemaVersion": 99, "items": [{"name": "x", "enabled": true}]}
        """.utf8)
        guard case .fromNewerBuild(let version) = VersionedList.decode(future, as: Bot.self) else {
            Issue.record("a newer file was read as though this build understood it")
            return
        }
        #expect(version == 99)

        let file = URL(filePath: NSTemporaryDirectory())
            .appending(path: "list-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try future.write(to: file)
        #expect(VersionedList.mayOverwrite(file, of: Bot.self) == false)
    }

    @Test("an ordinary file may be written over, and a missing one too")
    func ordinaryFilesAreWritable() throws {
        let file = URL(filePath: NSTemporaryDirectory())
            .appending(path: "list-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // Nothing there yet: the first save must not be refused.
        #expect(VersionedList.mayOverwrite(file, of: Bot.self))
        try VersionedList.encode(bots).write(to: file)
        #expect(VersionedList.mayOverwrite(file, of: Bot.self))
        // A legacy array is writable too — that is what upgrading it means.
        try JSONEncoder().encode(bots).write(to: file)
        #expect(VersionedList.mayOverwrite(file, of: Bot.self))
    }

    @Test("neither shape decoding is unreadable, which is a different answer")
    func rubbishIsUnreadable() {
        guard case .unreadable = VersionedList.decode(Data("ไม่ใช่ JSON".utf8), as: Bot.self) else {
            Issue.record("rubbish decoded as something")
            return
        }
        // And it is distinct from "from a newer build": one gets copied aside
        // and replaced, the other must not be touched at all.
        guard case .unreadable = VersionedList.decode(Data("{}".utf8), as: Bot.self) else {
            Issue.record("an object with no items decoded as a list")
            return
        }
    }
}

// ─────────────────────────────────────────────────────────────
// The four stores, through the door they all use now.
// ─────────────────────────────────────────────────────────────
@Suite("The four list files, versioned (P9.2)")
struct ListStoreVersionTests {

    /// The upgrade path: a bare array on disk, read, then written back as an
    /// envelope. Nobody loses a bot list on the morning they update.
    @Test("a legacy file is read, then written back with a version")
    func legacyUpgradesInPlace() throws {
        let file = URL(filePath: NSTemporaryDirectory())
            .appending(path: "legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        try JSONEncoder().encode(bots).write(to: file)
        guard case .list(let read, let version) =
                VersionedList.decode(try Data(contentsOf: file), as: Bot.self) else {
            Issue.record("the legacy file did not read")
            return
        }
        #expect(version == 0)

        try VersionedList.encode(read).write(to: file)
        guard case .list(let again, let newVersion) =
                VersionedList.decode(try Data(contentsOf: file), as: Bot.self) else {
            Issue.record("the upgraded file did not read")
            return
        }
        #expect(again == bots)
        #expect(newVersion == VersionedList.currentVersion)
    }

    /// The refusal, said in words a person can act on — and distinct from
    /// "unreadable", which means the opposite thing about their data.
    @Test("refusing to overwrite says the file is fine and this app is behind")
    func refusalExplainsItself() {
        let refusal = FileStoreError.fileFromNewerBuild
        #expect(refusal.description.contains("a newer version of the app"))
        #expect(refusal.description.contains("has not been written over"))

        let incident = ReadableFailure.newerSchema(doing: "ช่องทาง", version: 4)
        #expect(incident.whatToDo.contains("has not been written over"))
        // Not the same advice as a corrupt file, which says a copy was kept
        // and the list was replaced.
        #expect(incident.whatToDo.contains("สำรอง") == false)
    }
}
