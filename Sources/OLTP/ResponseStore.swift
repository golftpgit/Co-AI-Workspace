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
    /// The anonymous code this respondent was given, when the study uses them
    /// (§20.7). A code, never an identity — turning one into a person happens in
    /// a different file that this module knows nothing about.
    public let participantCode: String?
    public let answers: [StoredAnswer]
    /// Field names that arrived and are not in the instrument. Written down, not
    /// stored as data (§20.7 invariant 2).
    public let droppedFields: [String]
    public let receivedAt: Date

    public init(id: String, instrumentID: String, version: Int, waveID: String,
                consentDigest: String, participantCode: String? = nil,
                answers: [StoredAnswer],
                droppedFields: [String] = [], receivedAt: Date = Date()) {
        self.id = id
        self.instrumentID = instrumentID
        self.version = version
        self.waveID = waveID
        self.consentDigest = consentDigest
        self.participantCode = participantCode
        self.answers = answers
        self.droppedFields = droppedFields
        self.receivedAt = receivedAt
    }
}

/// A round of collection as it stands on disk (§20.7).
public struct WaveRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let openedAt: Date
    public let closedAt: Date?
    public let submissions: Int

    public var isOpen: Bool { closedAt == nil }
}

/// One respondent's submission, without its answers — enough to head a row.
public struct SubmissionRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let waveID: String
    public let receivedAt: Date
    public let consentDigest: String
    public let participantCode: String?
}

/// A questionnaire somebody started and has not finished (§20.7's SessionStore).
///
/// Not a submission: it has no consent digest and no id in the answer tables,
/// because a half-filled form is not an answer to anything yet. It exists so a
/// nurse interrupted by a patient can come back after their shift instead of
/// starting again — which is a response-rate problem before it is a feature.
public struct Draft: Sendable, Equatable, Identifiable {
    /// The only thing that identifies it. Long and random because it is a bearer
    /// credential for somebody's partial answers, living in a URL they keep.
    public let token: String
    public let instrumentID: String
    public let version: Int
    public let waveID: String
    public let participantCode: String?
    /// The form fields as they stood, encoded the way the form sends them.
    public let fields: String
    public let updatedAt: Date

    public var id: String { token }

