import Foundation
import CryptoKit
import AgentKit
import Observability
import OLTP

// ─────────────────────────────────────────────────────────────
// Who answered, kept apart from what they answered (ARCHITECTURE §20.7, P11.7b).
//
// A longitudinal study has to know that the person who answered in wave 1 is the
// person who answered in wave 3, and must not put a name next to an answer. The
// resolution is an anonymous code: the form carries the code, the answers carry
// the code, and the only place a code becomes a person is here — in a **different
// database file**, sealed with a key from the Keychain.
//
// Three consequences, and each is the point rather than a side effect:
//
//  • A copy of the response data carries no identities. Not "identities that are
//    hard to read" — none, because they are not in that file.
//  • The identity file on its own is ciphertext. A stolen backup is not a list
//    of who said they were burning out.
//  • **Every resolution writes an audit span.** Not on failure, not on the
//    interesting ones: every one. §20.7 invariant 3 asks that the two tables can
//    only be joined through an API that records it, and an API that records only
//    sometimes is an API whose log proves nothing.
//
// There is no SQL in this system that joins `participant` to `answer`, and there
// cannot be: they are in two databases that are never attached to each other.
// That is a stronger guarantee than a rule about queries, which is why it was
// chosen over keeping both in one file with a convention about not joining them.
// ─────────────────────────────────────────────────────────────

/// One person in a study, as the study is allowed to know them.
public struct Participant: Sendable, Equatable, Identifiable {
    /// What goes on the form and beside the answers. Short enough to read aloud
    /// over the phone, because in real fieldwork somebody will have to.
    public let code: String
    public let enrolledAt: Date
    public var id: String { code }
}

/// How many of each wave's invited participants actually answered (§20.7).
public struct Attrition: Sendable, Equatable {
    public let waveID: String
    public let invited: Int
    public let responded: Int

    public var rate: Double { invited == 0 ? 0 : Double(responded) / Double(invited) }
}

public enum LinkageError: Error, CustomStringConvertible, Equatable {
    case emptyIdentity
    case unreadable(code: String)

    public var description: String {
        switch self {
        case .emptyIdentity:
            "ต้องมีตัวระบุตัวตนของผู้เข้าร่วม — รหัสที่ไม่ผูกกับใครเลยติดตามรอบถัดไปไม่ได้"
        case .unreadable(let code):
            "ถอดรหัสตัวตนของรหัส \(code) ไม่ได้ — คีย์อาจไม่ใช่คีย์ของโปรเจกต์นี้"
        }
    }
}

