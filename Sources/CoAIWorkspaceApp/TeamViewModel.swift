import Foundation
import Observation
import AgentKit
import CoreEngine
import Observability
import Persistence
import ProjectKit

// ─────────────────────────────────────────────────────────────
// The Team screen's state (ARCHITECTURE §2.2, P4.7).
//
// §2.2 wants "who is doing what, and how did it go" answerable at any moment.
// Two sources answer it, and the screen needs both:
//
//  • the persisted ledger, which survives the run and the app — the moment a
//    person most wants to ask is after leaving something unattended;
//  • the live event stream, which is the only thing that can show work that is
//    still in flight, because a row is written when a state changes and an
//    assignment in progress has not changed state yet.
//
// Rows are keyed by assignment id and merged, so a restart mid-run shows the
// same list rather than a second copy of it.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class TeamViewModel {
    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    /// One assignment as the screen shows it. `.running` exists only in memory:
    /// nothing durable can say "started but not yet finished", which is exactly
    /// the state the Done-when asks to be visible.
    public enum Progress: Sendable, Equatable {
        case running
        case passed
        case failed
        /// Stopped and waiting for a person, with the reasons that got it here.
        case escalated
        /// A person stopped it (P4.7). Distinct from `escalated`: that one is
        /// a question, this one is the answer.
        case cancelled
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var role: Role
        public var goal: String
        public var attempts: Int
        public var progress: Progress
        public var findings: [String]
        public var summary: String?
    }

    /// An assignment while it is still the user's to change (§2.6).
    ///
    /// A separate type from `Assignment` because the two have different rules:
    /// `Assignment` cannot exist without acceptance criteria — the type has
    /// refused that since P1.1 — but a draft the user is halfway through
    /// writing obviously can. Converting is where the rule is enforced, so a
    /// half-written row simply cannot be started rather than being started and
    /// found unreviewable later.
    public struct Draft: Identifiable, Equatable {
        public var id = UUID()
        public var role: Role = .researcher
        public var goal: String = ""
        public var deliverableType: String = "เอกสารสรุป"
        /// One criterion per line, as `เกณฑ์ | หลักฐานที่ต้องเห็น`.
        public var criteria: String = ""

        var assignment: Assignment? {
            let parsed = criteria.split(separator: "\n").compactMap { line -> Criterion? in
                let parts = line.split(separator: "|", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard let text = parts.first, !text.isEmpty else { return nil }
                // Evidence is what makes a criterion reviewable (§2.5); a line
                // with none is kept, and the standard says so in words rather
                // than being silently dropped.
                let evidence = parts.count > 1 && !parts[1].isEmpty
                    ? parts[1] : "หลักฐานที่ตรวจได้จากสิ่งที่รันจริง"
                return Criterion(text: text, evidenceRequired: evidence)
            }
            let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedGoal.isEmpty, !parsed.isEmpty else { return nil }
            return Assignment(role: role, goal: trimmedGoal,
                              acceptanceCriteria: parsed,
                              deliverableType: deliverableType)
        }
    }

    public private(set) var rows: [Row] = []
    public private(set) var plan: TeamPlan?
    public private(set) var isRunning = false
    public private(set) var isPlanning = false
    public private(set) var status: Status?
    public var goal = ""
    /// A token ceiling for one run (§5.5, P4.8), as typed. Blank means no
    /// ceiling, which is the honest default: a number chosen here would be a
    /// limit nobody set, and the first time it stopped a real run it would
    /// look like a fault.
    public var tokenCeiling = ""
    public private(set) var scope: Scope = .central

    /// Which leaf of the plan this run is work against (§19.6, P10.4).
    ///
    /// Chosen rather than guessed, exactly as the chat header does it. A team
    /// run that is not against any promise is a real thing — trying something
    /// out, answering a question — and inventing an attribution would put hours
    /// on a package nobody worked on.
    ///
    /// It also closes a gap that had been open since P10.4: `LedgerRow` has
    /// carried `work_package` since then and **nothing ever wrote it**, so the
    /// column existed, the index existed, and every query over it returned
    /// nothing.
    public var workPackage: String?
    public private(set) var workPackages: [WorkPackage] = []

    /// Nothing runs while this is non-empty: the plan is the user's to change
    /// first, whether the lead wrote it or they did (§2.6).
    public var draft: [Draft] = []

    private var team: TeamOrchestrator?
    /// The ledger as it came off disk, so a row on screen can be turned back
    /// into an `Assignment` (P4.7's rework).
    private var stored: [LedgerRow] = []
    private var ledger: TaskLedgerStore?
    private var projects: ProjectService?
    /// Read at start time, not stored: the switch lives on the chat header and
    /// the gateway is where all three modes are already kept, so asking it is
    /// how the team screen sees the same setting rather than a second copy.
    private var gateway: ToolGateway?
    private var run: Task<Void, Never>?
    private let log = AppLog.logger("team-ui")

    public init() {}

    public func attach(team: TeamOrchestrator, ledger: TaskLedgerStore,
                       gateway: ToolGateway, projects: ProjectService,
                       scope: Scope) async {
        self.team = team
        self.ledger = ledger
        self.gateway = gateway
        self.projects = projects
        self.scope = scope
        // The lead files its rows and spans under the same workspace the screen
        // is reading. Until this it was pinned to `.central` at boot, so team
        // work never appeared in any project's tolerance strip or schedule.
        await team.use(scope: scope)
        await loadWorkPackages()
        await reload()
    }

    /// Open leaves of the current project, for the picker. Empty in General,
    /// which is correct — there is no plan there to be against.
    private func loadWorkPackages() async {
        guard let projects, case .project(let id) = scope else {
            workPackages = []
            workPackage = nil
            return
        }
        workPackages = await projects.breakdown(of: id).openLeaves
        // A package finished or deleted elsewhere must not stay selected: the
        // next run would be filed against something closed.
        if let current = workPackage, !workPackages.contains(where: { $0.id == current }) {
            workPackage = nil
        }
    }

    /// What the ledger has on disk. Live rows already on screen keep their
    /// place — a row still running has no durable state to be reloaded from,
    /// and dropping it would make in-flight work disappear on every refresh.
    public func reload() async {
        guard let ledger else { return }
        do {
            let rows = try await ledger.rows(scope: scope)
            // Kept, not just merged into the display rows: re-running a piece
            // of work needs the acceptance criteria, and those live on the
            // stored row rather than on anything the screen shows.
            stored = rows
            for row in rows { merge(row) }
        } catch {
            log.error("loading task ledger: \(error)")
            status = Status(message: "โหลดบันทึกงานของทีมไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public var unfinishedCount: Int {
        rows.count { $0.progress == .running || $0.progress == .escalated }
    }

    /// Whether this row can be sent back — false for rows written before the
    /// ledger stored acceptance criteria, which cannot be rebuilt.
    public func isReworkable(_ row: Row) -> Bool { assignment(for: row) != nil }

    // MARK: - planning (§2.6)

    /// Asks the lead for a plan and stops there. What comes back is a draft the
    /// user edits; approving it is a separate act.
    public func propose() async {
        guard let team else {
            status = Status(message: "ยังต่อทีมไม่ได้ — เอนจินยังไม่พร้อม", isError: true)
            return
        }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !isRunning, !isPlanning else { return }

        isPlanning = true
        defer { isPlanning = false }
        status = nil

        do {
            let proposed = try await team.propose(goal: goal)
            draft = proposed.assignments.map { assignment in
                Draft(role: assignment.role,
                      goal: assignment.goal,
                      deliverableType: assignment.deliverableType,
                      criteria: assignment.acceptanceCriteria
                        .map { "\($0.text) | \($0.evidenceRequired)" }
                        .joined(separator: "\n"))
            }
            status = Status(message: "หัวหน้าทีมเสนอ \(draft.count) งาน — แก้ได้ก่อนเริ่ม",
                            isError: false)
        } catch {
            status = Status(message: "วางแผนไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// Skips the lead entirely (§2.6): one role, one assignment, written by the
    /// user. It still goes through the same draft, so the acceptance criteria
    /// §2.5 requires are filled in by hand rather than waived.
    public func draftDirect(role: Role) {
        guard !isRunning else { return }
        draft = [Draft(role: role,
                       goal: goal.trimmingCharacters(in: .whitespacesAndNewlines))]
        status = Status(message: "ข้ามหัวหน้าทีม — เขียนงานและเกณฑ์ตรวจรับเอง", isError: false)
    }

    public func addDraftAssignment() {
        guard !isRunning else { return }
        draft.append(Draft())
    }

    public func removeDraft(_ id: Draft.ID) {
        draft.removeAll { $0.id == id }
    }

    public func discardDraft() {
        draft = []
        status = nil
    }

    /// What the lead would refuse about the draft as it stands, so §2.4's rule
    /// is visible while it can still be fixed.
    public func refusal() async -> String? {
        let assignments = draft.compactMap(\.assignment)
        guard let team, !assignments.isEmpty else { return nil }
        return await team.refusal(for: TeamPlan(goal: goal, assignments: assignments))
    }

    public var draftIsRunnable: Bool {
        !draft.isEmpty && draft.allSatisfy { $0.assignment != nil }
    }

    // MARK: - running

    /// Runs the plan the user approved. There is no path from a goal straight
    /// to work: `propose` or `draftDirect` first, edit, then this.
    public func start() async {
        guard let team else {
            status = Status(message: "ยังต่อทีมไม่ได้ — เอนจินยังไม่พร้อม", isError: true)
            return
        }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignments = draft.compactMap(\.assignment)
        guard !goal.isEmpty, !isRunning, assignments.count == draft.count,
              !assignments.isEmpty else { return }
        let approved = TeamPlan(goal: goal, assignments: assignments)

        rows = []
        plan = nil
        draft = []
        isRunning = true
        status = nil

        let untilDone = await gateway?.currentModes.runUntilDone ?? false
        let leaf = workPackage
        // P4.8 — the ceiling the person typed, or none. Blank means none
        // rather than a number this screen chose for them.
        let ceiling = Int(tokenCeiling.trimmingCharacters(in: .whitespaces))

        run = Task { [weak self] in
            // The orchestrator emits from its own actor; every event is hopped
            // back to the main actor before it touches view state.
            let deliverables = await team.run(goal: goal, plan: approved,
                                              runUntilDone: untilDone,
                                              workPackage: leaf,
                                              tokenCeiling: ceiling) { event in
                Task { @MainActor in self?.apply(event) }
            }
            await MainActor.run {
                self?.isRunning = false
                if self?.status?.isError != true {
                    self?.status = Status(message: "ทีมทำงานจบแล้ว — ได้ผลงาน \(deliverables.count) ชิ้น",
                                          isError: false)
                }
            }
            await self?.reload()
        }
    }

    // MARK: - one assignment at a time (P4.7)

    /// Sends one piece of work back with a reason.
    ///
    /// The reason is required by the UI rather than optional here: "do it
    /// again" with no note is the instruction that produced v1's loops, and
    /// the specialist reads this in the same place it reads QA's findings.
    public func rework(_ row: Row, note: String) async {
        guard let team, let assignment = assignment(for: row) else {
            status = Status(message: "งานนี้เก่าเกินกว่าจะสั่งแก้ได้ — บันทึกไม่มีเกณฑ์ตรวจรับของมัน",
                            isError: true)
            return
        }
        isRunning = true
        status = Status(message: "สั่งแก้ \(row.role.rawValue) แล้ว", isError: false)
        await team.rework(assignment, note: note) { event in
            Task { @MainActor in self.apply(event) }
        }
        isRunning = false
        await reload()
    }

    /// Stops one piece of work and says so in the ledger.
    public func cancel(_ row: Row, reason: String = "ผู้ใช้ยกเลิกงานนี้") async {
        guard let team else { return }
        await team.cancel(row.id, assignment: assignment(for: row), reason: reason) { event in
            Task { @MainActor in self.apply(event) }
        }
        await reload()
    }

    /// The stored assignment behind a row, when the ledger kept enough to
    /// rebuild it. Rows written before criteria were stored cannot be re-run —
    /// `Assignment` refuses to exist without them — and the screen says so
    /// rather than offering a button that would fail.
    private func assignment(for row: Row) -> Assignment? {
        stored.first { $0.assignmentID == row.id }?.assignment
    }

    /// Stops the run without pretending the work is finished. The rows already
    /// on screen stay: what was done before the stop is still what happened.
    public func cancel() {
        guard isRunning else { return }
        run?.cancel()
        run = nil
        isRunning = false
        for index in rows.indices where rows[index].progress == .running {
            rows[index].progress = .escalated
            rows[index].findings.append("ผู้ใช้สั่งหยุดกลางคัน")
        }
        status = Status(message: "หยุดการทำงานของทีมแล้ว", isError: false)
    }

    private func apply(_ event: TeamEvent) {
        switch event {
        case .planned(let teamPlan):
            plan = teamPlan

        case .assigned(let assignment, let attempt):
            upsert(id: assignment.id) { row in
                row.role = assignment.role
                row.goal = assignment.goal
                row.attempts = attempt
                row.progress = .running
            }

        case .delivered(let deliverable):
            upsert(id: deliverable.assignmentID) { $0.summary = deliverable.summary }

        case .reviewed(let id, let passed, let findings):
            upsert(id: id) { row in
                row.progress = passed ? .passed : .failed
                row.findings = findings
            }

        case .rework(let id, let attempt, let reasons):
            upsert(id: id) { row in
                row.attempts = attempt
                row.progress = .running
                row.findings = reasons
            }

        case .escalated(let id, let attempts, let reasons):
            upsert(id: id) { row in
                row.attempts = attempts
                row.progress = .escalated
                row.findings = reasons
            }

        case .cancelled(let id, let reason):
            upsert(id: id) { row in
                row.progress = .cancelled
                row.findings = [reason]
            }

        case .continuing(let remaining):
            status = Status(message: "ทำต่อเองตาม Run-until-done — เหลืองานค้างในบันทึก \(remaining) งาน",
                            isError: false)

        case .budgetExhausted(let summary, let remaining):
            // Marked as an error state on purpose: the run stopped short, and
            // a neutral note is how somebody reads a truncated run as a
            // finished one (P4.8).
            status = Status(message: "หยุดเพราะถึงเพดานโทเคนของการรันนี้ — \(summary) "
                            + "· เหลืองานที่ยังไม่ผ่าน \(remaining) งาน อยู่ในบันทึกให้สั่งต่อได้",
                            isError: true)

        case .finished:
            isRunning = false

        case .failed(let message):
            isRunning = false
            status = Status(message: message, isError: true)
        }
    }

    // MARK: - rows

    private func upsert(id: String, _ edit: (inout Row) -> Void) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            edit(&rows[index])
        } else {
            var row = Row(id: id, role: .researcher, goal: "", attempts: 1,
                          progress: .running, findings: [], summary: nil)
            edit(&row)
            rows.append(row)
        }
    }

    /// A stored row never downgrades a live one to `.running`: the ledger says
    /// what was recorded, the stream says what is happening now.
    private func merge(_ stored: LedgerRow) {
        upsert(id: stored.assignmentID) { row in
            row.role = stored.role
            row.goal = stored.goal
            row.attempts = stored.attempts
            row.findings = stored.findings
            row.summary = stored.summary
            if row.progress != .running || !isRunning {
                row.progress = stored.passed ? .passed
                    : stored.cancelled ? .cancelled : .escalated
            }
        }
    }

    public func changeScope(to scope: Scope) async {
        self.scope = scope
        rows = []
        await reload()
    }
}
