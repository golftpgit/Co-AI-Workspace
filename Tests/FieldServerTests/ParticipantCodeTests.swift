import Testing
import Foundation
import AgentKit
import Instruments
import OLTP
@testable import FieldServer

// ─────────────────────────────────────────────────────────────
// The code that follows a person between waves (ARCHITECTURE §20.7, P11.7b).
//
// A code kept in a linkage file and never carried by a form links nothing. This
// is the other half: the link a participant is sent carries `?code=`, the page
// keeps it, and the submission is stored against it.
//
// What the server must *not* be able to do is equally the point. It stores an
// opaque string. It cannot turn one into a person — `Linkage` is not in its
// module graph, and `check.sh` fails the build if that ever changes.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_codes")

private func approvedInstrument() throws -> PublishedInstrument {
    let question = ResearchQuestion(text: Bilingual("ความเครียดเป็นอย่างไร"))
    let construct = Construct(name: Bilingual("ความเครียด"), definition: "ความกดดัน",
                              researchQuestionID: question.id)
    let instrument = Instrument(
        projectID: project, title: Bilingual("แบบสอบถามติดตามผล"),
        researchQuestions: [question], constructs: [construct],
        items: [Item(prompt: Bilingual("ฉันเครียด"),
                     kind: .likert(levels: (1...5).map { Bilingual("ระดับ \($0)") }),
                     constructID: construct.id, order: 1)],
        consent: ConsentText(purpose: Bilingual("ศึกษา"),
                             whatIsCollected: Bilingual("คะแนน"),
                             voluntary: Bilingual("สมัครใจ"), contact: "r@example.ac.th"),
        ethics: .approved(committee: "กรรมการ", number: "COA-4", date: Date(),
                          declaredBy: "ผู้วิจัย"))
    let reviewed = instrument.itemsUnderContentReview
    let ratings = reviewed.flatMap { item in
        ["ก", "ข", "ค"].map {
            ExpertRating(itemID: item.id, expert: $0, congruence: 1, relevance: 4)
        }
    }
    return try InstrumentGate.approve(
        instrument,
        validity: ContentValidity.assess(ratings: ratings, itemIDs: reviewed.map(\.id)),
        by: "ผู้วิจัย")
}

private func store() async throws -> (ResponseStore, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "code-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try await ResponseStore(path: directory.appending(path: "responses.sqlite")),
            directory)
}

@Suite("Participant codes")
struct ParticipantCodeTests {

    @Test("the link a participant is sent puts their code on the form")
    func codeTravelsFromTheURLIntoThePage() async throws {
        let published = try approvedInstrument()
        let (responses, directory) = try await store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: responses)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        let page = await host.handle(
            HTTPRequest(method: "GET", path: "/", query: ["code": "P-BCDF2345"]),
            from: "192.168.1.5")
        let html = String(decoding: page.body, as: UTF8.self)
        #expect(html.contains("name=\"__code\" value=\"P-BCDF2345\""))

        // And a link with no code is still a working form: not every study is
        // longitudinal, and an anonymous one must not be broken by this.
        let plain = await host.handle(HTTPRequest(method: "GET", path: "/"), from: "192.168.1.5")
        #expect(plain.status == 200)
        #expect(String(decoding: plain.body, as: UTF8.self).contains("name=\"__code\" value=\"\""))
    }

    @Test("the code is stored beside the answers, and is only ever a code")
    func codeIsStoredWithTheSubmission() async throws {
        let published = try approvedInstrument()
        let (responses, directory) = try await store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: responses)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        let item = published.instrument.ordered[0].id
        let body = "__consent=yes&__instrument=\(published.instrument.id)&__version=1"
            + "&__code=P-BCDF2345&\(item)=4"
        let sent = await host.handle(
            HTTPRequest(method: "POST", path: "/submit",
                        headers: ["content-type": "application/x-www-form-urlencoded"],
                        body: Data(body.utf8)),
            from: "192.168.1.5")
        #expect(sent.status == 200)

        let submissions = try await responses.submissions(instrument: published.instrument.id,
                                                          version: 1)
        #expect(submissions.first?.participantCode == "P-BCDF2345")
        // One answer, not two: `__code` is the runtime's own field and must not
        // become a column of data.
        #expect(try await responses.answers(instrument: published.instrument.id,
                                            version: 1).count == 1)
        #expect(try await responses.droppedFieldCount() == 0)
    }

    @Test("an anonymous submission stores no code rather than an empty one")
    func missingCodesAreNil() async throws {
        let published = try approvedInstrument()
        let (responses, directory) = try await store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: responses)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        let item = published.instrument.ordered[0].id
        let body = "__consent=yes&__instrument=\(published.instrument.id)&__version=1"
            + "&__code=&\(item)=4"
        _ = await host.handle(
            HTTPRequest(method: "POST", path: "/submit",
                        headers: ["content-type": "application/x-www-form-urlencoded"],
                        body: Data(body.utf8)),
            from: "192.168.1.5")

        // "" and nil are different answers to "which participant is this", and
        // an empty string would join every anonymous response to one imaginary
        // person.
        let submissions = try await responses.submissions(instrument: published.instrument.id,
                                                          version: 1)
        #expect(submissions.first?.participantCode == nil)
    }

    @Test("a database made before codes existed gains the column rather than breaking")
    func olderDatabasesMigrate() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "code-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "responses.sqlite")

        // A file in the shape this store shipped with first: `CREATE TABLE IF
        // NOT EXISTS` would leave it alone, and the missing column would only
        // show up months later as a wave that cannot be linked.
        let raw = try SQLiteDatabase(path: path)
        try await raw.execute("""
            CREATE TABLE submission (
                id TEXT PRIMARY KEY, instrument_id TEXT NOT NULL, version INTEGER NOT NULL,
                wave_id TEXT NOT NULL, consent_digest TEXT NOT NULL, received_at REAL NOT NULL)
            """)
        try await raw.execute("""
            INSERT INTO submission VALUES ('sub_old', 'in_a', 1, 'wv_1', 'd', 1780000000)
            """)

        let store = try await ResponseStore(database: raw)
        try await store.append(
            Submission(id: "sub_new", instrumentID: "in_a", version: 1, waveID: "wv_1",
                       consentDigest: "d", participantCode: "P-BCDF2345",
                       answers: [StoredAnswer(itemID: "it_1", text: "4")]))

        let submissions = try await store.submissions(instrument: "in_a", version: 1)
        #expect(submissions.count == 2)
        #expect(submissions.first { $0.id == "sub_old" }?.participantCode == nil)
        #expect(submissions.first { $0.id == "sub_new" }?.participantCode == "P-BCDF2345")
    }
}
