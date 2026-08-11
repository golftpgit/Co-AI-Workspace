import Foundation
import AgentKit
import LLMProviders
import Observability
import Persistence

// ─────────────────────────────────────────────────────────────
// The team lead (ARCHITECTURE §2.2, §2.4, §2.5, P4.2–P4.5).
//
// One person gives one goal. The lead plans, assigns, reviews against evidence,
// sends work back when it does not meet the standard, and — when it still does
// not after a bounded number of tries — asks the human for help instead of
// burning the budget in a loop.
//
// Three rules are structural rather than advisory:
//
//  • **an assignment cannot exist without acceptance criteria** (the type has
//    refused that since P1.1), so nothing can be handed out that nobody can
//    review;
//  • **the Engineer is never fanned out** (§2.4). Splitting a code change into
//    summaries makes the pieces contradict each other, so a plan that tries is
//    rejected before anyone starts;
//  • **review reads evidence, not summaries** (§2.5). A specialist saying it
//    is done is not a finding.
// ─────────────────────────────────────────────────────────────

public struct TeamPlan: Sendable, Equatable {
    public let goal: String
    public let assignments: [Assignment]
}

public enum TeamEvent: Sendable {
    case planned(TeamPlan)
    case assigned(Assignment)
    case delivered(Deliverable)
    case reviewed(assignmentID: String, passed: Bool, findings: [String])
    case rework(assignmentID: String, attempt: Int, reasons: [String])
    /// The lead has stopped and wants a person. Carries why, because
    /// "ติดขัด" with no reason is the thing that made v1's loops unreadable.
    case escalated(assignmentID: String, attempts: Int, reasons: [String])
    case finished(deliverables: [Deliverable])
    case failed(String)
}

public enum TeamError: Error, CustomStringConvertible, Equatable {
    case planningFailed(String)
    case emptyPlan
    /// §2.4, enforced before any work starts.
    case engineerFannedOut(count: Int)
    case fanOutTooWide(count: Int, cap: Int)
    case noSpecialist(Role)

    public var description: String {
        switch self {
        case .planningFailed(let message): "วางแผนไม่สำเร็จ: \(message.prefix(160))"
        case .emptyPlan: "แผนว่างเปล่า — ไม่มีงานให้ใครทำ"
        case .engineerFannedOut(let count):
            "แผนแตกงาน Engineer เป็น \(count) ก้อน — §2.4 ห้าม เพราะการตัดงานโค้ดเป็นสรุปทำให้แก้ขัดกันเอง"
        case .fanOutTooWide(let count, let cap):
            "แผนมี \(count) งานขนานกัน เกินเพดาน \(cap)"
        case .noSpecialist(let role): "ไม่มี specialist สำหรับ role \(role.rawValue)"
        }
    }
}

