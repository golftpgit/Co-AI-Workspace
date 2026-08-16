import Foundation
import Observation
import AgentKit
import Roster
import ProjectKit
import CoreEngine
import Config
import DocGen
import Persistence
import Observability

// ─────────────────────────────────────────────────────────────
// The workspace switch and the project screen (ARCHITECTURE §19.1, §19.4).
//
// This is also where the app answers "which scope am I in": every screen reads
// `selection` rather than deciding for itself, which is what replaced the
// literal `ProjectID("default")` that used to stand in for a project the system
// did not actually have.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
public final class ProjectsViewModel {
    /// General or one project. There is no third state on purpose: `policy`
    /// scope is a knowledge partition, not a place to work (§11.2).
    ///
    /// Kept as a spelling of `OpenWorkspaces.Tab` rather than deleted, because
    /// it reads better at call sites that mean "the thing in front" — and the
    /// two cannot drift, since one converts to the other.
    public typealias Selection = OpenWorkspaces.Tab

    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    public private(set) var projects: [Project] = []
    public private(set) var status: Status?
    public private(set) var isWorking = false
    /// Which workspaces are open and which is in front (§19.1.1, P21.1).
    ///
    /// Was a single `Selection`, which is what made a project a *mode* rather
    /// than a tab: opening the second one cost you the first. Somebody
    /// researching two things at once is the ordinary case.
    public private(set) var workspaces = OpenWorkspaces()
    /// The gate for whatever is selected, recomputed after every change, so the
    /// screen never shows a stale "ready to advance".
    public private(set) var gate: GateEvaluation?
    /// The selected project's plan (§19.6). Read after every change rather
    /// than mutated in place: the gate reads the same value the screen draws,
    /// and two copies of a plan is how a gate starts disagreeing with the
    /// thing it is gating.
    public private(set) var wbs = WorkBreakdown()
    public private(set) var problems: [WBSProblem] = []
    /// The agreed frame and where the project sits inside it (§19.10).
    public private(set) var tolerances: [ToleranceStatus] = []
    public private(set) var openExceptions: [ExceptionReport] = []
    /// Where the readings come from. Held rather than recomputed inside the
    /// view model because each one belongs to a different subsystem, and P10.6
    /// wires two of the six for real — the rest are named and left at zero
    /// rather than invented.
    public var readings = ToleranceReadings()
    /// Which of the six the app can actually measure today (§19.10). The rest
    /// are enforced but unread, and the screen has to say so: a row showing
    /// "เวลา 0 / 1.50" reads as "time is being tracked and is fine", which is
    /// a lie by omission. Driving the screen by hand is what made that
    /// obvious — the numbers looked measured.
    /// Filled in as the readings become real. Everything not in here renders
    /// as "ยังไม่ได้วัด" rather than as a zero somebody would read as a
    /// measurement (§19.10).
    public private(set) var measured: Set<ToleranceDimension> = [.scope]
    /// Seconds spent against each leaf, from the span store (§19.7).
    public private(set) var elapsed: [String: TimeInterval] = [:]
    /// The five registers, the frozen agreements, and how far the plan has
    /// moved from the latest one (§19.11).
    public private(set) var registers: [RegisterEntry] = []
    public private(set) var baselines: [Baseline] = []
    public private(set) var drift: BaselineDiff?
    /// What the project was for, and how far the seventeen practices are
    /// answered (§19.12, §19.16). Both read after every change, like the gate:
    /// the closing checklist is only useful if it is the same set of facts the
    /// gate refuses on.
    public private(set) var benefits = BenefitLedger()
    public private(set) var conformance: [PracticeStatus] = []
    /// Reports already issued, newest first (§19.13). History rather than a
    /// button that re-renders: "what did we say in June" is the question a
    /// status report exists to answer.
    public private(set) var reports: [ProjectReport] = []

    /// What the status bar's popovers show (§19.2.3). Read alongside the gate,
    /// because a dashboard cell whose number is older than the screen it sits
    /// under is worse than no cell.
    public private(set) var spendByRole: [Slice] = []
    public private(set) var spendByModel: [Slice] = []
    public private(set) var spendTotal: Double = 0
    public private(set) var toolActivity: [ToolSlice] = []
    public private(set) var rework: [ReworkRow] = []
    /// p50–p90 of comparable finished work, for the time popover's band. `nil`
    /// when this machine has no history to forecast from — which the popover
    /// says, rather than drawing a band around a guess.
    public private(set) var forecast: ScheduleEstimate?

