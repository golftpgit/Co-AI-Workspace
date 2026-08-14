import Foundation
import AgentKit
import Observability
import OLTP

// ─────────────────────────────────────────────────────────────
// Answers, moved to where they can be analysed (ARCHITECTURE §19.17, P11.6b).
//
// §19.17 draws this arrow as a DuckDB `ATTACH` over the SQLite file. That is the
// right picture and the wrong mechanism here: P6.2 and U19 both recorded that a
// sandboxed DuckDB cannot load `sqlite_scanner` without network access, which
// means the arrow would work on a developer's machine and fail on the day a
// researcher is offline with their data. So the rows are read through `OLTP` and
// inserted, which needs no extension and no network.
//
// The direction is unchanged and it is the direction that matters: **the app
// pulls**. M16 still has no code path to DuckDB — it does not know this type
// exists — so a web request can never reach the analytical store, which is
// §19.17's first invariant.
//
// Two things this deliberately does not do:
//
//  • It does not pivot. One row per answer, with the question's own words beside
//    it, because a wide table keyed on opaque item ids is a table nobody can
//    read and a pivot is one `PIVOT` away in the notebook.
//  • It does not hide a correction. The value materialised is the corrected one,
//    and `was_corrected` says so — an analysis that silently used a changed
//    number would be exactly the thing the correction record exists to prevent.
// ─────────────────────────────────────────────────────────────

public struct MaterializedResponses: Sendable, Equatable {
    public let table: String
    public let rows: Int
    public let submissions: Int
    /// How many values in this table were corrected after they arrived. Reported
    /// rather than left to be noticed: it belongs in a methods section.
    public let corrections: Int
}

public struct ResponseMaterializer: Sendable {
    private let store: ResponseStore
    private let analysis: AnalysisStore
    private let spans: (any SpanSink)?
    private let log = AppLog.logger("materialize")

    public init(reading store: ResponseStore, into analysis: AnalysisStore,
                spans: (any SpanSink)? = nil) {
        self.store = store
        self.analysis = analysis
        self.spans = spans
    }

    /// The table one instrument version's answers land in. Named for the
    /// version because two versions are two datasets (§20.6): putting them in
    /// one table is the mistake versioning exists to prevent.
    public static func tableName(instrument: String, version: Int) -> String {
        // The id is opaque and already safe, but a table name built from data is
        // still a table name built from data.
        let safe = instrument.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return "responses_\(safe)_v\(version)"
    }

    /// Copies one version's answers across, replacing whatever was there.
    ///
    /// Replacing rather than appending, and a span every time (§19.17 invariant
    /// 3): "which pull produced the numbers in table 2" has to have an answer,
    /// and a table that accumulates across pulls cannot give one.
    @discardableResult
    public func materialize(instrument: String, version: Int,
                            prompts: [String: String] = [:]) async throws
        -> MaterializedResponses {
        let started = Date()
        let table = Self.tableName(instrument: instrument, version: version)
        let submissions = try await store.submissions(instrument: instrument, version: version)
        let answers = try await store.answers(instrument: instrument, version: version)
        let receivedAt = Dictionary(uniqueKeysWithValues:
            submissions.map { ($0.id, $0.receivedAt) })
        let waves = Dictionary(uniqueKeysWithValues: submissions.map { ($0.id, $0.waveID) })

        try await analysis.query("""
            CREATE OR REPLACE TABLE "\(table)" (
                submission_id VARCHAR,
                wave_id VARCHAR,
                received_at TIMESTAMP,
                item_id VARCHAR,
                item_prompt VARCHAR,
                value_text VARCHAR,
                value_number DOUBLE,
                was_corrected BOOLEAN
            )
            """)

        var corrections = 0
        for answer in answers {
            guard let received = receivedAt[answer.submissionID] else { continue }
            if answer.wasCorrected { corrections += 1 }
            let number = Double(answer.text)
            try await analysis.query("""
                INSERT INTO "\(table)" VALUES (
                    \(quoted(answer.submissionID)),
                    \(quoted(waves[answer.submissionID] ?? "")),
                    TIMESTAMP '\(Self.timestamp(received))',
                    \(quoted(answer.itemID)),
                    \(quoted(prompts[answer.itemID] ?? answer.itemID)),
                    \(quoted(answer.text)),
                    \(number.map { "\($0)" } ?? "NULL"),
                    \(answer.wasCorrected)
                )
                """)
        }

        let result = MaterializedResponses(table: table, rows: answers.count,
                                           submissions: submissions.count,
                                           corrections: corrections)
        log.info("materialised \(result.rows, privacy: .public) answers into \(table, privacy: .public)")
        await spans?.record(Span(name: "responses.materialize", status: .succeeded,
                                 startedAt: started, endedAt: Date(),
                                 detail: "\(table) · \(result.submissions) submissions · "
                                     + "\(result.rows) answers · \(result.corrections) corrected"))
        return result
    }

    /// Single quotes, doubled. The values here came from a web form, and this is
    /// the one place they are put into SQL text — DuckDB's Swift API takes a
    /// statement, not bindings, so the escaping is done here rather than hoped
    /// for.
    private func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