    public init(token: String, instrumentID: String, version: Int, waveID: String,
                participantCode: String?, fields: String, updatedAt: Date = Date()) {
        self.token = token
        self.instrumentID = instrumentID
        self.version = version
        self.waveID = waveID
        self.participantCode = participantCode
        self.fields = fields
        self.updatedAt = updatedAt
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
        try await addMissingColumns(database)
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
        // A round of collection, kept rather than remembered. Closing a round
        // used to live only in the running server: quit the app and the round it
        // had closed came back open, which turns "we stopped collecting on the
        // 14th" into something nobody can show.
        """
        CREATE TABLE IF NOT EXISTS wave (
            id TEXT PRIMARY KEY,
            instrument_id TEXT NOT NULL,
            version INTEGER NOT NULL,
            opened_at REAL NOT NULL,
            closed_at REAL
        )
        """,
        "CREATE INDEX IF NOT EXISTS wave_instrument ON wave (instrument_id, version)",
        // Partial answers, kept only while their round is open (§20.7).
        """
        CREATE TABLE IF NOT EXISTS draft (
            token TEXT PRIMARY KEY,
            instrument_id TEXT NOT NULL,
            version INTEGER NOT NULL,
            wave_id TEXT NOT NULL,
            participant_code TEXT,
            fields TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS draft_wave ON draft (wave_id)",
    ]

    // MARK: - drafts (§20.7)

    /// Saves or replaces a draft. Replaces, because a person continuing their
    /// own form is not two drafts.
    public func save(_ draft: Draft) async throws {
        try await database.execute("""
            INSERT INTO draft (token, instrument_id, version, wave_id,
                               participant_code, fields, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(token) DO UPDATE SET
                fields = excluded.fields, updated_at = excluded.updated_at
            """,
            [.text(draft.token), .text(draft.instrumentID), .integer(Int64(draft.version)),
             .text(draft.waveID),
             draft.participantCode.map { SQLiteValue.text($0) } ?? .null,
             .text(draft.fields), .double(draft.updatedAt.timeIntervalSince1970)])
    }

    public func draft(token: String) async throws -> Draft? {
        try await database.query("""
            SELECT token, instrument_id, version, wave_id, participant_code, fields, updated_at
            FROM draft WHERE token = ?
            """, [.text(token)])
            .compactMap { row -> Draft? in
                guard let token = row.string("token"),
                      let instrument = row.string("instrument_id"),
                      let wave = row.string("wave_id"),
                      let fields = row.string("fields"),
                      case .double(let updated)? = row["updated_at"] else { return nil }
                return Draft(token: token, instrumentID: instrument,
                             version: Int(row.integer("version") ?? 0), waveID: wave,
                             participantCode: row.string("participant_code"),
                             fields: fields,
                             updatedAt: Date(timeIntervalSince1970: updated))
            }.first
    }

    /// Drops a draft — after it is submitted, or when its round closes.
    public func removeDraft(token: String) async throws {
        try await database.execute("DELETE FROM draft WHERE token = ?", [.text(token)])
    }

    /// Everything left half-finished when a round ended.
    ///
    /// Deleted rather than kept: a draft is personal data collected under a
    /// consent that covered a round which is now over, and keeping partial
    /// answers nobody will ever submit is holding data with no purpose left
    /// (§20.5).
    @discardableResult
    public func discardDrafts(wave: String) async throws -> Int {
        try await database.execute("DELETE FROM draft WHERE wave_id = ?", [.text(wave)])
    }

    public func draftCount(wave: String) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) AS n FROM draft WHERE wave_id = ?", [.text(wave)])
        return Int(rows.first?.integer("n") ?? 0)
    }

    /// Columns added after the first version shipped. `CREATE TABLE IF NOT
    /// EXISTS` does nothing to a table that already exists, so a database made
    /// before this column existed would silently lack it — and the failure would
    /// be a wave that cannot be linked, months later.
    static let addedColumns = [("submission", "participant_code", "TEXT")]

    private static func addMissingColumns(_ database: SQLiteDatabase) async throws {
        for (table, column, type) in addedColumns {
            let existing = try await database.query("PRAGMA table_info(\(table))")
                .compactMap { $0.string("name") }
            guard !existing.contains(column) else { continue }
            try await database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        }
    }

    // MARK: - rounds (§20.7)

    /// Writes down that a round opened.
    public func openWave(id: String, instrument: String, version: Int,
                         at date: Date = Date()) async throws {
        try await database.execute("""
            INSERT INTO wave (id, instrument_id, version, opened_at, closed_at)
            VALUES (?, ?, ?, ?, NULL)
            """,
            [.text(id), .text(instrument), .integer(Int64(version)),
             .double(date.timeIntervalSince1970)])
    }

    /// Closes a round, once. `closed_at IS NULL` in the WHERE clause is the whole
    /// rule: a round has one closing date, and re-closing must not move it —
    /// "when did collection stop" has to keep the same answer.
    public func closeWave(id: String, at date: Date = Date()) async throws {
        try await database.execute("""
            UPDATE wave SET closed_at = ? WHERE id = ? AND closed_at IS NULL
            """, [.double(date.timeIntervalSince1970), .text(id)])
    }

    /// Every round for a version, newest first, with how many answers each got.
    public func waves(instrument: String, version: Int) async throws -> [WaveRecord] {
        try await database.query("""
            SELECT w.id AS id, w.opened_at AS opened, w.closed_at AS closed,
                   (SELECT COUNT(*) FROM submission s WHERE s.wave_id = w.id) AS answers
            FROM wave w
            WHERE w.instrument_id = ? AND w.version = ?
            ORDER BY w.opened_at DESC
            """, [.text(instrument), .integer(Int64(version))])
            .compactMap { row in
                guard let id = row.string("id"),
                      case .double(let opened)? = row["opened"] else { return nil }
                var closed: Date?
                if case .double(let seconds)? = row["closed"] {
                    closed = Date(timeIntervalSince1970: seconds)
                }
                return WaveRecord(id: id,
                                  openedAt: Date(timeIntervalSince1970: opened),
                                  closedAt: closed,
                                  submissions: Int(row.integer("answers") ?? 0))
            }
    }

    /// Whether this round is still taking answers. Read from the row rather than
    /// from whatever the server happens to remember, so a restart cannot reopen
    /// what somebody closed.
    public func waveIsOpen(id: String) async throws -> Bool {
        let rows = try await database.query(
            "SELECT closed_at FROM wave WHERE id = ?", [.text(id)])
        guard let row = rows.first else { return false }
        if case .null = row["closed_at"] ?? .null { return true }
        return false
    }

    // MARK: - writing

    /// Appends one submission. Whole or not at all.
    public func append(_ submission: Submission) async throws {
        let stamp = submission.receivedAt.timeIntervalSince1970
        var statements: [(sql: String, bindings: [SQLiteValue])] = [(
            """
            INSERT INTO submission (id, instrument_id, version, wave_id,
                                    consent_digest, participant_code, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(submission.id), .text(submission.instrumentID),
             .integer(Int64(submission.version)), .text(submission.waveID),
             .text(submission.consentDigest),
             submission.participantCode.map { SQLiteValue.text($0) } ?? .null,
             .double(stamp)])]

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

    /// Whether this project ever received an answer from anybody, across every
    /// instrument and wave (§20.5, P11.10).
    ///
    /// Asked at the closing gate, where the question is not "how many" but
    /// "does the promise made to participants apply to this project at all".
    public func hasAnySubmission() async throws -> Bool {
        let rows = try await database.query("SELECT COUNT(*) AS n FROM submission", [])
        return Int(rows.first?.integer("n") ?? 0) > 0
    }

    public func submissionIDs(instrument: String, version: Int) async throws -> [String] {
        try await database.query("""
            SELECT id FROM submission
            WHERE instrument_id = ? AND version = ?
            ORDER BY received_at
            """, [.text(instrument), .integer(Int64(version))])
            .compactMap { $0.string("id") }
    }

    /// The submissions themselves, in the order they arrived.
    public func submissions(instrument: String, version: Int) async throws -> [SubmissionRecord] {
        try await database.query("""
            SELECT id, wave_id, received_at, consent_digest, participant_code FROM submission
            WHERE instrument_id = ? AND version = ?
            ORDER BY received_at
            """, [.text(instrument), .integer(Int64(version))])
            .compactMap { row in
                guard let id = row.string("id"), let wave = row.string("wave_id"),
                      case .double(let received)? = row["received_at"] else { return nil }
                return SubmissionRecord(id: id, waveID: wave,
                                        receivedAt: Date(timeIntervalSince1970: received),
                                        consentDigest: row.string("consent_digest") ?? "",
                                        participantCode: row.string("participant_code"))
            }
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