    /// The schedule on a calendar axis (§19.7, P10.9). `nil` until spans have
    /// been read; empty rows are a real answer, not a missing one.
    public private(set) var timeline: ScheduleTimeline?
    /// How many pieces of work the chart is not drawing. A picture that quietly
    /// shows part of the history reads as complete — the same rule the knowledge
    /// graph's horizon count exists for.
    public private(set) var timelineBeyondLimit = 0

    /// Where the work that has not started would land (§19.7, P10.9's third
    /// axis). `nil` until a project is open; a projection with no rows is a
    /// real answer and the screen says which leaves could not be forecast.
    public private(set) var projection: ScheduleProjection?

    public struct Slice: Sendable, Equatable, Identifiable {
        public let key: String
        public let amount: Double
        public var id: String { key }
    }

    public struct ToolSlice: Sendable, Equatable, Identifiable {
        public let tool: String
        public let calls: Int
        public let seconds: TimeInterval
        public var id: String { tool }
    }

    /// A round of work that had to be done again, with what QA said each time.
    /// §19.2.3: "งานที่ rework แล้วกี่รอบ พร้อมเหตุผลจาก QA ทุกรอบ" — the count
    /// on its own is a number nobody can act on.
    public struct ReworkRow: Sendable, Equatable, Identifiable {
        public let goal: String
        public let role: String
        public let attempts: Int
        public let findings: [String]
        public let needsHuman: Bool
        public var id: String { goal + role }
    }

    /// The edit waiting for a person to confirm, once the plan is an agreement
    /// (§19.2.4). `nil` most of the time — before G2, and for edits that change
    /// nothing the baseline holds.
    public private(set) var pendingEdit: PlanChangeProposal?

    private var service: ProjectService?
    /// Where a project's documents live (§19.1). Optional because the screen
    /// works without it — a report still becomes a row, it just does not become
    /// a file, and that is the honest degradation.
    private var paths: AppPaths?
    private var spans: SurrealSpanSink?
    /// §21.1 layer 3 / P12.8 — how well each role actually uses each tool,
    /// from the spans. Across projects on purpose: proficiency built from one
    /// project's spans is a statement about that project.
    public private(set) var proficiency: [ToolProficiency] = []
    private var spend: SurrealSpendLedger?
    private var ledger: TaskLedgerStore?
    private let log = AppLog.logger("projects-ui")

    public init() {}

    /// What every other screen asks for. General is `central`: shared
    /// knowledge, no ledger, no lifecycle.
    public var selection: Selection { workspaces.active }
    public var scope: Scope { workspaces.activeScope }

    public var selected: Project? {
        guard let id = workspaces.active.projectID else { return nil }
        return projects.first { $0.id == id }
    }

    /// Whether the thing in front may be written to (§19.1.1, P21.3).
    ///
    /// The screen asks this before offering an action. It is **not** the rule —
    /// `ProjectService.requireWritable` is, and it refuses whatever the screen
    /// shows. This is so the button is disabled rather than failing when
    /// pressed, which is a different job from enforcement.
    public var activeIsWritable: Bool { workspaces.activeIsWritable }

    public var openProjects: [Project] { projects.filter(\.isOpen) }

    public func attach(service: ProjectService) async {
        if let saved = UserDefaults.standard.string(forKey: Self.cycleKey),
           let cycle = ReportSchedule.Cycle(rawValue: saved) {
            reportCycle = cycle
        }
        self.service = service
        await reload()
    }

    /// The three stores the readings come from (§19.10, P10.15). Passed in
    /// rather than reached for, and each one named where its number comes from
    /// — a tolerance whose source nobody can point at is the thing this whole
    /// section exists to avoid.
    public func attach(spans: SurrealSpanSink, spend: SurrealSpendLedger,
                       ledger: TaskLedgerStore, paths: AppPaths? = nil) async {
        self.paths = paths
        self.spans = spans
        self.spend = spend
        self.ledger = ledger
        await refreshGate()
        await refreshProficiency()
    }