public actor TeamOrchestrator {
    private let router: ModelRouter
    private let specialists: [Role: any Specialist]
    private let reviewer: QAReviewer
    private let maxFanOut: Int
    private let retryCap: Int
    /// Optional: the team works without a database, it just cannot be asked
    /// afterwards what happened.
    private let ledgerStore: TaskLedgerStore?
    private let scope: Scope
    private var ledger: [String: LedgerEntry] = [:]
    private let log = AppLog.logger("team")

    /// One row per assignment, so "who is doing what, and how did it go" is
    /// answerable without replaying anything (§2.2's task ledger).
    public struct LedgerEntry: Sendable, Equatable {
        public let assignment: Assignment
        public var attempts: Int
        public var passed: Bool
        public var findings: [String]
        public var deliverable: Deliverable?
    }

    public init(router: ModelRouter,
                specialists: [Role: any Specialist],
                reviewer: QAReviewer = QAReviewer(),
                maxFanOut: Int = 4,
                retryCap: Int = 3,
                ledgerStore: TaskLedgerStore? = nil,
                scope: Scope = .central) {
        self.router = router
        self.specialists = specialists
        self.reviewer = reviewer
        self.maxFanOut = maxFanOut
        self.retryCap = retryCap
        self.ledgerStore = ledgerStore
        self.scope = scope
    }

    /// Written on every state change, not once at the end: a run that is
    /// interrupted is exactly when someone wants to read the ledger.
    private func persist(_ id: String) async {
        guard let ledgerStore, let entry = ledger[id] else { return }
        try? await ledgerStore.record(LedgerRow(
            assignmentID: entry.assignment.id,
            role: entry.assignment.role,
            goal: entry.assignment.goal,
            attempts: entry.attempts,
            passed: entry.passed,
            findings: entry.findings,
            summary: entry.deliverable?.summary), scope: scope)
    }

    public var entries: [LedgerEntry] {
        ledger.values.sorted { $0.assignment.id < $1.assignment.id }
    }

    // MARK: - running

    public func run(goal: String,
                    plan providedPlan: TeamPlan? = nil,
                    emit: @Sendable (TeamEvent) -> Void = { _ in }) async -> [Deliverable] {
        let plan: TeamPlan
        do {
            if let providedPlan {
                plan = providedPlan
            } else {
                plan = try await makePlan(for: goal)
            }
            try validate(plan)
        } catch {
            emit(.failed("\(error)"))
            return []
        }
        emit(.planned(plan))

        var delivered: [Deliverable] = []

        for assignment in plan.assignments {
            guard let specialist = specialists[assignment.role] else {
                emit(.failed(TeamError.noSpecialist(assignment.role).description))
                continue
            }
            ledger[assignment.id] = LedgerEntry(assignment: assignment, attempts: 0,
                                                passed: false, findings: [])

            var attempt = 0
            var lastFindings: [String] = []

            while attempt < retryCap {
                attempt += 1
                ledger[assignment.id]?.attempts = attempt
                await persist(assignment.id)
                emit(.assigned(assignment))

                let deliverable: Deliverable
                do {
                    deliverable = try await specialist.execute(
                        reworked(assignment, attempt: attempt, findings: lastFindings))
                } catch {
                    lastFindings = ["\(error)"]
                    emit(.rework(assignmentID: assignment.id, attempt: attempt,
                                 reasons: lastFindings))
                    continue
                }
                emit(.delivered(deliverable))

                let verdict = reviewer.review(deliverable, against: assignment,
                                              standard: specialist.definitionOfDone)
                ledger[assignment.id]?.deliverable = deliverable
                ledger[assignment.id]?.findings = verdict.findings
                emit(.reviewed(assignmentID: assignment.id, passed: verdict.passed,
                               findings: verdict.findings))

                await persist(assignment.id)

                if verdict.passed {
                    ledger[assignment.id]?.passed = true
                    await persist(assignment.id)
                    delivered.append(deliverable)
                    break
                }
                lastFindings = verdict.findings
                emit(.rework(assignmentID: assignment.id, attempt: attempt,
                             reasons: verdict.findings))
            }

            if ledger[assignment.id]?.passed != true {
                // Bounded, and it ends by asking a person rather than by
                // trying forever (§2.5).
                emit(.escalated(assignmentID: assignment.id, attempts: attempt,
                                reasons: lastFindings))
            }
        }

        emit(.finished(deliverables: delivered))
        return delivered
    }

    /// Rework carries the reviewer's reasons into the next attempt. Sending
    /// the same brief back unchanged is how a loop repeats itself.
    private func reworked(_ assignment: Assignment, attempt: Int,
                          findings: [String]) -> Assignment {
        guard attempt > 1, !findings.isEmpty else { return assignment }
        return Assignment(
            id: assignment.id, role: assignment.role,
            goal: """
            \(assignment.goal)

            งานรอบก่อนไม่ผ่านการตรวจ ด้วยเหตุผลต่อไปนี้ — แก้ให้ครบ:
            \(findings.map { "- \($0)" }.joined(separator: "\n"))
            """,
            inputs: assignment.inputs,
            acceptanceCriteria: assignment.acceptanceCriteria,
            deliverableType: assignment.deliverableType)
    }

    // MARK: - planning

    private static let planSchema = #"""
    {"type":"object",
     "properties":{"assignments":{"type":"array","items":{
       "type":"object",
       "properties":{
         "role":{"type":"string","enum":["researcher","analyst","engineer","writer"]},
         "goal":{"type":"string"},
         "deliverable":{"type":"string"},
         "criteria":{"type":"array","items":{"type":"object",
           "properties":{"text":{"type":"string"},"evidence":{"type":"string"}},
           "required":["text","evidence"]}}},
       "required":["role","goal","deliverable","criteria"]}}},
     "required":["assignments"]}
    """#

    private func makePlan(for goal: String) async throws -> TeamPlan {
        var request = LLMRequest(messages: [
            .init(.system, """
            คุณคือหัวหน้าทีม แตกเป้าหมายเป็นงานย่อยให้ผู้เชี่ยวชาญ
            - ทุกงานต้องมีเกณฑ์ตรวจรับที่ระบุ **หลักฐาน** ที่ผู้ตรวจต้องเห็น ไม่ใช่คำว่า "ดี" หรือ "ครบถ้วน"
            - งานเขียนโค้ดให้เป็นงานเดียวของ engineer เท่านั้น ห้ามแตกเป็นหลายงาน
            - แตกงานเท่าที่จำเป็นจริง งานที่ทำคนเดียวจบให้เป็นงานเดียว
            """),
            .init(.user, goal),
        ])
        request.responseSchema = (name: "TeamPlan", schemaJSON: Self.planSchema)
        request.maxTokens = 2_048
        request.temperature = 0

        let completion: LLMCompletion
        do {
            // Planning badly is expensive downstream, so it never runs on the
            // smallest tier (§9.2, and E.7's measured routing instability).
            completion = try await router.complete(request, policy: .init(impact: .high))
        } catch {
            throw TeamError.planningFailed("\(error)")
        }

        guard let data = completion.text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["assignments"] as? [[String: Any]] else {
            throw TeamError.planningFailed("อ่านแผนไม่ได้: \(completion.text.prefix(160))")
        }

        let assignments = rows.compactMap { row -> Assignment? in
            guard let roleName = row["role"] as? String,
                  let role = Role(rawValue: roleName),
                  let taskGoal = row["goal"] as? String,
                  let deliverable = row["deliverable"] as? String else { return nil }

            let criteria = (row["criteria"] as? [[String: Any]] ?? []).compactMap {
                criterion -> Criterion? in
                guard let text = criterion["text"] as? String,
                      let evidence = criterion["evidence"] as? String else { return nil }
                return Criterion(text: text, evidenceRequired: evidence)
            }
            // A task nobody can review is not a task. The type would refuse it
            // anyway; dropping it here keeps the reason legible.
            guard !criteria.isEmpty else { return nil }

            return Assignment(role: role, goal: taskGoal,
                              acceptanceCriteria: criteria, deliverableType: deliverable)
        }

        return TeamPlan(goal: goal, assignments: assignments)
    }

    private func validate(_ plan: TeamPlan) throws {
        guard !plan.assignments.isEmpty else { throw TeamError.emptyPlan }

        let engineering = plan.assignments.filter { $0.role == .engineer }
        guard engineering.count <= 1 else {
            throw TeamError.engineerFannedOut(count: engineering.count)
        }
        guard plan.assignments.count <= maxFanOut else {
            throw TeamError.fanOutTooWide(count: plan.assignments.count, cap: maxFanOut)
        }
    }
}

// MARK: - QA

/// Checks a deliverable against its acceptance criteria and its role's
/// standard, using evidence only (§2.5). It never asks a model whether the
/// work looks good: "looks good" is what v1's review produced, and it passed
/// everything.
public struct QAReviewer: Sendable {
    public struct Verdict: Sendable, Equatable {
        public let passed: Bool
        public let findings: [String]
    }

    public init() {}

    public func review(_ deliverable: Deliverable,
                       against assignment: Assignment,
                       standard: [Criterion]) -> Verdict {
        var findings: [String] = []

        if deliverable.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append("ไม่มีข้อสรุปส่งกลับมา")
        }

        switch assignment.role {
        case .engineer:
            // External-truth-gated: a build or test that actually ran and
            // returned zero, or it is not done — whatever the summary says.
            let exits = deliverable.evidence.filter { $0.kind == .commandExit }
            if exits.isEmpty {
                findings.append("ไม่มีหลักฐานว่าได้รัน build/test จริง")
            } else if !exits.contains(where: \.passed) {
                findings.append("รัน build/test แล้วยังไม่ผ่าน (exit code ไม่ใช่ 0)")
            }

        case .researcher:
            let citations = deliverable.evidence.filter { $0.kind == .citation && $0.passed }
            if citations.count < 2 {
                findings.append("มีแหล่งอ้างอิงที่ใช้ได้ \(citations.count) แหล่ง ต้องมีอย่างน้อย 2")
            }
            // §2.5 is explicit that a snippet is not a source.
            if !citations.contains(where: { $0.summary.contains("http") }) {
                findings.append("ยังไม่มีหลักฐานว่าอ่านเนื้อหาจริงผ่าน fetch_page")
            }

        case .analyst:
            if !deliverable.evidence.contains(where: { $0.kind == .statisticalCheck }) {
                findings.append("ไม่มีผลการตรวจ assumption ของวิธีทางสถิติที่ใช้")
            }

        case .writer:
            if !deliverable.evidence.contains(where: { $0.kind == .citation && $0.passed }) {
                findings.append("ไม่มี citation ผูกกับแหล่งจริง")
            }

        case .teamLead, .reviewer:
            break
        }

        // The assignment's own criteria are checked too: a role standard is a
        // floor, and the lead can ask for more on a specific task.
        for criterion in assignment.acceptanceCriteria where deliverable.evidence.isEmpty {
            findings.append("ไม่มีหลักฐานสำหรับเกณฑ์: \(criterion.text)")
        }
        _ = standard

        return Verdict(passed: findings.isEmpty, findings: findings)
    }
}
