import Testing
import Foundation
import AgentKit
import Instruments
import OLTP
@testable import FieldServer

// ─────────────────────────────────────────────────────────────
// The socket, not the routing table (P11.5, §20.7).
//
// Everything else in this target hands `handle(_:from:)` a request it built. That
// proves the decisions and nothing about whether a browser can reach them: the
// listener, the parser, the wire format and the concurrency are all below that
// line, and all four are where a form that "works" fails on the day twenty
// people open it at once.
//
// So this suite talks HTTP over a real port. It is slower than the rest, and it
// is the part that would have caught a Content-Length off by one.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_socket")

private func approvedInstrument() throws -> PublishedInstrument {
    let question = ResearchQuestion(text: Bilingual("ความเครียดของพยาบาลเวรดึกเป็นอย่างไร"))
    let construct = Construct(name: Bilingual("ความเครียด"), definition: "ความกดดันระหว่างเวร",
                              researchQuestionID: question.id)
    let levels = (1...5).map { Bilingual("ระดับ \($0)") }
    let items = [
        Item(prompt: Bilingual("ฉันรู้สึกตึงเครียดระหว่างเวรดึก"),
             kind: .likert(levels: levels), constructID: construct.id, order: 1),
        Item(prompt: Bilingual("ประสบการณ์ (ปี)"), kind: .number(minimum: 0, maximum: 50),
             required: false, isDemographic: true, order: 2),
    ]
    let instrument = Instrument(
        projectID: project, title: Bilingual("แบบสอบถามความเครียดเวรดึก"),
        researchQuestions: [question], constructs: [construct], items: items,
        consent: ConsentText(purpose: Bilingual("ศึกษาความเครียดเวรดึก"),
                             whatIsCollected: Bilingual("คะแนนและปีประสบการณ์"),
                             voluntary: Bilingual("สมัครใจ ถอนตัวได้"),
                             contact: "researcher@example.ac.th"),
        ethics: .approved(committee: "คณะกรรมการจริยธรรม", number: "COA-2",
                          date: Date(), declaredBy: "ผู้วิจัย"))
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

/// Ask the system for a port instead of guessing one.
///
/// This was `UInt16.random(in: 49_200...50_800)`, which is not "a port nobody
/// is using" — it is a guess, and it collided often enough to fail one full run
/// in three while passing on its own. Port 0 means "you choose", and
/// `start(serving:port:)` reports back what it actually got, so there is no gap
/// between finding a port and binding it for anything else to slip into.
private let anyFreePort: UInt16 = 0

private func request(_ method: String, _ path: String, port: UInt16,
                     body: String? = nil) async throws -> (status: Int, body: String) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 10
    if let body {
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (status, String(decoding: data, as: UTF8.self))
}

@Suite("Field server over a real socket", .serialized)
struct SocketTests {

    @Test("a browser can open the form and send it back")
    func formRoundTripsOverHTTP() async throws {
        let published = try approvedInstrument()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ResponseStore(path: directory.appending(path: "responses.sqlite"))
        let host = FieldServerHost(store: store)
        let address = try await host.start(serving: published, port: anyFreePort)
        defer { Task { await host.stop() } }
        let port = address.port

        // The address has to name a real port — reporting the 0 that was asked
        // for would be a caller that cannot reach its own server.
        #expect(port != 0)

        let page = try await request("GET", "/", port: port)
        #expect(page.status == 200)
        #expect(page.body.contains("ความยินยอมในการเข้าร่วม"))
        #expect(page.body.contains("ฉันรู้สึกตึงเครียดระหว่างเวรดึก"))

        let items = published.instrument.ordered
        let form = "__consent=yes&__instrument=\(published.instrument.id)"
            + "&__version=1&\(items[0].id)=4&\(items[1].id)=6"
        let sent = try await request("POST", "/submit", port: port, body: form)
        #expect(sent.status == 200)
        #expect(sent.body.contains("บันทึกคำตอบเรียบร้อย"))

        #expect(try await store.submissionCount(instrument: published.instrument.id,
                                                version: 1) == 1)
    }

    @Test("twenty phones submitting at once lose nothing")
    func concurrentSubmissionsOverHTTP() async throws {
        let published = try approvedInstrument()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ResponseStore(path: directory.appending(path: "responses.sqlite"))
        let host = FieldServerHost(store: store)
        let port = try await host.start(serving: published, port: anyFreePort).port
        defer { Task { await host.stop() } }

        let items = published.instrument.ordered
        // The end of a shift briefing: everybody presses submit together. This is
        // the scenario §19.17 says DuckDB would have failed, and the reason there
        // is a third database at all.
        let statuses = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<20 {
                group.addTask {
                    let form = "__consent=yes&__instrument=\(published.instrument.id)"
                        + "&__version=1&\(items[0].id)=\(index % 5 + 1)&\(items[1].id)=\(index)"
                    return (try? await request("POST", "/submit", port: port, body: form))?.status ?? 0
                }
            }
            var collected: [Int] = []
            for await status in group { collected.append(status) }
            return collected
        }

        // The tally is in the message on purpose. This failed once during a full
        // `check.sh` run and passed everywhere else, and a bare "not all 200" is
        // an hour of guessing — the first thing worth knowing is whether the
        // refusals came from the server deciding or from the socket dropping.
        let tally = Dictionary(grouping: statuses, by: { $0 }).mapValues(\.count)
        #expect(statuses.allSatisfy { $0 == 200 }, "statuses: \(tally)")
        #expect(try await store.submissionCount(instrument: published.instrument.id,
                                                version: 1) == 20)
        // Two answers each, none half-written.
        #expect(try await store.answers(instrument: published.instrument.id, version: 1).count == 40)
    }

    @Test("closing the round refuses over the wire, not only in the app")
    func closedWaveRefusesOverHTTP() async throws {
        let published = try approvedInstrument()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ResponseStore(path: directory.appending(path: "responses.sqlite"))
        let host = FieldServerHost(store: store)
        let port = try await host.start(serving: published, port: anyFreePort).port
        defer { Task { await host.stop() } }

        await host.closeWave()

        let items = published.instrument.ordered
        let form = "__consent=yes&__instrument=\(published.instrument.id)"
            + "&__version=1&\(items[0].id)=4"
        // A page somebody left open in a tab before the round closed, submitted
        // after. §20.7 invariant 5 is about exactly this request.
        let sent = try await request("POST", "/submit", port: port, body: form)
        #expect(sent.status == 410)
        #expect(try await store.submissionCount(instrument: published.instrument.id,
                                                version: 1) == 0)
    }

    @Test("nothing on this server answers but the form")
    func noOtherEndpointsOverHTTP() async throws {
        let published = try approvedInstrument()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await ResponseStore(path: directory.appending(path: "responses.sqlite"))
        let host = FieldServerHost(store: store)
        let port = try await host.start(serving: published, port: anyFreePort).port
        defer { Task { await host.stop() } }

        for path in ["/admin", "/responses", "/api/v1/responses", "/status"] {
            let response = try await request("GET", path, port: port)
            #expect(response.status == 404, "\(path) answered \(response.status)")
        }
    }
}
