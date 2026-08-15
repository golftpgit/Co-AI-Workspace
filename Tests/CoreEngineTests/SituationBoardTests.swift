import Testing
import Foundation
import AgentKit
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P16.4/P16.6 — the board that cannot amplify a hallucination, and the one
// voice that reaches the user.
// ─────────────────────────────────────────────────────────────

private func assignment(_ id: String, goal: String) -> Assignment {
    Assignment(id: id, role: .researcher, goal: goal,
               acceptanceCriteria: [Criterion(text: "มีหลักฐาน", evidenceRequired: "แหล่งอ้างอิง")],
               deliverableType: "สรุป")
}

private let passed = QAReviewer.Verdict(passed: true, findings: [])
private let failed = QAReviewer.Verdict(passed: false, findings: ["ไม่มีหลักฐานรองรับ"])
private let citation = Evidence(kind: .citation, summary: "แนวทางกระทรวง 2567", passed: true, tier: .t1)

@Suite("The Situation Board (P16.4)")
struct SituationBoardTests {

    /// The rule the whole board rests on. Without it, one model's
    /// misunderstanding becomes "what the organisation knows" in a single
    /// round, and every team afterwards reads it as established.
    @Test("a finding QA rejected never reaches the board")
    func rejectedFindingsAreRefused() async {
        let board = SituationBoard(runID: "run-1")
        await #expect(throws: BoardRefusal.didNotPassQA(assignmentID: "a1")) {
            try await board.post(finding: "เวรดึกทำให้ผิดพลาดเพิ่ม 3 เท่า",
                                 from: "research", assignment: assignment("a1", goal: "หาหลักฐาน"),
                                 verdict: failed, evidence: [citation])
        }
        #expect(await board.all.isEmpty)
        #expect("\(BoardRefusal.didNotPassQA(assignmentID: "a1"))"
                    .contains("ทั้งองค์กรรู้"))
    }

    @Test("a finding with no evidence is refused even when QA passed it")
    func evidenceIsRequired() async {
        // A board entry another team can only believe is a rumour with a
        // provenance field.
        let board = SituationBoard(runID: "run-1")
        await #expect(throws: BoardRefusal.noEvidence(assignmentID: "a1")) {
            try await board.post(finding: "พบความสัมพันธ์", from: "research",
                                 assignment: assignment("a1", goal: "หาหลักฐาน"),
                                 verdict: passed, evidence: [])
        }
    }

    @Test("a finding that passed QA is posted with its evidence and its author")
    func passedFindingsArePosted() async throws {
        let board = SituationBoard(runID: "run-1")
        let entry = try await board.post(
            finding: "แนวทางกระทรวงกำหนดเวรดึกไม่เกินสามคืนติด",
            from: "research", assignment: assignment("a1", goal: "หาแนวทาง"),
            verdict: passed, evidence: [citation])

        #expect(entry.team == "research")
        #expect(entry.evidence.first?.tier == .t1)
        #expect(await board.all.count == 1)
    }

    /// §22.1's unity of command, and the practical half of the board: two teams
    /// given overlapping work, and the second one finds out before spending a
    /// model on it.
    @Test("a second team sees the first has the work, and what it already found")
    func overlappingWorkIsVisible() async throws {
        let board = SituationBoard(runID: "run-1")
        let shared = assignment("a1", goal: "ทบทวนแนวทางเวรดึกของกระทรวง")

        let unclaimed = await board.claim(shared.id, for: "research")
        #expect(unclaimed == nil)
        try await board.post(finding: "แนวทางกระทรวงกำหนดเวรดึกไม่เกินสามคืนติด",
                             from: "research", assignment: shared,
                             verdict: passed, evidence: [citation])

        // The second team asks before starting — pull, not push (§22.5).
        let taken = await board.claim(shared.id, for: "policy")
        #expect(taken == "research")
        let briefing = try #require(await board.briefing(before: shared, for: "policy"))
        #expect(briefing.contains("ทีม research รับใบงานนี้ไปแล้ว"))
        #expect(briefing.contains("ไม่เกินสามคืนติด"))
    }

    @Test("a team asking about unrelated work gets nothing rather than the whole run")
    func briefingIsNotAFeed() async throws {
        // A board that answered every question with everything would grow every
        // team's context at once, which is the cost §22.2 exists to avoid.
        let board = SituationBoard(runID: "run-1")
        try await board.post(finding: "แนวทางกระทรวงกำหนดเวรดึกไม่เกินสามคืนติด",
                             from: "research", assignment: assignment("a1", goal: "หาแนวทาง"),
                             verdict: passed, evidence: [citation])
        let unrelated = await board.briefing(
            before: assignment("a2", goal: "เขียนสคริปต์นำเข้าข้อมูล"), for: "engineering")
        #expect(unrelated == nil)
    }

    @Test("the board lives in its own scope, and it is the run's")
    func boardHasItsOwnScope() async {
        let board = SituationBoard(runID: "run-42")
        #expect(board.scope == .board("run-42"))
        // Round-trips through the storage key like any other scope, so the same
        // stores and the same search read it (§22.5).
        #expect(Scope(storageKey: board.scope.storageKey) == .board("run-42"))
        #expect(board.scope.storageKey == "board/run-42")
    }
}

