import Testing
import Foundation
@testable import OLTP

// ─────────────────────────────────────────────────────────────
// The answer store (ARCHITECTURE §19.17, P11.6b/P11.6c).
//
// The claim being tested is not "rows can be inserted". It is the one the whole
// third database exists for: **twenty people answering at the same time do not
// lose an answer between them**, and the app can read while they are still
// writing. That is the scenario DuckDB would have failed on the day it mattered,
// and it is not visible in a test that writes one row at a time.
// ─────────────────────────────────────────────────────────────

private func temporaryStore() async throws -> (ResponseStore, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "oltp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appending(path: "responses.sqlite")
    return (try await ResponseStore(path: path), directory)
}

private func submission(_ index: Int, instrument: String = "in_1", version: Int = 1,
                        dropped: [String] = []) -> Submission {
    Submission(id: "sub_\(index)", instrumentID: instrument, version: version,
               waveID: "wave_1", consentDigest: "digest-v1",
               answers: [StoredAnswer(itemID: "it_a", text: "\(index % 5 + 1)",
                                      number: Double(index % 5 + 1)),
                         StoredAnswer(itemID: "it_b", text: "คำตอบ \(index)")],
               droppedFields: dropped)
}

@Suite("Response store")
struct ResponseStoreTests {

    @Test("twenty people answering at once lose nothing, and the app can read mid-flight")
    func concurrentSubmissionsAreAllKept() async throws {
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The real shape of fieldwork: everybody presses submit at the end of the
        // session, not politely in turn.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { try? await store.append(submission(index)) }
            }
            // …and the app is looking at the responses screen while they do.
            group.addTask { _ = try? await store.submissionCount(instrument: "in_1", version: 1) }
        }

        #expect(try await store.submissionCount(instrument: "in_1", version: 1) == 20)
        #expect(try await store.answers(instrument: "in_1", version: 1).count == 40)
    }

    @Test("a submission is whole or absent, never half")
    func submissionsAreAtomic() async throws {
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.append(submission(1))
        // The same id twice: the second insert fails on the primary key, and its
        // answers must not survive it. A half-written answer set is worse than a
        // rejected one, because it looks like data.
        await #expect(throws: (any Error).self) {
            try await store.append(
                Submission(id: "sub_1", instrumentID: "in_1", version: 1, waveID: "wave_1",
                           consentDigest: "digest-v1",
                           answers: [StoredAnswer(itemID: "it_c", text: "ไม่ควรอยู่")]))
        }
        let answers = try await store.answers(instrument: "in_1", version: 1)
        #expect(answers.count == 2)
        #expect(!answers.contains { $0.itemID == "it_c" })
    }

    @Test("changing an answer keeps the old one beside it, never over it")
    func correctionsAreRecordsNotEdits() async throws {
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.append(submission(1))
        try await store.correct(Correction(submissionID: "sub_1", itemID: "it_a",
                                           previousText: "2", newText: "4",
                                           reason: "ผู้ตอบแจ้งกลับว่ากดผิด",
                                           correctedBy: "ผู้วิจัย"))

        let answers = try await store.answers(instrument: "in_1", version: 1)
        let corrected = try #require(answers.first { $0.itemID == "it_a" })
        // Read back as the new value, with the old one still attached — which is
        // what lets the screen show a mark rather than a silently different
        // number.
        #expect(corrected.text == "4")
        #expect(corrected.wasCorrected)
        #expect(corrected.corrected?.previousText == "2")
        #expect(corrected.corrected?.reason == "ผู้ตอบแจ้งกลับว่ากดผิด")

        // And the original row is still the original row.
        let raw = try await store.rawAnswerText(submission: "sub_1", item: "it_a")
        #expect(raw == "2")
    }

    @Test("a correction with no reason or nobody's name is refused")
    func correctionsNeedAReasonAndAPerson() async throws {
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.append(submission(1))

        await #expect(throws: ResponseStoreError.correctionNeedsReasonAndPerson) {
            try await store.correct(Correction(submissionID: "sub_1", itemID: "it_a",
                                               previousText: "2", newText: "4",
                                               reason: "   ", correctedBy: "ผู้วิจัย"))
        }
        await #expect(throws: ResponseStoreError.correctionNeedsReasonAndPerson) {
            try await store.correct(Correction(submissionID: "sub_1", itemID: "it_a",
                                               previousText: "2", newText: "4",
                                               reason: "กดผิด", correctedBy: ""))
        }
    }

    @Test("a field the instrument does not define is written down, not stored as data")
    func foreignFieldsAreRecordedNotKept() async throws {
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.append(submission(1, dropped: ["admin", "it_does_not_exist"]))
        #expect(try await store.droppedFieldCount() == 2)
        // Two answers, not four: the extra names are evidence, not columns.
        #expect(try await store.answers(instrument: "in_1", version: 1).count == 2)
    }

    @Test("versions are separate populations")
    func versionsDoNotMix() async throws {
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.append(submission(1, version: 1))
        try await store.append(submission(2, version: 2))
        // Answers collected with two different forms are two datasets. Counting
        // them together is the mistake versioning exists to prevent.
        #expect(try await store.submissionCount(instrument: "in_1", version: 1) == 1)
        #expect(try await store.submissionCount(instrument: "in_1", version: 2) == 1)
    }

    @Test("the store survives being closed and opened again")
    func rowsOutliveTheProcess() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "oltp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "responses.sqlite")

        do {
            let store = try await ResponseStore(path: path)
            try await store.append(submission(1))
        }
        let reopened = try await ResponseStore(path: path)
        #expect(try await reopened.submissionCount(instrument: "in_1", version: 1) == 1)
    }
}

// ─────────────────────────────────────────────────────────────
// The one fact the closing gate asks this store (§20.5, P11.10).
//
// `hasAnySubmission` decides whether §19.12's condition 8 applies to a project
// at all: a study that collected answers has to name a real retention policy
// before it can close, and a software project has nothing to promise anybody.
// Getting it wrong in either direction is bad in a different way — a false
// `true` makes every project invent a promise (R10's ceremony), a false
// `false` waves a study past the one condition that exists to protect the
// people in it.
//
// It had no test until a real response was driven through the field server and
// somebody went looking for what read it.
// ─────────────────────────────────────────────────────────────

@Suite("Whether anybody answered at all")
struct HasAnySubmissionTests {

    @Test("a store nobody has answered says so")
    func emptyIsFalse() async throws {
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await store.hasAnySubmission() == false)
    }

    @Test("one answer is enough — the question is whether the promise applies, not how many")
    func oneIsEnough() async throws {
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.append(submission(1))
        #expect(try await store.hasAnySubmission())
    }

    // The gate asks across the whole project, not per instrument: a study that
    // collected under one instrument and then retired it still collected.
    @Test("it counts across every instrument and every wave")
    func spansInstrumentsAndWaves() async throws {
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.append(submission(1, instrument: "in_retired", version: 1))
        try await store.append(submission(2, instrument: "in_current", version: 3))
        #expect(try await store.hasAnySubmission())
    }

    // Reopening is what actually happens: the closing gate runs months after
    // the answers came in, in a different process.
    @Test("it is still true after the store is closed and opened again")
    func survivesReopening() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "oltp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "responses.sqlite")

        let first = try await ResponseStore(path: path)
        try await first.append(submission(1))

        let reopened = try await ResponseStore(path: path)
        #expect(try await reopened.hasAnySubmission())
    }
}
