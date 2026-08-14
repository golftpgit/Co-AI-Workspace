import Testing
import Foundation
import AgentKit
import Instruments
import OLTP
@testable import FieldServer

// ─────────────────────────────────────────────────────────────
// The whole path, once (ARCHITECTURE §20.4 · §20.7, P11.3).
//
// The factor tests check the arithmetic against an independent implementation,
// and the scoring tests check what becomes a number. Neither of them touches a
// database, and that is the join this project has been caught at before: a
// capability that works everywhere except where it is actually called from.
//
// So this one goes the long way round — forty POSTs through the routing table
// into the real SQLite store, read back out of it, and only then scored. If the
// answers come back keyed differently, or a Likert ordinal arrives as its label,
// or a correction lands somewhere the reader does not look, it fails here rather
// than in somebody's chapter 4.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_scale")

private func likertKind() -> ItemKind {
    .likert(levels: (1...5).map { Bilingual("ระดับ \($0)") })
}

/// Two constructs of three items — the smallest instrument a two-factor
/// solution can be asked about.
private func twoConstructInstrument() throws -> (PublishedInstrument, [String]) {
    let question = ResearchQuestion(text: Bilingual("อะไรทำให้พยาบาลอยู่ต่อ"))
    let workload = Construct(name: Bilingual("ภาระงาน"), definition: "งานต่อเวร",
                             researchQuestionID: question.id)
    let team = Construct(name: Bilingual("ความสัมพันธ์ในทีม"), definition: "การช่วยเหลือกัน",
                         researchQuestionID: question.id)
    var items: [Item] = []
    for index in 0..<3 {
        items.append(Item(prompt: Bilingual("ภาระงาน ข้อ \(index + 1)"), kind: likertKind(),
                          constructID: workload.id, order: index))
    }
    for index in 0..<3 {
        items.append(Item(prompt: Bilingual("ทีม ข้อ \(index + 1)"), kind: likertKind(),
                          constructID: team.id, order: 3 + index))
    }

    let instrument = Instrument(
        projectID: project, title: Bilingual("แบบสอบถามการคงอยู่"),
        researchQuestions: [question], constructs: [workload, team], items: items,
        consent: ConsentText(purpose: Bilingual("ศึกษาการคงอยู่ของพยาบาล"),
                             whatIsCollected: Bilingual("คะแนนแบบสอบถาม ไม่เก็บชื่อ"),
                             voluntary: Bilingual("สมัครใจ ถอนตัวได้ทุกเมื่อ"),
                             contact: "researcher@example.ac.th"),
        ethics: .approved(committee: "คณะกรรมการจริยธรรม", number: "COA-9",
                          date: Date(), declaredBy: "ผู้วิจัย"))

    let ratings = instrument.itemsUnderContentReview.flatMap { item in
        ["ก", "ข", "ค"].map {
            ExpertRating(itemID: item.id, expert: $0, congruence: 1, relevance: 4)
        }
    }
    let validity = ContentValidity.assess(
        ratings: ratings, itemIDs: instrument.itemsUnderContentReview.map(\.id))
    return (try InstrumentGate.approve(instrument, validity: validity, by: "ผู้วิจัย"),
            instrument.ordered.map(\.id))
}

/// The same answers the factor tests were checked against, so the structure that
/// comes out at the far end is one whose right answer is already known.
private let plantedAnswers: [[Int]] = [
    [3, 3, 4, 1, 2, 2], [2, 2, 2, 3, 3, 3], [3, 3, 3, 4, 2, 4], [4, 5, 5, 3, 3, 2],
    [4, 3, 5, 3, 3, 4], [2, 3, 4, 2, 4, 4], [3, 5, 4, 5, 4, 4], [3, 3, 4, 2, 3, 2],
    [2, 1, 2, 2, 1, 2], [3, 3, 3, 3, 2, 2], [4, 3, 4, 3, 4, 3], [4, 3, 4, 1, 1, 2],
    [3, 3, 5, 4, 3, 3], [3, 3, 4, 3, 2, 3], [2, 3, 3, 2, 3, 2], [3, 4, 3, 4, 5, 4],
    [3, 2, 2, 1, 1, 2], [4, 5, 4, 4, 4, 4], [2, 1, 1, 2, 1, 2], [2, 2, 2, 3, 4, 3],
    [5, 3, 4, 2, 2, 3], [4, 4, 4, 2, 3, 3], [4, 3, 4, 3, 5, 4], [3, 3, 3, 1, 2, 2],
    [2, 1, 2, 3, 2, 4], [4, 4, 5, 4, 4, 5], [1, 1, 2, 2, 2, 3], [2, 3, 1, 4, 3, 5],
    [2, 2, 2, 3, 4, 4], [3, 3, 2, 3, 4, 3], [3, 3, 3, 2, 2, 2], [2, 2, 3, 3, 2, 3],
    [2, 1, 2, 4, 3, 4], [4, 4, 5, 3, 2, 3], [2, 3, 3, 3, 3, 3], [4, 3, 3, 4, 4, 4],
    [3, 3, 3, 4, 4, 3], [3, 2, 3, 4, 3, 3], [5, 5, 5, 3, 4, 3], [3, 3, 3, 3, 4, 4],
]

