import Foundation

// ─────────────────────────────────────────────────────────────
// What people answered (ARCHITECTURE §19.17, P11.6b/P11.6c/P11.7).
//
// Two rules shape every method here, and both are about a kind of damage that
// cannot be undone rather than about tidiness:
//
//  1. **Append-only.** There is no `UPDATE` and no `DELETE` on an answer,
//     anywhere in this file, and `check.sh` fails the build if one appears.
//     Changing a value is a *correction record* — old value, new value, reason,
//     who, when — and the screen shows the corrected value with a mark on it.
//     Research data that can be quietly overwritten is research data nobody can
//     prove was not overwritten.
//
//  2. **A field that is not in the instrument does not become a column.** It is
//     dropped and the drop is written down. Keeping unknown fields "just in
//     case" is how a form that was tampered with looks identical to one that
//     was not.
//
// The raw tables have a fixed schema with a `version` column rather than one
// table per instrument version. Answers arrive while people are answering, and a
// shape that needs `CREATE TABLE` on the way in is a shape that runs DDL under
// concurrency. Per-version tables are how these rows are *materialised into
// DuckDB* for analysis (§19.17), which happens on the app's side of the wall and
// on demand.
// ─────────────────────────────────────────────────────────────

/// One person's answer to one question, as it arrived.
public struct StoredAnswer: Sendable, Equatable {
    public let itemID: String
    /// The answer as text. Everything is kept as text as well as parsed, because
    /// "3" and "3.0" are the same number and different answers, and the thing a
    /// respondent actually chose is the thing a methods section has to describe.
    public let text: String
    public let number: Double?

    public init(itemID: String, text: String, number: Double? = nil) {
        self.itemID = itemID
        self.text = text
        self.number = number
    }
}

/// One completed submission, ready to be written down.
public struct Submission: Sendable, Equatable {
    public let id: String
    public let instrumentID: String
    public let version: Int
    public let waveID: String
    /// The consent text this respondent actually saw, hashed. §20.7 asks for the
    /// version they saw rather than the current one: consent given to an earlier
    /// wording is not consent to a later one.
    public let consentDigest: String
    public let answers: [StoredAnswer]
    /// Field names that arrived and are not in the instrument. Written down, not
    /// stored as data (§20.7 invariant 2).
    public let droppedFields: [String]
    public let receivedAt: Date

    public init(id: String, instrumentID: String, version: Int, waveID: String,
                consentDigest: String, answers: [StoredAnswer],
                droppedFields: [String] = [], receivedAt: Date = Date()) {
        self.id = id
        self.instrumentID = instrumentID
        self.version = version
        self.waveID = waveID
        self.consentDigest = consentDigest
        self.answers = answers
        self.droppedFields = droppedFields
        self.receivedAt = receivedAt
    }
}

/// A change to an answer already given, kept beside it rather than over it.
public struct Correction: Sendable, Equatable {
    public let submissionID: String
    public let itemID: String
    public let previousText: String
    public let newText: String
    /// Why. Required, and not a free pass: a correction with no reason is
    /// indistinguishable from an edit somebody hoped nobody would notice.
    public let reason: String
    public let correctedBy: String
    public let correctedAt: Date

    public init(submissionID: String, itemID: String, previousText: String,
                newText: String, reason: String, correctedBy: String,
                correctedAt: Date = Date()) {
        self.submissionID = submissionID
        self.itemID = itemID
        self.previousText = previousText
        self.newText = newText
        self.reason = reason
        self.correctedBy = correctedBy
        self.correctedAt = correctedAt
    }
}

/// An answer as it should be read today: what arrived, plus any correction.
public struct ResolvedAnswer: Sendable, Equatable {
    public let submissionID: String
    public let itemID: String
    public let text: String
    /// Set when a correction applies, so the screen can show the mark and the
    /// original rather than only the current value.
    public let corrected: Correction?
    public var wasCorrected: Bool { corrected != nil }
}

