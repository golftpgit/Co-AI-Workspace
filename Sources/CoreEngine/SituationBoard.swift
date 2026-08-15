import Foundation
import AgentKit
import Knowledge
import Observability

// ─────────────────────────────────────────────────────────────
// Where teams tell each other what they found (§22.5, P16.4).
//
// Two requirements that look like they contradict: §22.2 keeps teams' contexts
// apart so one team's confusion cannot become everybody's, and yet teams have
// to share findings or they repeat each other's work. The resolution is not a
// compromise on isolation — it is being exact about what may be shared.
//
//     shared                                  not shared
//     ──────────────────────────────────────  ────────────────────────────
//     findings that **passed QA**, with       raw transcripts
//       provenance                            another team's context window
//     which team is working on which          half-formed hypotheses,
//       assignment (so nobody repeats it)       unreviewed opinions
//     conflicts still undecided (so two
//       teams do not decide them differently)
//
// **The one rule that keeps this from being worse than having no board**:
// nothing reaches it that has not passed QA. A board that accepts an agent's
// raw opinion turns one model's misunderstanding into "what the organisation
// knows" within a single round — every team then reads it as established, and
// there is no longer anywhere the original claim can be checked against.
//
// It is also **pull, not push** (§22.5): an agent reads the board when it is
// about to start work — "has anybody done this?" — the way `RoleMemory` puts
// lessons in front of a role. A feed that flows into every context would make
// every team's context grow at once, which is the cost §22.2 exists to avoid.
// ─────────────────────────────────────────────────────────────

public struct BoardEntry: Sendable, Equatable {
    public let id: String
    /// Which team put it up. Not decoration: a finding whose author cannot be
    /// named cannot be asked about, and §11.3's provenance rule applies to
    /// knowledge produced inside the run as much as to knowledge from outside.
    public let team: String
    public let assignmentID: String
    public let finding: String
    /// The evidence QA accepted. Carried so a team reading this can weigh it
    /// rather than take it, which is the difference between a board and a
    /// rumour.
    public let evidence: [Evidence]
    public let postedAt: Date

    public init(id: String = UUID().uuidString,
                team: String, assignmentID: String, finding: String,
                evidence: [Evidence], postedAt: Date = Date()) {
        self.id = id
        self.team = team
        self.assignmentID = assignmentID
        self.finding = finding
        self.evidence = evidence
        self.postedAt = postedAt
    }
}

/// Why something was not posted.
public enum BoardRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    case didNotPassQA(assignmentID: String)
    case noEvidence(assignmentID: String)
    case empty

    public var description: String {
        switch self {
        case .didNotPassQA(let id):
            "ใบงาน \(id) ยังไม่ผ่าน QA — ขึ้นกระดานไม่ได้ · "
                + "กระดานที่รับความเห็นที่ยังไม่ตรวจ ทำให้ความเข้าใจผิดของทีมเดียว "
                + "กลายเป็น “สิ่งที่ทั้งองค์กรรู้” ภายในรอบเดียว"
        case .noEvidence(let id):
            "ใบงาน \(id) ไม่มีหลักฐานติดมา — ทีมอื่นจะชั่งน้ำหนักไม่ได้ ได้แต่เชื่อ"
        case .empty: "ไม่มีข้อความข้อค้นพบ"
        }
    }
}

/// One run's board. An actor because several teams post to it at once, and the
/// thing that must not happen is two teams reading a half-written entry.
public actor SituationBoard {
    public let runID: String
    /// The scope this board lives in, so `kb_search` reads it like any other
    /// library rather than through a second retrieval path (§22.5).
    public nonisolated var scope: Scope { .board(runID) }

    private var entries: [BoardEntry] = []
    /// Which team took which assignment, so a second team can see the work is
    /// already spoken for before starting it again.
    private var claims: [String: String] = [:]
    private let spans: (any SpanSink)?
    private let log = AppLog.logger("situation-board")

    public init(runID: String, spans: (any SpanSink)? = nil) {
        self.runID = runID
        self.spans = spans
    }

    /// Posts a finding — **only** for a deliverable that passed review.
    ///
    /// The QA verdict is a parameter rather than something this type infers,
    /// because the reviewer is the thing that decides it (§2.5) and a board
    /// that made its own judgement would be a second, weaker QA.
    @discardableResult
    public func post(finding: String,
                     from team: String,
                     assignment: Assignment,
                     verdict: QAReviewer.Verdict,
                     evidence: [Evidence]) throws -> BoardEntry {
        let finding = finding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finding.isEmpty else { throw BoardRefusal.empty }
        guard verdict.passed else {
            log.info("refused board post for \(assignment.id, privacy: .public) — QA said no")
            throw BoardRefusal.didNotPassQA(assignmentID: assignment.id)
        }
        guard !evidence.isEmpty else {
            throw BoardRefusal.noEvidence(assignmentID: assignment.id)
        }
        let entry = BoardEntry(team: team, assignmentID: assignment.id,
                               finding: finding, evidence: evidence)
        entries.append(entry)
        return entry
    }

    /// Claims an assignment for a team, or reports who has it already.
    ///
    /// - Returns: nil when the claim succeeded; the team that already holds it
    ///   otherwise. Unity of command (§22.1): one assignment, one owner, and a
    ///   second claim is answered rather than silently accepted.
    public func claim(_ assignmentID: String, for team: String) -> String? {
        if let holder = claims[assignmentID], holder != team { return holder }
        claims[assignmentID] = team
        return nil
    }

    /// What a team should read before starting — the pull in §22.5's "pull, not
    /// push". Everything already established about this piece of work, and
    /// nothing else: the board is not a feed of the whole run.
    public func briefing(before assignment: Assignment, for team: String) -> String? {
        let related = entries.filter { $0.assignmentID == assignment.id || overlaps(assignment, $0) }
        let owner = claims[assignment.id]
        var lines: [String] = []
        if let owner, owner != team {
            lines.append("ทีม \(owner) รับใบงานนี้ไปแล้ว — อย่าทำซ้ำ ให้ประสานหรือทำส่วนอื่นแทน")
        }
        for entry in related.prefix(5) {
            lines.append("ทีม \(entry.team) พบแล้วว่า: \(entry.finding)")
        }
        guard !lines.isEmpty else { return nil }
        return (["[กระดานสถานการณ์ของการรันนี้ — ข้อค้นพบที่ผ่าน QA แล้วเท่านั้น]"] + lines)
            .joined(separator: "\n")
    }

    public var all: [BoardEntry] { entries }

    /// Crude on purpose: overlap is decided by the words the two goals share,
    /// and a cleverer measure would be a second retrieval system with its own
    /// failure modes. Getting this wrong shows a team one extra line.
    private func overlaps(_ assignment: Assignment, _ entry: BoardEntry) -> Bool {
        let words = Set(assignment.goal.split(separator: " ").map(String.init))
            .filter { $0.count > 3 }
        guard !words.isEmpty else { return false }
        let found = Set(entry.finding.split(separator: " ").map(String.init))
        return !words.intersection(found).isEmpty
    }
}
