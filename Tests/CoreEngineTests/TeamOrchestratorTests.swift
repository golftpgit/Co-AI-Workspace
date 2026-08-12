import Testing
import Foundation
import AgentKit
import LLMProviders
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P4.2–P4.5: the lead assigns, reviews on evidence, sends work back with
// reasons, and stops by asking a person rather than by looping.
// ─────────────────────────────────────────────────────────────

/// A specialist that returns exactly what a test needs it to, in sequence, so
/// the loop rather than the model is under test.
private actor ScriptedSpecialist: Specialist {
    nonisolated let role: Role
    nonisolated let definitionOfDone: [Criterion]
    private var replies: [Deliverable]
    private(set) var received: [Assignment] = []

    init(role: Role, replies: [Deliverable],
         definitionOfDone: [Criterion] = [Criterion(text: "x", evidenceRequired: "y")]) {
        self.role = role
        self.replies = replies
        self.definitionOfDone = definitionOfDone
    }

    func execute(_ assignment: Assignment) async throws -> Deliverable {
        received.append(assignment)
        guard !replies.isEmpty else {
            throw SpecialistError.modelUnavailable("script exhausted")
        }
        let reply = replies.removeFirst()
        return Deliverable(assignmentID: assignment.id, summary: reply.summary,
                           artifacts: reply.artifacts, evidence: reply.evidence)
    }

    func assignmentsSeen() -> [Assignment] { received }
}

/// Collects the lead's events. An actor because the emit callback is
/// `@Sendable` — the orchestrator may call it from anywhere.
private actor EventLog {
    private(set) var events: [TeamEvent] = []
    func record(_ event: TeamEvent) { events.append(event) }

    var escalations: [(attempts: Int, reasons: [String])] {
        events.compactMap {
            if case .escalated(_, let attempts, let reasons) = $0 { return (attempts, reasons) }
            return nil
        }
    }
    var failures: [String] {
        events.compactMap { if case .failed(let message) = $0 { return message }; return nil }
    }
    var passedReviews: Int {
        events.count { if case .reviewed(_, let passed, _) = $0 { return passed }; return false }
    }
}

private func deliverable(_ summary: String, evidence: [Evidence] = []) -> Deliverable {
    Deliverable(assignmentID: "", summary: summary, evidence: evidence)
}

private let passingBuild = Evidence(kind: .commandExit, summary: "exit code: 0", passed: true)
private let failingBuild = Evidence(kind: .commandExit, summary: "exit code: 1", passed: false)

private func engineeringPlan() -> TeamPlan {
    TeamPlan(goal: "แก้เทสให้ผ่าน", assignments: [
        Assignment(id: "a1", role: .engineer, goal: "แก้เทส",
                   acceptanceCriteria: [Criterion(text: "เทสผ่าน",
                                                  evidenceRequired: "exit code 0")],
                   deliverableType: "โค้ด"),
    ])
}

private func orchestrator(_ specialists: [Role: any Specialist],
                          retryCap: Int = 3, maxFanOut: Int = 4) -> TeamOrchestrator {
    TeamOrchestrator(router: ModelRouter(executors: []), specialists: specialists,
                     maxFanOut: maxFanOut, retryCap: retryCap)
}

@Suite("Team orchestrator")
struct TeamOrchestratorTests {
    @Test("work that meets the standard is accepted once")
    func passingWorkIsAccepted() async {
        let engineer = ScriptedSpecialist(role: .engineer, replies: [
            deliverable("แก้แล้ว", evidence: [passingBuild]),
        ])
        let log = EventLog()
        let delivered = await orchestrator([.engineer: engineer])
            .run(goal: "แก้เทส", plan: engineeringPlan()) { event in
                Task { await log.record(event) }
            }

        #expect(delivered.count == 1)
        #expect(await engineer.assignmentsSeen().count == 1, "reworked despite passing")
    }

