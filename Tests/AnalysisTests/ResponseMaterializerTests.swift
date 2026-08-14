import Testing
import Foundation
import AgentKit
import Observability
import OLTP
@testable import Analysis

// ─────────────────────────────────────────────────────────────
// Answers into the analytical store (ARCHITECTURE §19.17, P11.6b).
//
// The path this proves is the one the picture in §19.17 draws with an `ATTACH`
// and this build does with a read-and-insert, for the reason recorded in P6.2: a
// sandboxed DuckDB cannot fetch `sqlite_scanner`, so the arrow that works on a
// developer's machine is the one that fails on a researcher's.
//
// What matters most here is not that rows arrive. It is that a corrected answer
// arrives **as the corrected value, marked** — an analysis that silently used a
// changed number would be the exact thing the correction record exists to stop.
// ─────────────────────────────────────────────────────────────

private func temporary() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "mat-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func submission(_ index: Int, wave: String = "wv_1") -> Submission {
    Submission(id: "sub_\(index)", instrumentID: "in_a", version: 2, waveID: wave,
               consentDigest: "d1",
               answers: [StoredAnswer(itemID: "it_1", text: "\(index)", number: Double(index)),
                         StoredAnswer(itemID: "it_2", text: "ตอบอิสระ \(index)")],
               receivedAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index)))
}

@Suite("Materialising responses")
struct ResponseMaterializerTests {

    @Test("answers reach DuckDB with the question's own words beside them")
    func answersLandInAnalysableForm() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let responses = try await ResponseStore(path: directory.appending(path: "r.sqlite"))
        let analysis = try AnalysisStore(fileURL: directory.appending(path: "a.duckdb"))
        for index in 1...3 { try await responses.append(submission(index)) }

        let spans = InMemorySpanSink()
        let result = try await ResponseMaterializer(reading: responses, into: analysis,
                                                    spans: spans)
            .materialize(instrument: "in_a", version: 2,
                         prompts: ["it_1": "ฉันเครียด", "it_2": "อธิบายเพิ่ม"])

        #expect(result.rows == 6)
        #expect(result.submissions == 3)
        #expect(result.table == "responses_in_a_v2")

        // Readable from the notebook, which is the whole point of moving them.
        let rows = try await analysis.query("""
            SELECT item_prompt, value_text, value_number FROM "\(result.table)"
            WHERE item_id = 'it_1' ORDER BY value_number
            """)
        #expect(rows.rows.count == 3)
        #expect(rows.rows.first?.first == "ฉันเครียด")

        // §19.17 invariant 3: every pull writes a span, so "which extraction
        // produced the numbers in table 2" always has an answer.
        #expect(await spans.spans(named: "responses.materialize").count == 1)
    }

    @Test("a corrected answer arrives corrected, and says that it was")
    func correctionsTravelWithTheirMark() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let responses = try await ResponseStore(path: directory.appending(path: "r.sqlite"))
        let analysis = try AnalysisStore(fileURL: directory.appending(path: "a.duckdb"))
        try await responses.append(submission(1))
        try await responses.correct(Correction(submissionID: "sub_1", itemID: "it_1",
                                               previousText: "1", newText: "5",
                                               reason: "ผู้ตอบแจ้งกลับว่ากดผิด",
                                               correctedBy: "ผู้วิจัย"))

        let result = try await ResponseMaterializer(reading: responses, into: analysis)
            .materialize(instrument: "in_a", version: 2)
        #expect(result.corrections == 1)

        let rows = try await analysis.query("""
            SELECT value_text, was_corrected FROM "\(result.table)" WHERE item_id = 'it_1'
            """)
        #expect(rows.rows.first?.first == "5")
        #expect(rows.rows.first?.last??.lowercased().hasPrefix("t") == true)
    }

    @Test("two versions are two tables, because they are two datasets")
    func versionsGetTheirOwnTable() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let responses = try await ResponseStore(path: directory.appending(path: "r.sqlite"))
        let analysis = try AnalysisStore(fileURL: directory.appending(path: "a.duckdb"))
        try await responses.append(submission(1))
        try await responses.append(
            Submission(id: "sub_9", instrumentID: "in_a", version: 3, waveID: "wv_2",
                       consentDigest: "d1",
                       answers: [StoredAnswer(itemID: "it_1", text: "4", number: 4)]))

        let materializer = ResponseMaterializer(reading: responses, into: analysis)
        let second = try await materializer.materialize(instrument: "in_a", version: 2)
        let third = try await materializer.materialize(instrument: "in_a", version: 3)

        #expect(second.table != third.table)
        #expect(second.rows == 2)
        #expect(third.rows == 1)
    }

    @Test("pulling twice replaces rather than doubles")
    func repeatedPullsReplace() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let responses = try await ResponseStore(path: directory.appending(path: "r.sqlite"))
        let analysis = try AnalysisStore(fileURL: directory.appending(path: "a.duckdb"))
        try await responses.append(submission(1))

        let materializer = ResponseMaterializer(reading: responses, into: analysis)
        _ = try await materializer.materialize(instrument: "in_a", version: 2)
        try await responses.append(submission(2))
        let again = try await materializer.materialize(instrument: "in_a", version: 2)

        // A table that accumulates across pulls cannot answer "which pull is
        // this", which is what the span exists to record.
        #expect(again.rows == 4)
        let count = try await analysis.query("SELECT COUNT(*) FROM \"\(again.table)\"")
        #expect(count.rows.first?.first == "4")
    }

    @Test("an apostrophe in an answer is a character, not a statement")
    func answersAreEscaped() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let responses = try await ResponseStore(path: directory.appending(path: "r.sqlite"))
        let analysis = try AnalysisStore(fileURL: directory.appending(path: "a.duckdb"))
        // These values came from a web form filled in by somebody who is not the
        // owner of this machine, which is the whole reason this test exists.
        try await responses.append(
            Submission(id: "sub_x", instrumentID: "in_a", version: 2, waveID: "wv_1",
                       consentDigest: "d1",
                       answers: [StoredAnswer(itemID: "it_2",
                                              text: "it's fine'); DROP TABLE x; --")]))

        let result = try await ResponseMaterializer(reading: responses, into: analysis)
            .materialize(instrument: "in_a", version: 2)
        #expect(result.rows == 1)
        let rows = try await analysis.query("SELECT value_text FROM \"\(result.table)\"")
        #expect(rows.rows.first?.first == "it's fine'); DROP TABLE x; --")
    }
}
