import Testing
import Foundation
import CryptoKit
import AgentKit
import Observability
@testable import Linkage

// ─────────────────────────────────────────────────────────────
// Linkage (ARCHITECTURE §20.7, P11.7b).
//
// The claims being tested are the ones a participant is entitled to:
//
//  • their name is not in the file that holds their answers;
//  • their name is not readable in the file that holds the codes either;
//  • nobody can turn a code back into them without it being written down.
//
// The first two are checked by reading the raw bytes of the database file and
// searching them, because "we encrypt it" is a claim about code and "the string
// is not in the file" is a fact about the disk.
// ─────────────────────────────────────────────────────────────

private func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "link-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Every byte of a SQLite database, including its write-ahead log — a value that
/// has been written but not checkpointed is still a value on disk.
private func bytesOnDisk(_ path: URL) throws -> Data {
    var data = Data()
    for suffix in ["", "-wal", "-shm"] {
        let file = URL(fileURLWithPath: path.path(percentEncoded: false) + suffix)
        if let part = try? Data(contentsOf: file) { data.append(part) }
    }
    return data
}

@Suite("Linkage")
struct LinkageStoreTests {

    @Test("a participant's name is not in the file, in any form a search would find")
    func identitiesAreSealed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "linkage.sqlite")

        let store = try await LinkageStore(path: path, project: "pj_1",
                                           keys: InMemoryLinkageKeys())
        let participant = try await store.enrol(identity: "somchai.jaidee@hospital.example")

        let bytes = try bytesOnDisk(path)
        // The exact claim §20.7 makes about this file.
        #expect(bytes.range(of: Data("somchai.jaidee@hospital.example".utf8)) == nil)
        #expect(bytes.range(of: Data("somchai".utf8)) == nil)
        // The code, by contrast, is meant to be there — it is what a wave is
        // organised around.
        #expect(bytes.range(of: Data(participant.code.utf8)) != nil)
    }

    @Test("the key is not in the file either")
    func keysAreNotStoredBesideTheData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "linkage.sqlite")

        let key = SymmetricKey(size: .bits256)
        let store = try await LinkageStore(path: path, project: "pj_1",
                                           keys: InMemoryLinkageKeys(key: key))
        try await store.enrol(identity: "ผู้เข้าร่วมคนที่หนึ่ง")

        // A file that contains both the ciphertext and the key is a file that
        // contains the plaintext.
        let raw = key.withUnsafeBytes { Data($0) }
        let bytes = try bytesOnDisk(path)
        #expect(bytes.range(of: raw) == nil)
        #expect(bytes.range(of: Data(raw.base64EncodedString().utf8)) == nil)
    }

    @Test("a code becomes a person only through an API that writes it down")
    func everyResolutionIsAudited() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spans = InMemorySpanSink()
        let store = try await LinkageStore(path: directory.appending(path: "linkage.sqlite"),
                                           project: "pj_1", keys: InMemoryLinkageKeys(),
                                           spans: spans)
        let participant = try await store.enrol(identity: "somchai@example.org")

        let name = try await store.resolve(code: participant.code,
                                           reason: "ผู้เข้าร่วมขอถอนข้อมูล", by: "ผู้วิจัย")
        #expect(name == "somchai@example.org")

        let audited = await spans.spans(named: "linkage.resolve")
        #expect(audited.count == 1)
        #expect(audited.first?.detail?.contains("ผู้วิจัย") == true)
        #expect(audited.first?.detail?.contains("ผู้เข้าร่วมขอถอนข้อมูล") == true)

        // A lookup that found nothing is still a lookup. "Who looked" is the
        // question an audit answers, not "who looked successfully".
        _ = try await store.resolve(code: "P-NOTREAL", reason: "พิมพ์ผิด", by: "ผู้วิจัย")
        #expect(await spans.spans(named: "linkage.resolve").count == 2)
    }

    @Test("another project's key cannot read this project's identities")
    func keysDoNotCrossProjects() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "linkage.sqlite")

        let first = try await LinkageStore(path: path, project: "pj_1",
                                           keys: InMemoryLinkageKeys())
        let participant = try await first.enrol(identity: "somchai@example.org")

        // The same file, opened with a different key — which is what a copied
        // linkage file on somebody else's machine amounts to.
        let second = try await LinkageStore(path: path, project: "pj_1",
                                            keys: InMemoryLinkageKeys())
        await #expect(throws: LinkageError.self) {
            _ = try await second.resolve(code: participant.code, reason: "x", by: "y")
        }
    }

    @Test("an identity nobody gave is refused")
    func emptyIdentitiesAreRefused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await LinkageStore(path: directory.appending(path: "linkage.sqlite"),
                                           project: "pj_1", keys: InMemoryLinkageKeys())
        await #expect(throws: LinkageError.emptyIdentity) {
            _ = try await store.enrol(identity: "   ")
        }
    }

    @Test("attrition is the difference between who was asked and who answered")
    func attritionIsMeasured() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await LinkageStore(path: directory.appending(path: "linkage.sqlite"),
                                           project: "pj_1", keys: InMemoryLinkageKeys())

        var codes: [String] = []
        for index in 1...10 {
            codes.append(try await store.enrol(identity: "person-\(index)@example.org").code)
        }

        try await store.invite(codes, to: "wave_1")
        for code in codes.prefix(9) {
            try await store.recordResponse(code: code, wave: "wave_1")
        }
        try await store.invite(codes, to: "wave_2")
        for code in codes.prefix(6) {
            try await store.recordResponse(code: code, wave: "wave_2")
        }

        let attrition = try await store.attrition()
        #expect(attrition.count == 2)
        #expect(attrition[0].invited == 10)
        #expect(attrition[0].responded == 9)
        // The number a longitudinal study reports, and the one that decides
        // whether its later waves mean anything.
        #expect(abs(attrition[1].rate - 0.6) < 0.0001)
    }

    @Test("the same person in two waves is the same code")
    func codesFollowAPersonAcrossWaves() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await LinkageStore(path: directory.appending(path: "linkage.sqlite"),
                                           project: "pj_1", keys: InMemoryLinkageKeys())
        let participant = try await store.enrol(identity: "somchai@example.org")
        try await store.invite([participant.code], to: "wave_1")
        try await store.invite([participant.code], to: "wave_2")

        // Which is the whole reason the code exists: without it, "did the people
        // who were burning out in March improve by June" cannot be asked without
        // putting names beside answers.
        let rows = try await store.attrition()
        #expect(rows.map(\.waveID) == ["wave_1", "wave_2"])
        #expect(try await store.participants().count == 1)
    }

    @Test("a code is readable aloud: no vowels, no look-alike characters")
    func codesSurviveBeingReadOverThePhone() {
        // Fieldwork means somebody reads this to somebody else. A code that can
        // spell a word, or that contains both O and 0, is a code that arrives
        // wrong and quietly joins the wrong person's answers.
        let forbidden = Set("AEIOU01")
        for _ in 0..<200 {
            let code = LinkageStore.freshCode()
            #expect(code.hasPrefix("P-"))
            #expect(!code.dropFirst(2).contains { forbidden.contains($0) })
        }
    }
}