    @Test("a summary claiming success does not pass without evidence")
    func claimedSuccessIsNotEnough() async {
        // The exact failure §2.5 exists for: the model says it is done.
        let engineer = ScriptedSpecialist(role: .engineer, replies: [
            deliverable("เรียบร้อย ทุกอย่างผ่านแล้ว"),
            deliverable("ผ่านแล้วจริงๆ"),
            deliverable("ยืนยันว่าผ่าน"),
        ])
        let team = orchestrator([.engineer: engineer])
        let delivered = await team.run(goal: "แก้เทส", plan: engineeringPlan())

        #expect(delivered.isEmpty)
        let entry = await team.entries.first
        #expect(entry?.passed == false)
        #expect(entry?.attempts == 3, "did not use every attempt before giving up")
        #expect(entry?.findings.contains { $0.contains("build/test") } == true)
    }

    @Test("rework carries the reviewer's reasons into the next attempt")
    func reworkExplainsItself() async {
        let engineer = ScriptedSpecialist(role: .engineer, replies: [
            deliverable("ลองแก้", evidence: [failingBuild]),
            deliverable("แก้ใหม่", evidence: [passingBuild]),
        ])
        _ = await orchestrator([.engineer: engineer])
            .run(goal: "แก้เทส", plan: engineeringPlan())

        let seen = await engineer.assignmentsSeen()
        #expect(seen.count == 2)
        // Sending the same brief back unchanged is how a loop repeats itself.
        #expect(seen[1].goal.contains("ไม่ผ่านการตรวจ"))
        #expect(seen[1].goal.contains("exit code"))
    }

    @Test("the loop stops at the cap and asks a person")
    func retriesAreBounded() async {
        let engineer = ScriptedSpecialist(role: .engineer, replies: [
            deliverable("รอบ 1", evidence: [failingBuild]),
            deliverable("รอบ 2", evidence: [failingBuild]),
            deliverable("รอบ 3", evidence: [failingBuild]),
            deliverable("รอบ 4", evidence: [failingBuild]),
        ])
        let log = EventLog()
        let team = orchestrator([.engineer: engineer], retryCap: 3)
        _ = await team.run(goal: "แก้เทส", plan: engineeringPlan()) { event in
            Task { await log.record(event) }
        }

        #expect(await engineer.assignmentsSeen().count == 3, "the cap did not hold")
        #expect(await team.entries.first?.passed == false)
    }

    @Test("a plan that splits the engineer is refused before anyone starts")
    func engineerIsNeverFannedOut() async {
        // §2.4: cutting a code change into summaries makes the pieces
        // contradict each other.
        let plan = TeamPlan(goal: "แก้ทั้งระบบ", assignments: [
            Assignment(id: "e1", role: .engineer, goal: "แก้ส่วนหน้า",
                       acceptanceCriteria: [Criterion(text: "ผ่าน", evidenceRequired: "exit 0")],
                       deliverableType: "โค้ด"),
            Assignment(id: "e2", role: .engineer, goal: "แก้ส่วนหลัง",
                       acceptanceCriteria: [Criterion(text: "ผ่าน", evidenceRequired: "exit 0")],
                       deliverableType: "โค้ด"),
        ])
        let engineer = ScriptedSpecialist(role: .engineer, replies: [deliverable("x")])

        let log = EventLog()
        _ = await orchestrator([.engineer: engineer])
            .run(goal: "แก้ทั้งระบบ", plan: plan) { event in
                Task { await log.record(event) }
            }
        // Give the emitted events a moment to land in the actor.
        try? await Task.sleep(for: .milliseconds(50))

        let failures = await log.failures
        #expect(failures.contains { $0.contains("§2.4") }, "got \(failures)")
        #expect(await engineer.assignmentsSeen().isEmpty, "work started before the check")
    }