    /// The forecast band, and what it is made of (§19.10, §19.7, P10.15).
    ///
    /// Read once when the screen attaches rather than on every redraw: it is a
    /// scan of up to two thousand spans, and it changes on the scale of days.
    ///
    /// The band has been wrong twice, both times in the population rather than
    /// the arithmetic. First it was every span carrying a role — overwhelmingly
    /// `tool:kb_search` — so a schedule was being drawn from a p90 of search
    /// calls. Then it was completed turns, which is closer but is still a
    /// message-and-tools round trip standing in for a reviewed promise. Now that
    /// `TeamOrchestrator` records an assignment as a span, the first choice is
    /// the real thing: **finished assignments that produced the same kind of
    /// deliverable this project produces**.
    ///
    /// The fallback to turns stays, because a fresh install has no assignments
    /// and a popover that says nothing is less useful than one that says what it
    /// has. What it must not do is fall back silently — so the basis travels
    /// with the estimate and the popover prints it.
    private func forecastBand(spans: SurrealSpanSink,
                              project id: ProjectID) async -> ScheduleEstimate? {
        var rows: [LedgerRow] = []
        if let ledger { rows = (try? await ledger.rows(scope: .project(id))) ?? [] }
        // A project that has assigned nothing yet has no shape to forecast
        // from; every role and every kind would be a band made of unrelated work.
        guard !rows.isEmpty else { return nil }

        // Kinds this project actually produces, commonest first — a project
        // that writes ten reports and one script should be told about reports.
        var frequency: [String: Int] = [:]
        for row in rows where !row.deliverableType.isEmpty {
            frequency[Assignment.deliverableKind(row.deliverableType), default: 0] += 1
        }
        for kind in frequency.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).map(\.key) {
            let durations = (try? await spans.durations(forDeliverableKind: kind)) ?? []
            // The first kind with enough finished work behind it wins. Pooling
            // the kinds together would put a literature review and a bug fix in
            // one distribution, which is the average nobody's work resembles.
            if let estimate = Schedule.estimate(from: durations,
                                                basis: .assignments(kind: kind)) {
                return estimate
            }
        }

