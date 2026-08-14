import Testing
import Foundation
import AgentKit
import Instruments
import OLTP
@testable import FieldServer

// ─────────────────────────────────────────────────────────────
// Coming back to a form you started (ARCHITECTURE §20.7's SessionStore, P11.7).
//
// The reason this exists is not convenience. A ward nurse fills in a
// questionnaire between patients; if being interrupted means starting again,
// the ones who finish are the ones who had a quiet shift, and that is a sample
// bias with a mechanism.
//
// What it must not become is an account system. There is no login and no cookie:
// a long random token in a URL the respondent keeps, and nothing else. That
// makes the link a bearer credential for their partial answers, which is why the
// token is long, why the page says losing it loses the draft, and why a draft
// dies with the round it belongs to.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_resume")

private func approvedInstrument() throws -> PublishedInstrument {
    let question = ResearchQuestion(text: Bilingual("ความเครียดเป็นอย่างไร"))
    let construct = Construct(name: Bilingual("ความเครียด"), definition: "ความกดดัน",
                              researchQuestionID: question.id)
    let instrument = Instrument(
        projectID: project, title: Bilingual("แบบสอบถามยาว"),
        researchQuestions: [question], constructs: [construct],
        items: [
            Item(prompt: Bilingual("ฉันเครียด"),
                 kind: .likert(levels: (1...5).map { Bilingual("ระดับ \($0)") }),
                 constructID: construct.id, order: 1),
            Item(prompt: Bilingual("เล่าเพิ่มเติม"), kind: .openText(maximumLength: 500),
                 constructID: construct.id, order: 2),
            Item(prompt: Bilingual("อายุ"), kind: .number(minimum: 18, maximum: 70),
                 required: false, isDemographic: true, order: 3),
        ],
        consent: ConsentText(purpose: Bilingual("ศึกษา"), whatIsCollected: Bilingual("คะแนน"),
                             voluntary: Bilingual("สมัครใจ"), contact: "r@example.ac.th"),
        ethics: .approved(committee: "กรรมการ", number: "COA-5", date: Date(),
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

private func form(_ body: String, to path: String) -> HTTPRequest {
    HTTPRequest(method: "POST", path: path,
                headers: ["content-type": "application/x-www-form-urlencoded"],
                body: Data(body.utf8))
}

private func makeStore() async throws -> (ResponseStore, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "resume-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try await ResponseStore(path: directory.appending(path: "responses.sqlite")),
            directory)
}

/// The token out of the link on the "saved" page.
private func token(in html: String) -> String? {
    guard let range = html.range(of: "?resume=") else { return nil }
    return String(html[range.upperBound...].prefix(while: { $0.isLetter || $0.isNumber }))
}

@Suite("Resuming a form")
struct ResumeTests {

    @Test("a half-filled form comes back with what was typed in it")
    func draftsAreRestored() async throws {
        let published = try approvedInstrument()
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        let items = published.instrument.ordered
        // Interrupted after two questions — and without consent ticked, which a
        // save must not require the way a submit does.
        let partial = "__instrument=\(published.instrument.id)&__version=1&__resume="
            + "&\(items[0].id)=4&\(items[1].id)=\("เวรดึกติดกันสามคืน".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
        let saved = await host.handle(form(partial, to: "/save"), from: "192.168.1.5")
        #expect(saved.status == 200)
        let html = String(decoding: saved.body, as: UTF8.self)
        let resume = try #require(token(in: html))
        #expect(resume.count >= 24)

        // Nothing was submitted: a draft is not an answer.
        #expect(try await store.submissionCount(instrument: published.instrument.id,
                                                version: 1) == 0)

        let back = await host.handle(
            HTTPRequest(method: "GET", path: "/", query: ["resume": resume]),
            from: "192.168.1.5")
        #expect(back.status == 200)
        let form = String(decoding: back.body, as: UTF8.self)
        #expect(form.contains("value=\"4\" required checked")
                || form.contains("value=\"4\" checked"))
        #expect(form.contains("เวรดึกติดกันสามคืน"))
        #expect(form.contains("name=\"__resume\" value=\"\(resume)\""))
    }

    @Test("saving twice keeps one draft, not two")
    func savingAgainReusesTheToken() async throws {
        let published = try approvedInstrument()
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }
        let wave = try #require(await host.currentWave?.id)

        let items = published.instrument.ordered
        let first = await host.handle(
            form("__instrument=\(published.instrument.id)&__version=1&__resume=&\(items[0].id)=2",
                 to: "/save"), from: "192.168.1.5")
        let resume = try #require(token(in: String(decoding: first.body, as: UTF8.self)))

        _ = await host.handle(
            form("__instrument=\(published.instrument.id)&__version=1&__resume=\(resume)"
                 + "&\(items[0].id)=5", to: "/save"), from: "192.168.1.5")

        // One person continuing their own form is one draft.
        #expect(try await store.draftCount(wave: wave) == 1)
        let draft = try #require(try await store.draft(token: resume))
        #expect(draft.fields.contains("=5"))
    }

    @Test("submitting clears the draft it came from")
    func submittingRemovesTheDraft() async throws {
        let published = try approvedInstrument()
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }
        let wave = try #require(await host.currentWave?.id)

        let items = published.instrument.ordered
        let saved = await host.handle(
            form("__instrument=\(published.instrument.id)&__version=1&__resume=&\(items[0].id)=4",
                 to: "/save"), from: "192.168.1.5")
        let resume = try #require(token(in: String(decoding: saved.body, as: UTF8.self)))

        let sent = await host.handle(
            form("__consent=yes&__instrument=\(published.instrument.id)&__version=1"
                 + "&__resume=\(resume)&\(items[0].id)=4&\(items[1].id)=x", to: "/submit"),
            from: "192.168.1.5")
        #expect(sent.status == 200)

        // Left behind, it would be a second copy of somebody's answers with no
        // purpose and no expiry.
        #expect(try await store.draftCount(wave: wave) == 0)
        // And `__resume` is the runtime's own field, not an answer.
        #expect(try await store.answers(instrument: published.instrument.id,
                                        version: 1).count == 2)
        #expect(try await store.droppedFieldCount() == 0)
    }

    @Test("closing the round takes the unfinished forms with it")
    func draftsDieWithTheirRound() async throws {
        let published = try approvedInstrument()
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }
        let wave = try #require(await host.currentWave?.id)

        let items = published.instrument.ordered
        let saved = await host.handle(
            form("__instrument=\(published.instrument.id)&__version=1&__resume=&\(items[0].id)=3",
                 to: "/save"), from: "192.168.1.5")
        let resume = try #require(token(in: String(decoding: saved.body, as: UTF8.self)))
        #expect(try await store.draftCount(wave: wave) == 1)

        await host.closeWave()

        // Personal data collected under a consent for a round that is over, that
        // nobody will ever submit (§20.5).
        #expect(try await store.draftCount(wave: wave) == 0)
        let back = await host.handle(
            HTTPRequest(method: "GET", path: "/", query: ["resume": resume]),
            from: "192.168.1.5")
        #expect(back.status == 410)
    }

    @Test("a draft from another version is refused rather than half-applied")
    func draftsDoNotCrossVersions() async throws {
        let published = try approvedInstrument()
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }
        let wave = try #require(await host.currentWave?.id)

        // A draft saved against version 2 of the same instrument: the questions
        // have changed underneath it, and pouring old answers into a new form is
        // how a value ends up against a question nobody asked it for.
        try await store.save(Draft(token: "stale-token", instrumentID: published.instrument.id,
                                   version: 2, waveID: wave, participantCode: nil,
                                   fields: "x=1"))
        let back = await host.handle(
            HTTPRequest(method: "GET", path: "/", query: ["resume": "stale-token"]),
            from: "192.168.1.5")
        #expect(back.status == 404)

        // As is a token nobody issued.
        let nonsense = await host.handle(
            HTTPRequest(method: "GET", path: "/", query: ["resume": "not-a-token"]),
            from: "192.168.1.5")
        #expect(nonsense.status == 404)
    }

    @Test("a resume token is long and random, unlike a participant code")
    func tokensAreNotGuessable() {
        // The opposite of a participant code and for the opposite reason: nobody
        // reads this one aloud, and it is the only thing standing between a
        // stranger and somebody's half-finished answers.
        let tokens = (0..<200).map { _ in FieldServerHost.freshToken() }
        #expect(Set(tokens).count == tokens.count)
        #expect(tokens.allSatisfy { $0.count == 32 })
    }
}
