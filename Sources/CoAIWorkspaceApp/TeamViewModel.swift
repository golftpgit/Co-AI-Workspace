import Foundation
import Observation
import AgentKit
import CoreEngine
import Observability
import Persistence

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

    public private(set) var rows: [Row] = []
    public private(set) var plan: TeamPlan?
    public private(set) var isRunning = false
    public private(set) var status: Status?
    public var goal = ""
    public var scope: Scope = .central

    private var team: TeamOrchestrator?
    private var ledger: TaskLedgerStore?
    private var run: Task<Void, Never>?
    private let log = AppLog.logger("team-ui")

    public init() {}

    public func attach(team: TeamOrchestrator, ledger: TaskLedgerStore) async {
        self.team = team
        self.ledger = ledger
        await reload()
    }

    /// What the ledger has on disk. Live rows already on screen keep their
    /// place — a row still running has no durable state to be reloaded from,
    /// and dropping it would make in-flight work disappear on every refresh.
    public func reload() async {
        guard let ledger else { return }
        do {
            let stored = try await ledger.rows(scope: scope)
            for row in stored { merge(row) }
        } catch {
            log.error("loading task ledger: \(error)")
            status = Status(message: "โหลดบันทึกงานของทีมไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public var unfinishedCount: Int {
        rows.count { $0.progress == .running || $0.progress == .escalated }
    }

    // MARK: - running

    public func start() async {
        guard let team else {
            status = Status(message: "ยังต่อทีมไม่ได้ — เอนจินยังไม่พร้อม", isError: true)
            return
        }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !isRunning else { return }

        rows = []
        plan = nil
        isRunning = true
        status = nil

        run = Task { [weak self] in
            // The orchestrator emits from its own actor; every event is hopped
            // back to the main actor before it touches view state.
            let deliverables = await team.run(goal: goal) { event in
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
                row.progress = stored.passed ? .passed : .escalated
            }
        }
    }

    public func changeScope(to scope: Scope) async {
        self.scope = scope
        rows = []
        await reload()
    }
}