@Suite("One voice to the user (P16.6)")
struct CommandReportingTests {
    private let reporter = CommandReporter()
    private let start = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("only the incident commander speaks to the user")
    func onlyICSpeaks() {
        #expect(reporter.maySpeakToUser(team: "ic", incidentCommander: "ic"))
        // A sub-team that could reach the user makes the IC's summary a
        // duplicate, and the person is back to reading three streams.
        #expect(reporter.maySpeakToUser(team: "research", incidentCommander: "ic") == false)
    }

    @Test("an escalation goes out immediately, without waiting for the next summary")
    func escalationsCutThrough() {
        let messages = reporter.next(pendingEscalations: ["research"],
                                     summary: "กำลังทบทวนเอกสาร 12 ฉบับ",
                                     lastSentAt: start,
                                     now: start.addingTimeInterval(30))
        #expect(messages.count == 1)
        #expect(messages[0].isUrgent)
        // The summary is held: an escalation arriving alongside routine news
        // reads as routine news.
        #expect(messages[0].text.contains("หยุดรอการตัดสินใจของคน"))
    }

    @Test("two escalations are two messages, not one combined one")
    func escalationsAreNotBatched() {
        let messages = reporter.next(pendingEscalations: ["research", "engineering"],
                                     summary: nil, lastSentAt: start,
                                     now: start.addingTimeInterval(30))
        // Combining them makes the second look like context for the first, and
        // each is a team that has stopped.
        #expect(messages.count == 2)
        #expect(messages.filter(\.isUrgent).count == 2)
    }

    @Test("routine news waits for the summary interval")
    func summariesAreRationed() {
        #expect(reporter.next(pendingEscalations: [], summary: "อ่านไปแล้ว 3 ฉบับ",
                              lastSentAt: start, now: start.addingTimeInterval(60)).isEmpty)
        let due = reporter.next(pendingEscalations: [], summary: "อ่านไปแล้ว 3 ฉบับ",
                                lastSentAt: start, now: start.addingTimeInterval(6 * 60))
        #expect(due.count == 1)
        #expect(due[0].kind == .summary)
    }

    /// A long quiet stretch looks exactly like a crashed run. Saying so, with
    /// the duration, is what tells the two apart.
    @Test("silence past the limit is itself a message, and says how long")
    func silenceIsReported() {
        let messages = reporter.next(pendingEscalations: [], summary: nil,
                                     lastSentAt: start, now: start.addingTimeInterval(25 * 60))
        #expect(messages.count == 1)
        #expect(messages[0].kind == .stillWorking)
        #expect(messages[0].text.contains("25 นาที"))
    }

    @Test("nothing to say and not long enough sends nothing at all")
    func quietRunsAreQuiet() {
        #expect(reporter.next(pendingEscalations: [], summary: nil,
                              lastSentAt: start, now: start.addingTimeInterval(60)).isEmpty)
    }
}