/// The thing M16 writes to, and the only thing it writes to.
///
/// Deliberately in its own module: keeping it here rather than beside the DuckDB
/// store is what makes "no code path from M16 to DuckDB" a fact about the
/// package graph instead of a sentence in a document (§19.17 invariant 1).
public actor ResponseStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) async throws {
        self.database = database
        try await Self.migrate(database)
    }

    public init(path: URL) async throws {
        try await self.init(database: SQLiteDatabase(path: path))
    }

    private static func migrate(_ database: SQLiteDatabase) async throws {
        for statement in schema {
            try await database.execute(statement)
        }
    }

    static let schema = [
        """
        CREATE TABLE IF NOT EXISTS submission (
            id TEXT PRIMARY KEY,
            instrument_id TEXT NOT NULL,
            version INTEGER NOT NULL,
            wave_id TEXT NOT NULL,
            consent_digest TEXT NOT NULL,
            received_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS submission_instrument ON submission (instrument_id, version)",
        """
        CREATE TABLE IF NOT EXISTS answer (
            submission_id TEXT NOT NULL REFERENCES submission(id),
            item_id TEXT NOT NULL,
            value_text TEXT NOT NULL,
            value_number REAL,
            PRIMARY KEY (submission_id, item_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS correction (
            submission_id TEXT NOT NULL,
            item_id TEXT NOT NULL,
            previous_text TEXT NOT NULL,
            new_text TEXT NOT NULL,
            reason TEXT NOT NULL,
            corrected_by TEXT NOT NULL,
            corrected_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS correction_target ON correction (submission_id, item_id)",
        // Not data: evidence that something arrived which the instrument does not
        // define. Kept so "were there extra fields" is answerable.
        """
        CREATE TABLE IF NOT EXISTS dropped_field (
            submission_id TEXT NOT NULL,
            name TEXT NOT NULL,
            received_at REAL NOT NULL
        )
        """,
    ]

    // MARK: - writing

    /// Appends one submission. Whole or not at all.
    public func append(_ submission: Submission) async throws {
        let stamp = submission.receivedAt.timeIntervalSince1970
        var statements: [(sql: String, bindings: [SQLiteValue])] = [(
            """
            INSERT INTO submission (id, instrument_id, version, wave_id,
                                    consent_digest, received_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(submission.id), .text(submission.instrumentID),
             .integer(Int64(submission.version)), .text(submission.waveID),
             .text(submission.consentDigest), .double(stamp)])]

        for answer in submission.answers {
            statements.append((
                """
                INSERT INTO answer (submission_id, item_id, value_text, value_number)
                VALUES (?, ?, ?, ?)
                """,
                [.text(submission.id), .text(answer.itemID), .text(answer.text),
                 answer.number.map { SQLiteValue.double($0) } ?? .null]))
        }

        for name in submission.droppedFields {
            statements.append((
                "INSERT INTO dropped_field (submission_id, name, received_at) VALUES (?, ?, ?)",
                [.text(submission.id), .text(name), .double(stamp)]))
        }

        try await database.transaction(statements)
    }

    /// Records a change to an answer already given. Note what this does *not*
    /// do: it does not touch the `answer` row (§19.17 invariant 2).
    public func correct(_ correction: Correction) async throws {
        guard !correction.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !correction.correctedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResponseStoreError.correctionNeedsReasonAndPerson
        }
        try await database.execute("""
            INSERT INTO correction (submission_id, item_id, previous_text, new_text,
                                    reason, corrected_by, corrected_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(correction.submissionID), .text(correction.itemID),
             .text(correction.previousText), .text(correction.newText),
             .text(correction.reason), .text(correction.correctedBy),
             .double(correction.correctedAt.timeIntervalSince1970)])
    }

    // MARK: - reading

    public func submissionCount(instrument: String, version: Int) async throws -> Int {
        let rows = try await database.query("""
            SELECT COUNT(*) AS n FROM submission
            WHERE instrument_id = ? AND version = ?
            """, [.text(instrument), .integer(Int64(version))])
        return Int(rows.first?.integer("n") ?? 0)
    }

    public func submissionIDs(instrument: String, version: Int) async throws -> [String] {
        try await database.query("""
            SELECT id FROM submission
            WHERE instrument_id = ? AND version = ?
            ORDER BY received_at
            """, [.text(instrument), .integer(Int64(version))])
            .compactMap { $0.string("id") }
    }

    /// Every answer as it should be read today: the value that arrived, plus the
    /// most recent correction if there is one.
    public func answers(instrument: String, version: Int) async throws -> [ResolvedAnswer] {
        let rows = try await database.query("""
            SELECT a.submission_id AS sid, a.item_id AS iid, a.value_text AS original,
                   c.new_text AS corrected, c.previous_text AS previous,
                   c.reason AS reason, c.corrected_by AS who, c.corrected_at AS at
            FROM answer a
            JOIN submission s ON s.id = a.submission_id
            LEFT JOIN correction c
                   ON c.submission_id = a.submission_id AND c.item_id = a.item_id
                  AND c.corrected_at = (SELECT MAX(corrected_at) FROM correction c2
                                         WHERE c2.submission_id = a.submission_id
                                           AND c2.item_id = a.item_id)
            WHERE s.instrument_id = ? AND s.version = ?
            ORDER BY s.received_at, a.item_id
            """, [.text(instrument), .integer(Int64(version))])

        return rows.compactMap { row in
            guard let sid = row.string("sid"), let iid = row.string("iid"),
                  let original = row.string("original") else { return nil }
            guard let newText = row.string("corrected"),
                  let previous = row.string("previous"),
                  let reason = row.string("reason"),
                  let who = row.string("who") else {
                return ResolvedAnswer(submissionID: sid, itemID: iid, text: original,
                                      corrected: nil)
            }
            let at: Date = if case .double(let seconds) = row["at"] {
                Date(timeIntervalSince1970: seconds)
            } else {
                Date(timeIntervalSince1970: 0)
            }
            return ResolvedAnswer(
                submissionID: sid, itemID: iid, text: newText,
                corrected: Correction(submissionID: sid, itemID: iid,
                                      previousText: previous, newText: newText,
                                      reason: reason, correctedBy: who, correctedAt: at))
        }
    }

    /// The value exactly as it arrived, ignoring any correction — the thing a
    /// correction record is only meaningful against.
    public func rawAnswerText(submission: String, item: String) async throws -> String? {
        try await database.query("""
            SELECT value_text FROM answer WHERE submission_id = ? AND item_id = ?
            """, [.text(submission), .text(item)])
            .first?.string("value_text")
    }

    public func droppedFieldCount() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) AS n FROM dropped_field")
        return Int(rows.first?.integer("n") ?? 0)
    }
}

public enum ResponseStoreError: Error, CustomStringConvertible, Equatable {
    case correctionNeedsReasonAndPerson

    public var description: String {
        switch self {
        case .correctionNeedsReasonAndPerson:
            "การแก้ค่าคำตอบต้องมีเหตุผลและชื่อผู้แก้ — การแก้ที่ไม่มีทั้งสองอย่างแยกไม่ออกจากการแก้ที่หวังว่าไม่มีใครสังเกต"
        }
    }
}
