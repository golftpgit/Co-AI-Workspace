import Testing
import Foundation
import AgentKit
import Instruments
import OLTP
@testable import FieldServer

// ─────────────────────────────────────────────────────────────
// M16 (ARCHITECTURE §20.7, P11.5).
//
// Everything here goes through `handle(_:from:)` — the routing table — rather
// than through the page, because the page is the sender's and `curl` is not
// obliged to run its JavaScript. The tests that matter are the ones a browser
// cannot produce: a closed wave that is POSTed to anyway, a field nobody asked
// for, a submission naming a different version, a required answer left out by
// something that never rendered the `required` attribute.
//
// Note what cannot be tested here, because it does not compile: handing this
// server an instrument that has not passed the gate. There is no such value.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_field")

private func likert() -> ItemKind {
    .likert(levels: [Bilingual("ไม่เห็นด้วยอย่างยิ่ง"), Bilingual("ไม่เห็นด้วย"),
                     Bilingual("เฉย ๆ"), Bilingual("เห็นด้วย"), Bilingual("เห็นด้วยอย่างยิ่ง")])
}

/// Approves whatever instrument it is handed — the only way to get a
/// `PublishedInstrument`, here as everywhere.
private func approve(_ instrument: Instrument) throws -> PublishedInstrument {
    let reviewed = instrument.itemsUnderContentReview
    let ratings = reviewed.flatMap { item in
        ["ก", "ข", "ค"].map {
            ExpertRating(itemID: item.id, expert: $0, congruence: 1, relevance: 4)
        }
    }
    let validity = ContentValidity.assess(ratings: ratings, itemIDs: reviewed.map(\.id))
    return try InstrumentGate.approve(instrument, validity: validity, by: "ผู้วิจัย")
}

/// A published instrument, which can only be made by passing the gate.
/// `addingFollowUp` gets the instrument once its items exist, so a skip
/// condition can point at a real one.
private func approved(
    addingFollowUp: ((Instrument) -> Item)? = nil
) throws -> PublishedInstrument {
    let question = ResearchQuestion(text: Bilingual("พยาบาลมีภาวะหมดไฟมากน้อยเพียงใด"))
    let construct = Construct(name: Bilingual("ภาวะหมดไฟ"), definition: "ความอ่อนล้าทางอารมณ์",
                              researchQuestionID: question.id)
    let items = [
        Item(prompt: Bilingual("ฉันรู้สึกอ่อนล้าทางอารมณ์จากงาน"), kind: likert(),
             constructID: construct.id, order: 1),
        Item(prompt: Bilingual("ฉันหมดพลังเมื่อคิดถึงเวรถัดไป"), kind: likert(),
             constructID: construct.id, order: 2),
        Item(prompt: Bilingual("อายุ"), kind: .number(minimum: 18, maximum: 70),
             required: false, isDemographic: true, order: 3),
    ]

    var instrument = Instrument(
        projectID: project, title: Bilingual("แบบวัดภาวะหมดไฟ"),
        researchQuestions: [question], constructs: [construct], items: items,
        consent: ConsentText(purpose: Bilingual("ศึกษาภาวะหมดไฟ"),
                             whatIsCollected: Bilingual("คะแนนแบบวัดและอายุ ไม่เก็บชื่อ"),
                             voluntary: Bilingual("สมัครใจ ถอนตัวได้ทุกเมื่อ"),
                             contact: "researcher@example.ac.th"),
        ethics: .approved(committee: "คณะกรรมการจริยธรรม", number: "COA-1",
                          date: Date(), declaredBy: "ผู้วิจัย"))

    if let addingFollowUp {
        instrument.items.append(addingFollowUp(instrument))
    }
    return try approve(instrument)
}

private func temporaryStore() async throws -> (ResponseStore, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "field-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try await ResponseStore(path: directory.appending(path: "responses.sqlite")), directory)
}

/// A form POST, encoded the way a browser encodes one.
private func post(_ fields: [(String, String)], to path: String = "/submit") -> HTTPRequest {
    let body = fields.map { name, value in
        let escape = { (text: String) in
            text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        }
        return "\(escape(name))=\(escape(value))"
    }.joined(separator: "&")
    return HTTPRequest(method: "POST", path: path,
                       headers: ["content-type": "application/x-www-form-urlencoded"],
                       body: Data(body.utf8))
}

private func completeAnswers(_ published: PublishedInstrument) -> [(String, String)] {
    let items = published.instrument.ordered
    return [("__consent", "yes"),
            ("__instrument", published.instrument.id),
            ("__version", "\(published.instrument.version)"),
            (items[0].id, "4"),
            (items[1].id, "5"),
            (items[2].id, "31")]
}