private func submission(_ published: PublishedInstrument, _ itemIDs: [String],
                        _ row: [Int]) -> HTTPRequest {
    var fields = [("__consent", "yes"),
                  ("__instrument", published.instrument.id),
                  ("__version", "\(published.instrument.version)")]
    for (itemID, value) in zip(itemIDs, row) {
        fields.append((itemID, "\(value)"))
    }
    let body = fields.map { name, value in
        let escape = { (text: String) in
            text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        }
        return "\(escape(name))=\(escape(value))"
    }.joined(separator: "&")
    return HTTPRequest(method: "POST", path: "/submit",
                       headers: ["content-type": "application/x-www-form-urlencoded"],
                       body: Data(body.utf8))
}

/// Reads the store back the way the screen does: current values, keyed by item.
private func answersByRespondent(_ store: ResponseStore, instrument: String,
                                 version: Int) async throws -> [[String: String]] {
    let submissions = try await store.submissions(instrument: instrument, version: version)
    let answers = try await store.answers(instrument: instrument, version: version)
    let grouped = Dictionary(grouping: answers, by: \.submissionID)
    return submissions.map { row in
        Dictionary((grouped[row.id] ?? []).map { ($0.itemID, $0.text) },
                   uniquingKeysWith: { first, _ in first })
    }
}

@Suite("from the form to the factor solution")
struct ScaleFromFieldTests {

    private func filled() async throws
        -> (PublishedInstrument, [String], ResponseStore, URL, FieldServerHost) {
        let (published, itemIDs) = try twoConstructInstrument()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try await ResponseStore(path: directory.appending(path: "responses.sqlite"))
        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        for row in plantedAnswers {
            let response = await host.handle(submission(published, itemIDs, row),
                                             from: "192.168.1.20")
            #expect(response.status == 200)
        }
        return (published, itemIDs, store, directory, host)
    }

    @Test("forty answers posted through the form come back out as the structure they were built with")
    func endToEnd() async throws {
        let (published, itemIDs, store, directory, host) = try await filled()
        defer {
            Task { await host.stop() }
            try? FileManager.default.removeItem(at: directory)
        }

        let rows = try await answersByRespondent(store, instrument: published.instrument.id,
                                                 version: 1)
        #expect(rows.count == 40)

        let scored = ScoredResponses.score(instrument: published.instrument, answers: rows)
        #expect(scored.itemIDs == itemIDs)
        #expect(scored.matrix.count == 40)
        #expect(scored.droppedRespondents == 0)

        let report = ScaleReport.of(instrument: published.instrument, scored: scored,
                                    rule: .parallelAnalysis)
        let solution = try #require(report.solution)
        #expect(solution.retained == 2)
        #expect(abs(solution.adequacy.kmo - 0.718420) < 1e-5)

        // Each construct's three items land together and nowhere else — the
        // instrument was written that way, and this is the path that has to agree.
        let fit = try #require(report.fit)
        #expect(fit.constructs.count == 2)
        #expect(fit.misplaced.isEmpty)
        #expect(fit.mergedConstructs.isEmpty)
        #expect(report.subscales.count == 2)
        #expect(report.subscales.allSatisfy { $0.alpha?.passes == true })
        #expect(report.subscales.allSatisfy { $0.omega?.passes == true })
    }

    @Test("a corrected answer is the one that gets analysed, and the original still exists")
    func correctionsAreWhatIsAnalysed() async throws {
        let (published, itemIDs, store, directory, host) = try await filled()
        defer {
            Task { await host.stop() }
            try? FileManager.default.removeItem(at: directory)
        }

        let submissions = try await store.submissions(instrument: published.instrument.id,
                                                      version: 1)
        let first = try #require(submissions.first)
        // The first respondent answered 3 to the first item; a data-entry check
        // finds it should have been 5.
        try await store.correct(Correction(submissionID: first.id, itemID: itemIDs[0],
                                           previousText: "3", newText: "5",
                                           reason: "ตรวจกับแบบกระดาษแล้วลงผิด",
                                           correctedBy: "ผู้ช่วยวิจัย"))

        let rows = try await answersByRespondent(store, instrument: published.instrument.id,
                                                 version: 1)
        let scored = ScoredResponses.score(instrument: published.instrument, answers: rows)
        #expect(scored.matrix[0][0] == 5)

        // And the row that arrived is untouched: §19.17 invariant 2 is what makes
        // the corrected number defensible in the first place.
        let raw = try await store.answers(instrument: published.instrument.id, version: 1)
        let corrected = try #require(raw.first { $0.submissionID == first.id
                                                 && $0.itemID == itemIDs[0] })
        #expect(corrected.text == "5")
        #expect(corrected.corrected?.previousText == "3")
    }
}