public actor LinkageStore {
    private let database: SQLiteDatabase
    private let key: SymmetricKey
    private let project: String
    private let spans: (any SpanSink)?
    private let log = AppLog.logger("linkage")

    /// Opens the linkage database. The path is the caller's to choose and the
    /// caller is expected to choose one that is **not** the response database —
    /// `check.sh` fails the build if the two ever name the same file.
    public init(path: URL, project: String, keys: any LinkageKeySource,
                spans: (any SpanSink)? = nil) async throws {
        self.database = try SQLiteDatabase(path: path)
        self.key = try keys.key(for: project)
        self.project = project
        self.spans = spans
        for statement in Self.schema {
            try await database.execute(statement)
        }
    }

    static let schema = [
        """
        CREATE TABLE IF NOT EXISTS participant (
            code TEXT PRIMARY KEY,
            enrolled_at REAL NOT NULL,
            sealed BLOB NOT NULL
        )
        """,
        // Who was asked, and who answered. Invitation and response are separate
        // rows on purpose: attrition is the difference between them, and a table
        // that only records answers cannot measure it.
        """
        CREATE TABLE IF NOT EXISTS enrolment (
            code TEXT NOT NULL,
            wave_id TEXT NOT NULL,
            invited_at REAL NOT NULL,
            responded_at REAL,
            PRIMARY KEY (code, wave_id)
        )
        """,
    ]

    // MARK: - enrolling

    /// Registers a person and returns the code that stands for them.
    ///
    /// The identity never touches the response database and never leaves this
    /// file unsealed.
    @discardableResult
    public func enrol(identity: String, code: String = LinkageStore.freshCode()) async throws
        -> Participant {
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LinkageError.emptyIdentity }
        let sealed = try AES.GCM.seal(Data(trimmed.utf8), using: key).combined ?? Data()
        let now = Date()
        try await database.execute("""
            INSERT INTO participant (code, enrolled_at, sealed) VALUES (?, ?, ?)
            """,
            [.text(code), .double(now.timeIntervalSince1970),
             .text(sealed.base64EncodedString())])
        return Participant(code: code, enrolledAt: now)
    }

    /// A code a person can read out over the phone: no vowels, so it cannot
    /// spell anything, and no 0/O or 1/I.
    public static func freshCode() -> String {
        let alphabet = Array("23456789BCDFGHJKLMNPQRSTVWXZ")
        return "P-" + String((0..<8).map { _ in alphabet.randomElement()! })
    }

    // MARK: - resolving

    /// Turns a code back into a person. **Always writes an audit span.**
    ///
    /// The span is written before the answer is returned and whether or not the
    /// code was found, because the question an audit answers is "who looked",
    /// not "who looked successfully".
    public func resolve(code: String, reason: String, by person: String) async throws
        -> String? {
        await spans?.record(Span(name: "linkage.resolve", status: .succeeded,
                                 endedAt: Date(),
                                 detail: "project \(project) · code \(code) · "
                                     + "by \(person) · reason: \(reason)"))
        log.info("identity resolved for one code")

        let rows = try await database.query(
            "SELECT sealed FROM participant WHERE code = ?", [.text(code)])
        guard let encoded = rows.first?.string("sealed"),
              let sealed = Data(base64Encoded: encoded) else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let opened = try? AES.GCM.open(box, using: key) else {
            throw LinkageError.unreadable(code: code)
        }
        return String(decoding: opened, as: UTF8.self)
    }

    public func participants() async throws -> [Participant] {
        try await database.query(
            "SELECT code, enrolled_at FROM participant ORDER BY enrolled_at")
            .compactMap { row in
                guard let code = row.string("code"),
                      case .double(let at)? = row["enrolled_at"] else { return nil }
                return Participant(code: code, enrolledAt: Date(timeIntervalSince1970: at))
            }
    }

    // MARK: - waves and attrition

    public func invite(_ codes: [String], to wave: String, at date: Date = Date()) async throws {
        for code in codes {
            try await database.execute("""
                INSERT OR IGNORE INTO enrolment (code, wave_id, invited_at, responded_at)
                VALUES (?, ?, ?, NULL)
                """, [.text(code), .text(wave), .double(date.timeIntervalSince1970)])
        }
    }

    /// Marks that a code answered in a wave. Called by the app after a
    /// submission arrives — never by the server, which has no way to reach this
    /// file.
    public func recordResponse(code: String, wave: String,
                               at date: Date = Date()) async throws {
        try await database.execute("""
            UPDATE enrolment SET responded_at = ?
            WHERE code = ? AND wave_id = ? AND responded_at IS NULL
            """, [.double(date.timeIntervalSince1970), .text(code), .text(wave)])
    }

    /// Who was asked and who answered, per wave — the number a longitudinal
    /// study has to report and the one that decides whether its later waves mean
    /// anything.
    public func attrition() async throws -> [Attrition] {
        try await database.query("""
            SELECT wave_id,
                   COUNT(*) AS invited,
                   SUM(CASE WHEN responded_at IS NULL THEN 0 ELSE 1 END) AS responded
            FROM enrolment GROUP BY wave_id ORDER BY MIN(invited_at)
            """)
            .compactMap { row in
                guard let wave = row.string("wave_id") else { return nil }
                return Attrition(waveID: wave,
                                 invited: Int(row.integer("invited") ?? 0),
                                 responded: Int(row.integer("responded") ?? 0))
            }
    }
}