    @Test("a plan wider than the cap is refused")
    func fanOutIsCapped() async {
        let plan = TeamPlan(goal: "ค้นทุกอย่าง", assignments: (1...5).map { index in
            Assignment(id: "r\(index)", role: .researcher, goal: "ค้นเรื่อง \(index)",
                       acceptanceCriteria: [Criterion(text: "มีแหล่ง", evidenceRequired: "citation")],
                       deliverableType: "สรุป")
        })
        let log = EventLog()
        _ = await orchestrator([.researcher: ScriptedSpecialist(role: .researcher, replies: [])],
                               maxFanOut: 4)
            .run(goal: "ค้นทุกอย่าง", plan: plan) { event in
                Task { await log.record(event) }
            }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await log.failures.contains { $0.contains("เกินเพดาน") })
    }

    @Test("the ledger says who did what and how it went")
    func ledgerRecordsEverything() async {
        let engineer = ScriptedSpecialist(role: .engineer, replies: [
            deliverable("รอบแรก", evidence: [failingBuild]),
            deliverable("รอบสอง", evidence: [passingBuild]),
        ])
        let team = orchestrator([.engineer: engineer])
        _ = await team.run(goal: "แก้เทส", plan: engineeringPlan())

        let entries = await team.entries
        #expect(entries.count == 1)
        #expect(entries.first?.attempts == 2)
        #expect(entries.first?.passed == true)
        #expect(entries.first?.deliverable?.summary == "รอบสอง")
    }

    @Test("a researcher needs two sources that were actually read")
    func researcherStandardIsEnforced() async {
        let reviewer = QAReviewer()
        let assignment = Assignment(
            id: "r1", role: .researcher, goal: "ค้น",
            acceptanceCriteria: [Criterion(text: "2 แหล่ง", evidenceRequired: "citation")],
            deliverableType: "สรุป")

        let oneSource = Deliverable(assignmentID: "r1", summary: "พบแล้ว", evidence: [
            Evidence(kind: .citation, summary: "https://who.int/x", passed: true),
        ])
        #expect(reviewer.review(oneSource, against: assignment, standard: []).passed == false)

        let readTwo = Deliverable(assignmentID: "r1", summary: "พบแล้ว", evidence: [
            Evidence(kind: .citation, summary: "https://who.int/x", passed: true),
            Evidence(kind: .citation, summary: "https://pubmed.ncbi.nlm.nih.gov/1/", passed: true),
        ])
        #expect(reviewer.review(readTwo, against: assignment, standard: []).passed)
    }

    @Test("a specialist that throws is retried, not treated as a failure to review")
    func throwingSpecialistIsRetried() async {
        // An empty script throws; the second attempt has nothing either, so
        // this ends in escalation rather than in a deliverable nobody made.
        let researcher = ScriptedSpecialist(role: .researcher, replies: [])
        let team = orchestrator([.researcher: researcher], retryCap: 2)
        _ = await team.run(goal: "ค้น", plan: TeamPlan(goal: "ค้น", assignments: [
            Assignment(id: "r1", role: .researcher, goal: "ค้น",
                       acceptanceCriteria: [Criterion(text: "มีแหล่ง",
                                                      evidenceRequired: "citation")],
                       deliverableType: "สรุป"),
        ]))
        #expect(await team.entries.first?.attempts == 2)
        #expect(await team.entries.first?.passed == false)
    }
}

// ─────────────────────────────────────────────────────────────
// P4.7's last piece: what a person can do to one assignment.
// ─────────────────────────────────────────────────────────────

@Suite("Rework and cancel, one assignment at a time")
struct SingleAssignmentControlTests {

