import Foundation
import Observation
import AgentKit
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
    public enum Selection: Equatable {
        case general
        case project(ProjectID)
    }

    public struct Status: Equatable {
        public var message: String
        public var isError: Bool
    }

    public private(set) var projects: [Project] = []
    public private(set) var status: Status?
    public private(set) var isWorking = false
    public private(set) var selection: Selection = .general
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

    private var service: ProjectService?
    /// Where a project's documents live (§19.1). Optional because the screen
    /// works without it — a report still becomes a row, it just does not become
    /// a file, and that is the honest degradation.
    private var paths: AppPaths?
    private var spans: SurrealSpanSink?
    private var spend: SurrealSpendLedger?
    private var ledger: TaskLedgerStore?
    private let log = AppLog.logger("projects-ui")

    public init() {}

    /// What every other screen asks for. General is `central`: shared
    /// knowledge, no ledger, no lifecycle.
    public var scope: Scope {
        switch selection {
        case .general: .central
        case .project(let id): .project(id)
        }
    }

    public var selected: Project? {
        guard case .project(let id) = selection else { return nil }
        return projects.first { $0.id == id }
    }

    public var openProjects: [Project] { projects.filter(\.isOpen) }

    public func attach(service: ProjectService) async {
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
    }

    public func reload() async {
        guard let service else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            projects = try await service.projects()
            // A project deleted or closed elsewhere must not leave the app
            // pointed at it; falling back to General is always safe.
            if case .project(let id) = selection, !projects.contains(where: { $0.id == id }) {
                selection = .general
            }
            await refreshGate()
        } catch {
            log.error("loading projects: \(error)")
            status = Status(message: "โหลดรายการโปรเจกต์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func select(_ selection: Selection) async {
        self.selection = selection
        status = nil
        await refreshGate()
    }

    public func create(name: String, kind: ProjectKind) async {
        guard let service else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = Status(message: "ตั้งชื่อโปรเจกต์ก่อน", isError: true)
            return
        }
        do {
            let project = try await service.create(name: trimmed, kind: kind)
            await reload()
            await select(.project(project.id))
            status = Status(message: "สร้าง '\(trimmed)' แล้ว — อยู่ขั้นเริ่มต้น", isError: false)
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
            await select(.project(project.id))
            status = Status(
                message: draft.isReadyForG1
                    ? "ยกระดับเป็นโปรเจกต์แล้ว — ตรวจขอบเขตอีกครั้งแล้วกดผ่าน G1 ได้เลย"
                    : "ยกระดับเป็นโปรเจกต์แล้ว — ยังผ่าน G1 ไม่ได้จนกว่าจะเติมช่องที่ค้าง",
                isError: false)
        } catch {
            status = Status(message: "ยกระดับเป็นโปรเจกต์ไม่สำเร็จ: \(error)", isError: true)
        }
    }

    // MARK: - the plan

    public func addPackage(title: String, parent: String?) async {
        guard let service, let project = selected else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let siblings = wbs.children(of: parent)
        do {
            try await service.save(WorkPackage(
                projectID: project.id,
                parent: parent,
                title: trimmed,
                // Pre-filled when the project has exactly one thing in scope,
                // because that is the common case and an empty required field
                // teaches people to ignore required fields.
                scopeRef: project.statement.inScope.count == 1
                    ? project.statement.inScope.first : nil,
                acceptanceCriteria: [],
                order: (siblings.map(\.order).max() ?? -1) + 1))
            await refreshGate()
        } catch {
            status = Status(message: "เพิ่มใบงานไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func update(_ package: WorkPackage) async {
        guard let service else { return }
        do {
            try await service.save(package)
            await refreshGate()
        } catch {
            status = Status(message: "บันทึกใบงานไม่สำเร็จ: \(error)", isError: true)
        }
    }

    public func removePackage(_ packageID: String) async {
        guard let service, let project = selected else { return }
        do {
            try await service.removePackage(packageID, from: project.id)
            await refreshGate()
        } catch {
            status = Status(message: "ลบใบงานไม่สำเร็จ: \(error)", isError: true)
        }
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

    public func setTolerances(_ preset: Tolerances) async {
        guard var project = selected else { return }
        project.tolerances = preset
        await update(project)
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
                    try ReportDocument.docx(report).write(to: file, options: .atomic)
                    note += " · \(file.lastPathComponent)"
                } catch {
                    log.error("writing report: \(error)")
                    note += " · เก็บเป็นข้อมูลแล้ว แต่เขียนไฟล์ไม่ได้: \(error.localizedDescription)"
                }
            }
            await refreshGate()
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
            let spent = elapsed.values.reduce(0, +)
            // The frame is a multiple of how long this kind of work usually
            // takes, so an unfinished plan with no history has no ratio to
            // report — not a ratio of zero.
            let history = (try? await spans.durations(forRole: .analyst)) ?? []
            if let estimate = Schedule.estimate(from: history), estimate.p90 > 0 {
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
    }
}