@Suite("Field server")
struct FieldServerTests {

    @Test("a complete submission is stored, and the page says nothing about it back")
    func completeSubmissionIsStored() async throws {
        let published = try approved()
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        let response = await host.handle(post(completeAnswers(published)), from: "192.168.1.9")
        #expect(response.status == 200)
        let page = String(decoding: response.body, as: UTF8.self)
        #expect(page.contains("บันทึกคำตอบเรียบร้อย"))
        // The thank-you page is reachable by anyone with the link, so it must not
        // echo what was answered.
        #expect(!page.contains("31"))

        #expect(try await store.submissionCount(instrument: published.instrument.id,
                                                version: 1) == 1)
        let answers = try await store.answers(instrument: published.instrument.id, version: 1)
        #expect(answers.count == 3)
    }

    @Test("closing the round makes the endpoint refuse, not the button disappear")
    func closedWaveRejectsAtTheEndpoint() async throws {
        let published = try approved()
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        await host.closeWave()
        // POSTed directly, the way a page left open in a tab would POST.
        let response = await host.handle(post(completeAnswers(published)), from: "192.168.1.9")
        #expect(response.status == 410)
        #expect(try await store.submissionCount(instrument: published.instrument.id, version: 1) == 0)

        // And the form itself stops being served.
        let page = await host.handle(HTTPRequest(method: "GET", path: "/"), from: "192.168.1.9")
        #expect(page.status == 410)
    }

    @Test("a field the instrument does not define is dropped and written down")
    func foreignFieldsAreDroppedAndRecorded() async throws {
        let published = try approved()
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        var fields = completeAnswers(published)
        fields.append(("is_admin", "1"))
        fields.append(("it_from_another_form", "42"))

        let response = await host.handle(post(fields), from: "192.168.1.9")
        #expect(response.status == 200)
        #expect(try await store.droppedFieldCount() == 2)
        // Three answers, not five: the extra names are evidence, not columns.
        #expect(try await store.answers(instrument: published.instrument.id, version: 1).count == 3)
    }

    @Test("a required answer left out is refused, and the reason comes back with the form")
    func missingRequiredIsRefused() async throws {
        let published = try approved()
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        // No `required` attribute was involved: this sender never rendered the page.
        let fields = completeAnswers(published).filter { $0.0 != published.instrument.ordered[1].id }
        let response = await host.handle(post(fields), from: "192.168.1.9")
        #expect(response.status == 400)
        let page = String(decoding: response.body, as: UTF8.self)
        #expect(page.contains("ยังไม่ได้ตอบข้อที่จำเป็น"))
        #expect(try await store.submissionCount(instrument: published.instrument.id, version: 1) == 0)
    }

    @Test("consent is checked on this side of the wire")
    func consentIsCheckedOnTheServer() async throws {
        let published = try approved()
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        let fields = completeAnswers(published).filter { $0.0 != "__consent" }
        let response = await host.handle(post(fields), from: "192.168.1.9")
        #expect(response.status == 400)
        #expect(String(decoding: response.body, as: UTF8.self).contains("ยินยอม"))
        #expect(try await store.submissionCount(instrument: published.instrument.id, version: 1) == 0)
    }

    @Test("an answer to a different version is not a late answer to this one")
    func versionMismatchIsRefused() async throws {
        let published = try approved()
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        var fields = completeAnswers(published)
        fields = fields.map { $0.0 == "__version" ? ($0.0, "9") : $0 }
        let response = await host.handle(post(fields), from: "192.168.1.9")
        #expect(response.status == 400)
        #expect(try await store.submissionCount(instrument: published.instrument.id, version: 1) == 0)
    }

    @Test("there is nothing on this server but the form")
    func noAdminSurface() async throws {
        let published = try approved()
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        for path in ["/admin", "/responses", "/api/responses", "/.env", "/submit/../admin"] {
            let response = await host.handle(HTTPRequest(method: "GET", path: path),
                                             from: "192.168.1.9")
            #expect(response.status == 404, "\(path) answered \(response.status)")
        }
        // And no way to read answers back out, which is the one thing a
        // participant's browser must never be able to do.
        let get = await host.handle(HTTPRequest(method: "GET", path: "/submit"), from: "192.168.1.9")
        #expect(get.status == 405)
    }

    @Test("a question that was skipped is not a question that was left blank")
    func skippedQuestionsAreNotMissing() async throws {
        // "Explain further" is required, and only asked of people who scored 4+.
        let published = try approved { instrument in
            Item(prompt: Bilingual("อธิบายเพิ่มเติม"),
                 kind: .openText(maximumLength: 200),
                 constructID: instrument.constructs[0].id,
                 skip: SkipCondition(itemID: instrument.ordered[0].id,
                                     test: .atLeast, value: "4"),
                 order: 4)
        }
        let (store, directory) = try await temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }

        let items = published.instrument.ordered
        func answers(first: String, follow: String? = nil) -> [(String, String)] {
            var fields: [(String, String)] = [
                ("__consent", "yes"),
                ("__instrument", published.instrument.id),
                ("__version", "1"),
                (items[0].id, first),
                (items[1].id, "3"),
                (items[2].id, "40"),
            ]
            if let follow { fields.append((items[3].id, follow)) }
            return fields
        }

        // Scored 2: the follow-up was never asked, so its absence is not a gap.
        // Nothing in this request says it was hidden — the server works that out
        // from the answer the condition depends on.
        let skipped = await host.handle(post(answers(first: "2")), from: "192.168.1.9")
        #expect(skipped.status == 200)

        // Scored 4: it *was* asked, and leaving it out is a missing answer.
        let asked = await host.handle(post(answers(first: "4")), from: "192.168.1.10")
        #expect(asked.status == 400)
        #expect(String(decoding: asked.body, as: UTF8.self).contains("ยังไม่ได้ตอบข้อที่จำเป็น"))

        // …and answering it goes through.
        let complete = await host.handle(post(answers(first: "4", follow: "เวรดึกติดกันสามคืน")),
                                         from: "192.168.1.11")
        #expect(complete.status == 200)
        #expect(try await store.submissionCount(instrument: published.instrument.id,
                                                version: 1) == 2)
    }

    @Test("the form page escapes what a researcher typed, and asks for consent first")
    func pageIsSafeAndConsentComesFirst() throws {
        var instrument = try approved().instrument
        instrument.items[0].prompt = Bilingual("<script>alert(1)</script> เครียดไหม")
        let published = try approve(instrument)

        let page = FormRuntime.page(for: published, wave: "wv_1")
        #expect(!page.contains("<script>alert(1)</script>"))
        #expect(page.contains("&lt;script&gt;"))
        // Consent before the first question, always (§20.5).
        let consentAt = try #require(page.range(of: "consent-heading")).lowerBound
        let firstItemAt = try #require(page.range(of: "class=\"items\"")).lowerBound
        #expect(consentAt < firstItemAt)
        // Native controls only — that is what makes it work with a screen reader
        // without anybody writing ARIA for a custom widget.
        #expect(page.contains("<legend>"))
        #expect(page.contains("type=\"radio\""))
        #expect(!page.contains("role=\"button\""))
    }
}