    /// The note is not decoration: it goes to the specialist through the same
    /// channel QA's findings use, so "do it again" always comes with what was
    /// wrong with it.
    @Test("a human rework re-runs the work with the reason attached")
    func reworkCarriesTheReason() async throws {
        let specialist = RecordingSpecialist(role: .writer)
        let team = TeamOrchestrator(router: ModelRouter(executors: []),
                                    specialists: [.writer: specialist])
        let assignment = Assignment(id: "as_1", role: .writer, goal: "เขียนบทสรุป",
                                    acceptanceCriteria: [Criterion(text: "มีข้อสรุป",
                                                                   evidenceRequired: "สรุปหนึ่งย่อหน้า")],
                                    deliverableType: "manuscript")

        let seenEvents = EventBox()
        _ = await team.rework(assignment, note: "ย่อหน้าแรกยังไม่ตอบคำถาม") { event in
            if case .rework(_, _, let reasons) = event { seenEvents.add(reasons.joined()) }
        }

        #expect(seenEvents.all.contains("ย่อหน้าแรกยังไม่ตอบคำถาม"))
        let seen = await specialist.lastGoal
        #expect(seen?.contains("ย่อหน้าแรกยังไม่ตอบคำถาม") == true,
                "the reason never reached the specialist: \(seen ?? "nil")")
    }

    @Test("a reworked assignment keeps counting attempts, not starting over")
    func reworkContinuesTheAttemptCount() async throws {
        let specialist = RecordingSpecialist(role: .writer)
        let team = TeamOrchestrator(router: ModelRouter(executors: []),
                                    specialists: [.writer: specialist])
        let assignment = Assignment(id: "as_2", role: .writer, goal: "เขียน",
                                    acceptanceCriteria: [Criterion(text: "ok", evidenceRequired: "ok")],
                                    deliverableType: "manuscript")

        _ = await team.rework(assignment, note: "รอบแรก")
        _ = await team.rework(assignment, note: "รอบสอง")

        let entry = await team.entries.first { $0.assignment.id == "as_2" }
        // Two human rounds on top of nothing is two, not one twice: a rework
        // that reset the counter would hand the work a fresh retry budget.
        #expect(entry?.attempts == 2)
    }

    /// Cancelling is a decision, and §2.5's whole point is that a decision is
    /// not overturned by a machine a moment later.
    @Test("a cancelled assignment is recorded and never resumed")
    func cancelIsRecordedAndFinal() async throws {
        let specialist = RecordingSpecialist(role: .engineer)
        let team = TeamOrchestrator(router: ModelRouter(executors: []),
                                    specialists: [.engineer: specialist])
        let assignment = Assignment(id: "as_3", role: .engineer, goal: "แก้บั๊ก",
                                    acceptanceCriteria: [Criterion(text: "ok", evidenceRequired: "ok")],
                                    deliverableType: "patch")

        let seenEvents = EventBox()
        await team.cancel("as_3", assignment: assignment, reason: "ทำเองแล้ว") { event in
            if case .cancelled(_, let reason) = event { seenEvents.add(reason) }
        }

        #expect(seenEvents.all == ["ทำเองแล้ว"])
        let entry = await team.entries.first { $0.assignment.id == "as_3" }
        #expect(entry?.cancelled == true)
        #expect(entry?.passed == false)
        // And it is not an escalation: those two look the same on a
        // `!passed` filter and mean opposite things to run-until-done.
        #expect(entry?.needsHuman == false)
    }

    @Test("asking for a rework takes the work back off the human pile")
    func reworkClearsEscalation() async throws {
        let specialist = RecordingSpecialist(role: .analyst)
        let team = TeamOrchestrator(router: ModelRouter(executors: []),
                                    specialists: [.analyst: specialist])
        let assignment = Assignment(id: "as_4", role: .analyst, goal: "วิเคราะห์",
                                    acceptanceCriteria: [Criterion(text: "ok", evidenceRequired: "ok")],
                                    deliverableType: "analysis")

        await team.cancel("as_4", assignment: assignment)
        _ = await team.rework(assignment, note: "ลองใหม่")

        let entry = await team.entries.first { $0.assignment.id == "as_4" }
        #expect(entry?.cancelled == false)
        #expect(entry?.needsHuman == false)
    }
}

/// Remembers the goal it was handed, which is where the rework note has to
/// arrive if the specialist is to act on it.
private actor RecordingSpecialist: Specialist {
    nonisolated let role: Role
    nonisolated var definitionOfDone: [Criterion] { [] }
    private(set) var lastGoal: String?

    init(role: Role) { self.role = role }

    func execute(_ assignment: Assignment) async throws -> Deliverable {
        lastGoal = assignment.goal
        return Deliverable(assignmentID: assignment.id, summary: "เสร็จแล้ว",
                           evidence: [Evidence(kind: .citation,
                                               summary: "https://example.org/x", passed: true)])
    }
}


/// The orchestrator emits from its own actor, so a test collecting events
/// needs a lock rather than a captured `var`.
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