        var durations: [TimeInterval] = []
        for role in Set(rows.map(\.role)).sorted(by: { $0.rawValue < $1.rawValue }) {
            durations += (try? await spans.durations(forRole: role)) ?? []
        }
        return Schedule.estimate(from: durations, basis: .turns)
    }

    /// The forward pass over the leaves that have not started (P10.9).
    ///
    /// One band for the whole project rather than one per leaf, and that is a
    /// limitation worth stating: `forecastBand` picks the kind this project
    /// produces most, so a plan mixing a literature review with a bug fix gets
    /// the review's timing for both. Per-leaf bands need per-leaf deliverable
    /// kinds on the work package, which the type does not carry yet.
    private func refreshProjection(project id: ProjectID) {
        let started = Set(elapsed.filter { $0.value > 0 }.keys)
        let band = forecast
        projection = ScheduleForecast.project(wbs, started: started, now: Date()) { _ in band }
    }

    /// Turns the project's recorded work into a chart (§19.7, P10.9).
    ///
    /// Read from the same population `elapsedByWorkPackage` sums — top-level
    /// spans — so the picture and the total beside it are two views of one set
    /// of rows rather than two answers to one question.
    private func refreshTimeline(spans: SurrealSpanSink, project id: ProjectID) async {
        guard let work = try? await spans.topLevelWork(project: .init(id.rawValue)) else {
            timeline = nil
            return
        }
        timelineBeyondLimit = max(0, work.total - work.spans.count)
        timeline = ScheduleTimeline.build(
            intervals: work.spans.compactMap { span in
                guard let ended = span.endedAt else { return nil }
                return ScheduleTimeline.Interval(
                    id: span.id.rawValue, workPackage: span.workPackage,
                    start: span.startedAt, end: ended,
                    succeeded: span.status == .succeeded)
            },
            leaves: wbs.leaves)
    }

    public func refreshProficiency() async {
        guard let spans else { return }
        proficiency = (try? await spans.toolProficiency()) ?? []
    }

    /// What this role has been measured at, most-used first.
    public func proficiency(for role: Role) -> [ToolProficiency] {
        proficiency.filter { $0.role == role }
    }

    public func reload() async {
        guard let service else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            projects = try await service.projects()
            // Titles, access and existence all re-read at once. Replaces the
            // ad-hoc "fall back to General if the selected project vanished" —
            // which handled deletion and silently missed the case that matters
            // more: a project closed elsewhere while its tab sat open, still
            // offering every edit.
            workspaces.reconcile(with: projects)
            await refreshGate()
        } catch {
            log.error("loading projects: \(error)")
            status = Status(message: "โหลดรายการโปรเจกต์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// Opens a project in a tab, or moves to it if it is already open.
    public func open(_ project: Project) async {
        workspaces.open(project)
        status = nil
        await refreshGate()
    }

    /// Moves to an already-open tab.
    public func focus(_ tab: Selection) async {
        workspaces.focus(tab)
        status = nil
        await refreshGate()
        // Asked when a workspace comes to the front, which is the only moment
        // this app can ask anything: it is not running when it is closed.
        await refreshReportDue()
    }

    /// Closes a tab. **Closing a window, not closing a project** — the life
    /// cycle's closing gate is a different act, and conflating the two would
    /// let somebody end a project by tidying their screen.
    public func closeTab(_ tab: Selection) async {
        workspaces.close(tab)
        status = nil
        await refreshGate()
    }

    /// Creates a project from a type manifest (§20.2, P11.1).
    ///
    /// The manifest decides what the project starts with: which coarse kind it
    /// is, and the plan laid down from its template. What it deliberately does
    /// *not* decide is which practices apply — that is a governance decision
    /// with a person's name on it (§19.15), so the type's suggestions are
    /// carried to the screen rather than acted on.
    public func create(name: String, type: ProjectTypeManifest) async {
        guard let service else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = Status(message: "ตั้งชื่อโปรเจกต์ก่อน", isError: true)
            return
        }
        do {
            let template = type.wbsTemplate
            let project = try await service.create(
                name: trimmed, kind: type.kind, typeName: type.type,
                startingPlan: { WBSTemplate.packages(template, project: $0) })
            await reload()
            await open(project)
            let planted = WBSTemplate.packages(template, project: project.id).count
            status = Status(message: planted > 0
                            ? "สร้าง '\(trimmed)' แบบ\(type.label) แล้ว — อยู่ขั้นเริ่มต้น "
                                + "พร้อมแผนตั้งต้น \(planted) รายการที่ยังต้องผูกขอบเขตและระบุผู้รับผิดชอบเอง"
                            : "สร้าง '\(trimmed)' แล้ว — อยู่ขั้นเริ่มต้น",
                            isError: false)
        } catch {
            status = Status(message: "สร้างโปรเจกต์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// Edits land immediately. The brief and the scope statement are what G1
    /// reads, so making them a modal with a Save button would put a gate
    /// condition behind a second decision.
    public func update(_ project: Project) async {
        guard let service else { return }
        do {
            try await service.update(project)
            await reload()
        } catch {
            status = Status(message: "บันทึกไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func advance() async {
        guard let service, let project = selected else { return }
        do {
            let moved = try await service.advance(project.id)
            await reload()
            status = Status(message: "ผ่าน \(project.stage.exitGate ?? "") แล้ว — ตอนนี้อยู่ขั้น\(moved.stage.label)",
                            isError: false)
        } catch {
            // The refusal names what is missing. A gate that says only "no" is
            // a gate people route around.
            status = Status(message: "\(error)", isError: true)
        }
    }

    public func terminate(reason: String) async {
        guard let service, let project = selected else { return }
        do {
            _ = try await service.terminate(project.id, reason: reason)
            await reload()
            status = Status(message: "ยุติโครงการแล้ว — บันทึกไว้ว่า 'ยุติก่อนกำหนด' ไม่ใช่ 'สำเร็จ'",
                            isError: false)
        } catch {
            status = Status(message: "ปิดโครงการไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// General → Project (§19.1, P10.3).
    ///
    /// Creates the project from the drafted brief and moves the conversation
    /// that produced it. Order matters: the project has to exist before the
    /// conversation can point at it, and a failed move must not leave a
    /// project with no history behind it — so the failure is reported with the
    /// project already made, and the conversation stays where it is.
    public func promote(_ draft: DraftedBrief,
                        conversationID: String?,
                        conversations: ConversationStore) async {
        guard let service else { return }
        do {
            let project = try await service.create(name: draft.name,
                                                   kind: .blank,
                                                   brief: draft.brief,
                                                   statement: draft.statement)
            if let conversationID {
                try await conversations.reassign(conversationID, to: project.scope)
            }
            await reload()
            await open(project)
            status = Status(
                message: draft.isReadyForG1
                    ? "ยกระดับเป็นโปรเจกต์แล้ว — ตรวจขอบเขตอีกครั้งแล้วกดผ่าน G1 ได้เลย"
                    : "ยกระดับเป็นโปรเจกต์แล้ว — ยังผ่าน G1 ไม่ได้จนกว่าจะเติมช่องที่ค้าง",
                isError: false)
        } catch {
            status = Status(message: "ยกระดับเป็นโปรเจกต์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: - editing the plan (§19.2.4, P10.16)

    /// Makes an edit, or asks first.
    ///
    /// Every inline edit in the Plan area comes through here, which is the point:
    /// after G2 the same edit is a change to an agreement, and the decision about
    /// whether to say so cannot be made at each call site or it will be made
    /// differently at each call site. Before a baseline exists nothing is asked —
    /// editing the plan then *is* writing the plan.
    public func edit(_ edit: PlanEdit) async {
        guard let service, let project = selected else { return }
        if let proposal = await service.proposal(for: edit, in: project.id, basis: basis()) {
            // §19.2.4: not blocked, not warned about afterwards — put the
            // consequence where the hand already is and let the person confirm.
            pendingEdit = proposal
            return
        }
        await commit(edit)
    }

    /// Confirms the edit the bar is asking about, which also records the change
    /// request. One call, because they are one event (§19.11).
    public func confirmPendingEdit() async {
        guard let proposal = pendingEdit else { return }
        pendingEdit = nil
        await commit(proposal.edit, expecting: proposal)
    }

    public func cancelPendingEdit() {
        pendingEdit = nil
        // The screen is still showing the edited value in its local buffers, so
        // a reload is what puts the agreed plan back in front of the person.
        Task { await reload() }
    }

    private func commit(_ edit: PlanEdit, expecting proposal: PlanChangeProposal? = nil) async {
        guard let service, let project = selected else { return }
        do {
            let recorded = try await service.apply(edit, in: project.id, basis: basis())
            await refreshGate()
            if let recorded {
                status = Status(message: "บันทึกแล้ว · เปิดคำขอเปลี่ยนแปลง #\(recorded.requestNumber) "
                                + "รอคนตัดสิน — ประตูขั้นถัดไปยังไม่เปิดจนกว่าจะตัดสิน",
                                isError: false)
            } else if proposal != nil {
                // The proposal was computed from a plan that has since moved. Say
                // it rather than silently applying under a stale impact estimate.
                status = Status(message: "แก้แล้ว แต่ผลกระทบที่แสดงไว้คำนวณจากแผนก่อนหน้า — ตรวจส่วนต่างอีกครั้ง",
                                isError: true)
            }
        } catch {
            status = Status(message: "แก้แผนไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// What the two estimated impacts rest on (§19.2.4). Read from the same
    /// measurements the status strip shows, so the change request cannot quote a
    /// number the screen does not.
    private func basis() -> ChangeEstimateBasis {
        ChangeEstimateBasis(elapsedByPackage: elapsed,
                            spent: readings.spent,
                            costMeasured: measured.contains(.cost))
    }

    public func addPackage(title: String, parent: String?) async {
        guard let project = selected else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let siblings = wbs.children(of: parent)
        await edit(.savePackage(WorkPackage(
            projectID: project.id,
            parent: parent,
            title: trimmed,
            // Pre-filled when the project has exactly one thing in scope,
            // because that is the common case and an empty required field
            // teaches people to ignore required fields.
            scopeRef: project.statement.inScope.count == 1
                ? project.statement.inScope.first : nil,
            acceptanceCriteria: [],
            order: (siblings.map(\.order).max() ?? -1) + 1)))
    }

    public func update(_ package: WorkPackage) async {
        await edit(.savePackage(package))
    }

    /// Moves a package to where another sits among its siblings (§19.6, P10.11).
    ///
    /// Every renumbered sibling is written, because a sequence half-written is
    /// a sequence that reads wrong and inserts wrong. Refusals — a different
    /// parent, a drop on itself — come back as nothing changed rather than as
    /// an error: a drag that lands somewhere meaningless is not a mistake
    /// somebody needs telling about.
    public func reorder(_ moved: String, toPositionOf target: String) async {
        let changed = wbs.reordering(moved, toPositionOf: target)
        guard !changed.isEmpty else { return }
        for package in changed { await edit(.savePackage(package)) }
    }

    public func removePackage(_ packageID: String) async {
        let title = wbs.packages.first { $0.id == packageID }?.title ?? packageID
        await edit(.removePackage(id: packageID, title: title))
    }

    /// The scope statement, which a baseline holds as well (§19.11). Split from
    /// the rest of the project row on purpose: the brief and the board seats are
    /// not part of the agreement, so editing them is not a change request.
    public func updateScope(_ statement: ScopeStatement) async {
        await edit(.scopeStatement(statement))
    }

    /// Closing a leaf by hand. The evidence rule lives in `WorkBreakdown`, so
    /// the refusal here is the same refusal an agent gets.
    public func complete(_ packageID: String, evidence: [Evidence]) async {
        guard let service, let project = selected else { return }
        do {
            try await service.complete(packageID, in: project.id, with: evidence)
            await refreshGate()
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    // MARK: - tolerance (§19.10)

    /// The frame is part of the agreement, so changing it after G2 goes through
    /// change control like the plan does.
    public func setTolerances(_ preset: Tolerances) async {
        await edit(.tolerances(preset))
    }

    /// One axis, typed in. §19.2.4's line between what you *set* and what you
    /// *measure*: the limit is set, the current value is measured, and only one
    /// of the two has a text field.
    public func setTolerance(_ dimension: ToleranceDimension, to limit: Double) async {
        guard let project = selected else { return }
        var limits = project.tolerances
        limits.limits[dimension] = limit
        await edit(.tolerances(limits))
    }

    /// Checks the frame and raises what is newly outside it. Returns the text
    /// to send, so the caller decides where it goes — this model does not know
    /// what a channel is.
    @discardableResult
    public func checkTolerances() async -> [String] {
        guard let service, let project = selected else { return [] }
        do {
            let raised = try await service.raiseBreaches(for: project.id, readings: readings)
            await refreshGate()
            return raised.map(\.message)
        } catch {
            status = Status(message: "ตรวจกรอบไม่สำเร็จ: \(error)", isError: true)
            return []
        }
    }

    public func resolve(_ report: ExceptionReport, decision: String) async {
        guard let service else { return }
        do {
            try await service.resolve(report, decision: decision)
            await refreshGate()
            status = Status(message: "ปิดข้อยกเว้นแล้ว — ทีมทำงานต่อได้", isError: false)
        } catch {
            status = Status(message: "ปิดข้อยกเว้นไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: - benefits (§19.12)

    public func addBenefit(title: String, measure: String, baselineValue: Double,
                           target: Double, reviewAt: Date, owner: String) async {
        guard let service, let project = selected else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = Status(message: "ตั้งชื่อประโยชน์ที่จะได้ก่อน", isError: true)
            return
        }
        let who = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await service.save(Benefit(
                projectID: project.id, title: trimmed,
                measure: measure.trimmingCharacters(in: .whitespacesAndNewlines),
                baselineValue: baselineValue, target: target, reviewAt: reviewAt,
                owner: who.isEmpty ? .agent(.teamLead) : .human(who)))
            await refreshGate()
        } catch {
            status = Status(message: "บันทึกประโยชน์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// Recording the measurement. Works on a closed project on purpose — the
    /// review date is usually after closing, and §19.12 asks for the review, not
    /// for somebody to reopen the project to hold it.
    public func measure(_ benefit: Benefit, value: Double, by person: String,
                        note: String = "") async {
        guard let service else { return }
        do {
            try await service.measure(benefit, value: value, by: person, note: note)
            await refreshGate()
            status = Status(message: "บันทึกผลการวัดแล้ว", isError: false)
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    public func removeBenefit(_ benefit: Benefit) async {
        guard let service, let project = selected else { return }
        do {
            try await service.removeBenefit(benefit.id, from: project.id)
            await refreshGate()
        } catch {
            status = Status(message: "ลบไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: - reporting (§19.13)

    /// Issues one of the three reports, keeps it, and writes the file beside the
    /// project's other documents.
    ///
    /// Returns the text so the caller can send it — the same string that is in
    /// the `.docx`, because a report that reads differently on a phone than in
    /// the file is two reports.
    @discardableResult
    public func issueReport(_ kind: ReportKind) async -> String? {
        guard let service, let project = selected else { return nil }
        do {
            guard let report = try await service.issueReport(kind, for: project.id) else {
                return nil
            }
            var note = "\(kind.label)ออกแล้ว"
            if let paths {
                // A row is not a deliverable. §19.13 says these go through
                // DocGen, and a report nobody can attach to an email is a report
                // that gets rewritten by hand.
                let folder = paths.project(project.id).documentsDirectory
                let file = folder.appending(path: ReportDocument.filename(report) + ".docx")
                do {
                    try FileManager.default.createDirectory(at: folder,
                                                            withIntermediateDirectories: true)
                    // P9.5 — off the main actor (E.29).
                    try await Task.detached(priority: .userInitiated) {
                        try ReportDocument.docx(report).write(to: file, options: .atomic)
                    }.value
                    note += " · \(file.lastPathComponent)"
                } catch {
                    log.error("writing report: \(error)")
                    note += " · เก็บเป็นข้อมูลแล้ว แต่เขียนไฟล์ไม่ได้: \(error.localizedDescription)"
                }
            }
            await refreshGate()
            // The same call a person makes, so nothing arrives by a path that
            // skips what manual issuing checks (§19.13, P10.13).
            await refreshReportDue()
            status = Status(message: note, isError: false)
            return report.rendered
        } catch {
            status = Status(message: "ออกรายงานไม่สำเร็จ: \(error)", isError: true)
            return nil
        }
    }

    // MARK: - conformance and closing (§19.12, §19.15)

    /// Writing down that a practice is not being done. The name and the reason
    /// are both required by `TailoringRecord.decided`, so a blank form comes
    /// back as an error rather than as a green tick.
    public func tailor(_ practice: Practice, reason: String, by person: String) async {
        guard let service, let project = selected else { return }
        do {
            try await service.tailor(practice, in: project.id, reason: reason, by: person)
            await refreshGate()
            status = Status(message: "บันทึกไว้แล้วว่าไม่ทำ \(practice.label) — พร้อมเหตุผลและชื่อคนตัดสิน",
                            isError: false)
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    public func decideDisposition(action: DataDisposition.Action, policy: String,
                                  by person: String, note: String = "") async {
        guard let service, let project = selected else { return }
        do {
            _ = try await service.decideDisposition(
                DataDisposition(action: action, policy: policy, decidedBy: person, note: note),
                for: project.id)
            await reload()
            status = Status(message: "บันทึกแล้วว่าข้อมูลที่เหลือจะ\(action.label) — ระบบไม่ลบไฟล์ให้เอง",
                            isError: false)
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    /// The cycle for automatic highlight reports (§19.13, P10.13). Held on
    /// the screen rather than on the project row: it is a preference about how
    /// often somebody wants telling, not part of the agreement a baseline
    /// holds.
    public var reportCycle: ReportSchedule.Cycle = .off {
        didSet { UserDefaults.standard.set(reportCycle.rawValue, forKey: Self.cycleKey) }
    }
    static let cycleKey = "co-ai.report-cycle"

    /// Whether a highlight report is due, and for what period. Asked when a
    /// project is opened — there is no daemon, and a scheduler that pretended
    /// otherwise would report Tuesday on Thursday.
    public private(set) var reportDue: ReportDue?

    func refreshReportDue() async {
        guard let project = selected, reportCycle != .off else { reportDue = nil; return }
        let last = await service?.reportHistory(of: project.id)
            .first { $0.kind == .highlight }?.generatedAt
        reportDue = ReportCycle.due(ReportSchedule(cycle: reportCycle),
                                    lastIssued: last,
                                    projectStarted: project.createdAt,
                                    now: Date())
    }

    // MARK: - registers (§19.11)

    public func record(_ detail: RegisterDetail, title: String) async {
        guard let service, let project = selected else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await service.record(RegisterEntry(projectID: project.id, title: trimmed,
                                                   detail: detail, origin: .human("ผู้ใช้")))
            await refreshGate()
        } catch {
            status = Status(message: "บันทึกไม่สำเร็จ: \(error)", isError: true)
        }
    }

    /// Deciding a change. The person's name goes in because that is what the
    /// register records — "approved" with nobody attached is the state §19.11
    /// exists to prevent.
    public func decide(_ entry: RegisterEntry, approve: Bool, by person: String) async {
        guard let service else { return }
        do {
            try await service.decideChange(entry, approve: approve, by: person)
            await refreshGate()
            status = Status(message: approve
                            ? "อนุมัติแล้ว — baseline เวอร์ชันใหม่ถูก freeze ไว้ ของเดิมยังอ่านได้"
                            : "ปฏิเสธแล้ว — baseline เดิมไม่ถูกแตะ",
                            isError: false)
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    /// Reads what can be read, and says which dimensions those are.
    ///
    /// Each source is the one §19.10 named: spans for time, the spend ledger
    /// for cost, the task ledger's retry count for quality, and the plan's own
    /// risk classes for risk, and the benefit ledger for benefit — which reads
    /// only once somebody has measured one, and says "ยังไม่ได้วัด" until then
    /// rather than showing a zero.
    private func measure(_ id: ProjectID) async {
        var reading = readings
        var known: Set<ToleranceDimension> = [.scope]

        if let spans {
            elapsed = (try? await spans.elapsedByWorkPackage(project: .init(id.rawValue))) ?? [:]
            await refreshTimeline(spans: spans, project: id)
            // After `elapsed`, because which leaves have started is read from
            // it — and work that has started is measured, never projected.
            refreshProjection(project: id)
            let spent = elapsed.values.reduce(0, +)
            // The frame is a multiple of how long this kind of work usually
            // takes, so an unfinished plan with no history has no ratio to
            // report — not a ratio of zero.
            if let estimate = await forecastBand(spans: spans, project: id), estimate.p90 > 0 {
                reading.timeRatio = spent / estimate.p90
                known.insert(.time)
            }
        }
        if let spend {
            let window = await spend.spend(now: Date())
            reading.spent = window.today
            known.insert(.cost)
        }
        if let ledger, let rows = try? await ledger.rows(scope: .project(id)) {
            reading.maxRework = Double(rows.map(\.attempts).max() ?? 0)
            known.insert(.quality)
        }
        // Risk needs no store: the plan already carries what each leaf is
        // classified as, and the open ones are the ones that could still bite.
        let openRisk = wbs.openLeaves.map(\.riskClass.rawValue).max() ?? 0
        reading.highestRisk = Double(openRisk)
        known.insert(.risk)
        // The sixth axis (§19.12, P10.10). Only counts once somebody has
        // actually measured something — benefits with no result leave the
        // reading alone and the strip keeps saying "ยังไม่ได้วัด", because a
        // business case that looks fine because nobody looked is the failure
        // this dimension exists to catch.
        if let achieved = benefits.lowestAchievement {
            reading.benefitRatio = achieved
            known.insert(.benefit)
        }

        readings = reading
        measured = known
        tolerances = ToleranceCheck.evaluate(selected?.tolerances ?? .balanced, readings: reading)
    }

    /// The four popovers that read stores rather than the project row
    /// (§19.2.3). Each source is named where it is read, for the same reason the
    /// tolerance readings are: a dashboard number nobody can trace is a number
    /// nobody can argue with when it decides something.
    private func refreshStatusDetail(_ id: ProjectID) async {
        if let spend, let split = try? await spend.breakdown(since: startOfMonth()) {
            spendByRole = split.byRole.map { Slice(key: $0.key, amount: $0.costUSD) }
            spendByModel = split.byModel.map { Slice(key: $0.key, amount: $0.costUSD) }
            spendTotal = split.total
        }
        if let spans {
            toolActivity = ((try? await spans.toolActivity(project: id)) ?? [])
                .map { ToolSlice(tool: $0.tool, calls: $0.calls, seconds: $0.seconds) }
            // The band the time popover draws. Across projects on purpose: the
            // whole point of a p90 is that it comes from more than the project
            // asking for it.
            forecast = await forecastBand(spans: spans, project: id)
        }
        if let ledger, let rows = try? await ledger.rows(scope: .project(id)) {
            // Only the rounds that were actually redone. A row with one attempt
            // is work, not rework, and listing it would bury the ones that hurt.
            rework = rows.filter { $0.attempts > 1 || $0.needsHuman }
                .sorted { $0.attempts > $1.attempts }
                .map { ReworkRow(goal: $0.goal, role: $0.role.rawValue, attempts: $0.attempts,
                                 findings: $0.findings, needsHuman: $0.needsHuman) }
        }
    }

    private func startOfMonth() -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    }

    // MARK: - the status bar's actions (§19.2.3)

    /// Runs a status-bar action. Every one of them writes to the register on the
    /// way through (`ProjectService.perform`), which is the half of this feature
    /// that keeps a one-click dashboard from being a place decisions vanish.
    public func perform(_ action: StatusAction) async {
        guard let service, let project = selected else { return }
        do {
            try await service.perform(action, in: project.id)
            await refreshGate()
            status = Status(message: "\(action.title) — บันทึกลงทะเบียนแล้ว", isError: false)
        } catch {
            status = Status(message: "\(error)", isError: true)
        }
    }

    private func refreshGate() async {
        guard let service, case .project(let id) = selection else {
            gate = nil
            wbs = WorkBreakdown()
            problems = []
            return
        }
        wbs = await service.breakdown(of: id)
        problems = wbs.problems(inScope: selected?.statement.inScope ?? [])
        openExceptions = (try? await service.openExceptions(id)) ?? []
        registers = await service.entries(of: id)
        baselines = await service.baselineHistory(of: id)
        drift = await service.drift(of: id)
        // The scope tolerance reads drift from the agreement rather than the
        // size of the plan: a project is not off-scope for having a plan, only
        // for having grown one past what was agreed (§19.10).
        readings.addedPackages = drift?.addedCount ?? 0
        benefits = await service.benefitLedger(of: id)
        await measure(id)
        // Order matters here: what the app measured has to reach the service
        // *before* the gate is asked, because G4's conformance condition counts
        // money and time this screen is the only one that can read (§19.16).
        await service.observe(ObservedFacts(readings: readings,
                                           measured: measured,
                                           measuredSeconds: elapsed.values.reduce(0, +)))
        conformance = await service.conformance(of: id)
        gate = await service.gate(for: id)
        reports = await service.reportHistory(of: id)
        await refreshStatusDetail(id)
    }
}