@Suite("HTTP parsing")
struct HTTPParsingTests {

    @Test("a body that has not all arrived yet is not a request yet")
    func partialRequestsWait() throws {
        let head = "POST /submit HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc"
        #expect(try HTTPParser.parse(Data(head.utf8)) == nil)
        let whole = "POST /submit HTTP/1.1\r\nContent-Length: 10\r\n\r\nabcdefghij"
        let request = try #require(try HTTPParser.parse(Data(whole.utf8)))
        #expect(request.method == "POST")
        #expect(request.body.count == 10)
    }

    @Test("an oversized body is refused before it is interpreted")
    func oversizedRequestsAreRefused() {
        let head = "POST /submit HTTP/1.1\r\nContent-Length: \(HTTPParser.maximumBody + 1)\r\n\r\n"
        #expect(throws: HTTPParseError.tooLarge) { try HTTPParser.parse(Data(head.utf8)) }

        // …and so is one that never sends the blank line at all, rather than
        // being buffered until the machine gives up.
        let endless = Data(repeating: UInt8(ascii: "a"), count: HTTPParser.maximumHeader + 1)
        #expect(throws: HTTPParseError.tooLarge) { try HTTPParser.parse(endless) }
    }

    @Test("the query is split off the path once, here")
    func queryIsParsed() throws {
        let raw = "GET /?wave=wv_1&lang=th HTTP/1.1\r\nHost: x\r\n\r\n"
        let request = try #require(try HTTPParser.parse(Data(raw.utf8)))
        #expect(request.path == "/")
        #expect(request.query["wave"] == "wv_1")
        #expect(request.query["lang"] == "th")
    }

    @Test("repeated names are one question with several answers")
    func repeatedFieldsCollect() {
        let request = HTTPRequest(method: "POST", path: "/submit",
                                  body: Data("a=1&a=2&b=3".utf8))
        #expect(request.formFields["a"] == ["1", "2"])
        #expect(request.formFields["b"] == ["3"])
    }
}
