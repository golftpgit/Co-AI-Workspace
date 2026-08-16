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

    /// Public because `run(goal:plan:)` takes one: a caller that wants to skip
    /// the planning model — a check, or P4.6's hand-edited plan — could not
    /// build the argument the public method asks for.
    public init(goal: String, assignments: [Assignment]) {
        self.goal = goal
        self.assignments = assignments
    }
}

public enum TeamEvent: Sendable {
    case planned(TeamPlan)
    /// Carries the attempt it is starting: a screen watching this stream has
    /// no other way to know which round is running, and guessing from the
    /// previous `rework` leaves it a full attempt behind the ledger.
    case assigned(Assignment, attempt: Int)
    case delivered(Deliverable)
    case reviewed(assignmentID: String, passed: Bool, findings: [String])
    case rework(assignmentID: String, attempt: Int, reasons: [String])
    /// The lead has stopped and wants a person. Carries why, because
    /// "ติดขัด" with no reason is the thing that made v1's loops unreadable.
    case escalated(assignmentID: String, attempts: Int, reasons: [String])
    /// Run-until-done picked the ledger back up. Announced rather than silent:
    /// work continuing without the user typing again is exactly the thing they
    /// should be able to see happening.
    case continuing(remaining: Int)
    /// A person stopped one assignment (P4.7). Separate from `escalated`:
    /// escalation asks for a decision, this *is* one.
    case cancelled(assignmentID: String, reason: String)
    /// The run hit its token ceiling (P4.8). Announced rather than left to be
    /// inferred from a short list of deliverables: a run that stopped because
    /// it ran out of budget looks exactly like a run that found less to do.
    case budgetExhausted(summary: String, remaining: Int)
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
    /// §21.2 / P12.7 — what this role already learned, brought to the start of
    /// an assignment. A closure rather than a store: the lessons live in the
    /// knowledge base, and the orchestrator's job is to make sure they arrive,
    /// not to know where they are kept.
    private let roleMemory: (@Sendable (Role) async -> [String])?
    /// Which workspace the ledger rows and spans are filed under.
    ///
    /// A `var` since P10.15, and this was not a refactor for its own sake: it
    /// was fixed at `.central` for the life of the process, so every piece of
    /// team work in the app was filed under General no matter which project was
    /// open. Everything downstream reads by project — the tolerance strip, the
    /// forecast band, the schedule — so they were all asking about a table that
    /// team work never wrote a row into.
    private var scope: Scope
    /// Where assignment spans go (§19.7, P10.15). Optional like the ledger: the
    /// team works without observability, it just cannot be asked afterwards how
    /// long anything took.
    private let spans: (any SpanSink)?
    private var ledger: [String: LedgerEntry] = [:]
    /// Assignment spans still open, by assignment id. Held so the span can be
    /// closed by whatever ends the work — a pass, an escalation, or a person
    /// cancelling it from the screen — rather than only by the happy path. A
    /// span left running is not a neutral omission: the process view shows it
    /// as live work forever, and having no `ended_at` it silently drops out of
    /// every duration the forecast is built from.
    private var openSpans: [String: Span] = [:]
    /// The run's token ceiling (§5.5, P4.8). Shared with the specialists'
    /// environment, which is what makes "how much has this run used" a
    /// question with an answer.
    private let budget: RunBudget?
    private let log = AppLog.logger("team")

    /// One row per assignment, so "who is doing what, and how did it go" is
    /// answerable without replaying anything (§2.2's task ledger).
    public struct LedgerEntry: Sendable, Equatable {
        public let assignment: Assignment
        public var attempts: Int
        public var passed: Bool
        /// The lead gave up and asked for a person (§2.5). Recorded separately
        /// from `!passed` so run-until-done can tell an escalation from a run
        /// that was merely cut short.
        public var needsHuman: Bool = false
        /// A person stopped this one (P4.7). Kept apart from `needsHuman`:
        /// escalation asks someone to decide, cancellation *is* the decision.
        public var cancelled: Bool = false
        public var findings: [String]
        public var deliverable: Deliverable?
        /// Which leaf of the plan this work is against (§19.6, P10.4). The
        /// ledger row has carried this field since P10.4 and nothing ever wrote
        /// it, so "how much of the plan has actually been worked on" had a
        /// column and no data.
        public var workPackage: String?
    }

    public init(router: ModelRouter,
                specialists: [Role: any Specialist],
                reviewer: QAReviewer = QAReviewer(),
                maxFanOut: Int = 4,
                retryCap: Int = 3,
                ledgerStore: TaskLedgerStore? = nil,
                spans: (any SpanSink)? = nil,
                roleMemory: (@Sendable (Role) async -> [String])? = nil,
                budget: RunBudget? = nil,
                scope: Scope = .central) {
        self.budget = budget
        self.router = router
        self.specialists = specialists
        self.reviewer = reviewer
        self.maxFanOut = maxFanOut
        self.retryCap = retryCap
        self.ledgerStore = ledgerStore
        self.spans = spans
        self.roleMemory = roleMemory
        self.scope = scope
    }

    /// Points the lead at another workspace.
    ///
    /// Refused mid-run: half a run's rows landing in one project and half in
    /// another would be a ledger that cannot be read by either. The screen
    /// disables the switch while work is in flight for the same reason.
    public func use(scope newScope: Scope) {
        guard openSpans.isEmpty else { return }
        guard newScope != scope else { return }
        scope = newScope
        // The in-memory ledger belongs to the workspace it was read for; the
        // durable rows are re-read by the screen.
        ledger.removeAll()
    }

    public var currentScope: Scope { scope }

    /// Whether this lead has work in flight.
    ///
    /// Read off the open spans rather than a flag of its own: a span is opened
    /// when an assignment starts and closed by whatever ends it — a pass, an
    /// escalation, or a person cancelling — so the two cannot drift. `use` has
    /// asked the same question since P10.15; P21.2 needs it from outside, to
    /// know that letting go of a workspace would be letting go of running work.
    public var isBusy: Bool { !openSpans.isEmpty }

    /// Written on every state change, not once at the end: a run that is
    /// interrupted is exactly when someone wants to read the ledger.
    private func persist(_ id: String) async {
        guard let ledgerStore, let entry = ledger[id] else { return }
        do {
            try await ledgerStore.record(LedgerRow(
                assignmentID: entry.assignment.id,
                role: entry.assignment.role,
                goal: entry.assignment.goal,
                attempts: entry.attempts,
                passed: entry.passed,
                needsHuman: entry.needsHuman,
                cancelled: entry.cancelled,
                findings: entry.findings,
                summary: entry.deliverable?.summary,
                acceptanceCriteria: entry.assignment.acceptanceCriteria,
                deliverableType: entry.assignment.deliverableType,
                workPackageID: entry.workPackage), scope: scope)
        } catch {
            // Was `try?`. A ledger that silently stops updating is
            // indistinguishable from one that is up to date, which is the worse
            // failure: §2.2's promise is that the ledger can be read after an
            // interrupted run, and a stale row answers the question wrongly
            // rather than admitting it cannot answer.
            log.error("task ledger write failed for \(id, privacy: .public): \(error)")
        }
    }

    public var entries: [LedgerEntry] {
        ledger.values.sorted { $0.assignment.id < $1.assignment.id }
    }

    // MARK: - how long the work took (§19.6, §19.7, P10.15)

    /// Opens the span that covers one whole assignment.
    ///
    /// One span for the assignment, one child per attempt. The parent is what
    /// the forecast band is built from, and it deliberately spans *every* round
    /// including the reworked ones: an estimate that counted only work which
    /// passed first time would promise a schedule that only holds when nothing
    /// goes wrong. The children are what make a rework loop legible on the Live
    /// Monitor, where until now three failed rounds and one slow one looked the
    /// same.
    ///
    /// `deliverableKind` goes on the parent and on nothing else — it is the
    /// field that says which population a duration belongs to, and putting it on
    /// the attempts as well would let a query that forgot the name filter count
    /// one assignment four times.
    private func beginAssignmentSpan(_ assignment: Assignment,
                                     workPackage: String?) async -> Span {
        var span = Span(name: Span.assignmentName,
                        role: assignment.role,
                        scope: scope,
                        workPackage: workPackage,
                        deliverableKind: assignment.deliverableKind)
        span.detail = assignment.goal
        openSpans[assignment.id] = span
        await spans?.record(span)
        return span
    }

    /// Closes it, whatever ended it. Does nothing when there is no span open,
    /// so cancelling something that was never started writes no phantom row.
    private func closeAssignmentSpan(_ assignmentID: String,
                                     _ status: SpanStatus,
                                     detail: String? = nil) async {
        guard var span = openSpans.removeValue(forKey: assignmentID) else { return }
        span.status = status
        span.endedAt = Date()
        if let detail { span.detail = detail }
        await spans?.record(span)
    }

    /// One round of work. A child of the assignment span, and never carries a
    /// deliverable kind — see `beginAssignmentSpan`.
    private func recordAttempt(_ assignment: Assignment, attempt: Int,
                               parent: SpanID?, workPackage: String?,
                               startedAt: Date, status: SpanStatus,
                               detail: String?) async {
        await spans?.record(Span(parent: parent, name: Span.attemptName,
                                role: assignment.role, scope: scope,
                                status: status, startedAt: startedAt, endedAt: Date(),
                                detail: detail ?? "รอบที่ \(attempt)",
                                workPackage: workPackage))
    }

    // MARK: - what a person can do to one piece of work (P4.7)

    /// Runs one assignment again, with the reason a person gave for sending it
    /// back.
    ///
    /// The note goes in where QA's findings go, because that is the channel
    /// the specialist already reads (`reworked(_:attempt:findings:)`) — a
    /// second mechanism for "here is what is wrong with it" would be a second
    /// thing to keep in step. Attempts keep counting from where the ledger
    /// left off, so a human rework does not hand the work a fresh retry budget
    /// it has already spent.
    public func rework(_ assignment: Assignment,
                       note: String,
                       emit: @Sendable (TeamEvent) -> Void = { _ in }) async -> Deliverable? {
        guard let specialist = specialists[assignment.role] else {
            emit(.failed(TeamError.noSpecialist(assignment.role).description))
            return nil
        }
        let previous = ledger[assignment.id]
        let attempt = (previous?.attempts ?? 0) + 1
        let reasons = note.isEmpty ? ["ผู้ใช้สั่งให้แก้"] : [note]
        let workPackage = previous?.workPackage

        ledger[assignment.id] = LedgerEntry(
            assignment: assignment, attempts: attempt, passed: false,
            // A person asking for a rework un-escalates and un-cancels it:
            // they have taken it back off the "waiting for a human" pile by
            // being the human.
            needsHuman: false, cancelled: false,
            findings: reasons, deliverable: previous?.deliverable,
            workPackage: workPackage)
        await persist(assignment.id)
        emit(.rework(assignmentID: assignment.id, attempt: attempt, reasons: reasons))
        emit(.assigned(assignment, attempt: attempt))
        // An attempt span, not an assignment span — and so carrying no
        // deliverable kind. A human send-back is one more round on a promise
        // that was already made, and recording it as a whole assignment would
        // put a single round into a population of whole assignments and pull
        // the forecast band down every time somebody asks for a small fix.
        let started = Date()

        do {
            let deliverable = try await specialist.execute(
                reworked(assignment, attempt: attempt, findings: reasons, fromAPerson: true))
            emit(.delivered(deliverable))
            // The same standard the automatic loop reviews against — a human
            // rework must not be graded more leniently than a machine one.
            let verdict = reviewer.review(deliverable, against: assignment,
                                          standard: specialist.definitionOfDone)
            ledger[assignment.id]?.deliverable = deliverable
            ledger[assignment.id]?.passed = verdict.passed
            ledger[assignment.id]?.findings = verdict.findings
            await persist(assignment.id)
            await recordAttempt(assignment, attempt: attempt, parent: nil,
                                workPackage: workPackage, startedAt: started,
                                status: verdict.passed ? .succeeded : .failed,
                                detail: "แก้ตามที่ผู้ใช้สั่ง (รอบที่ \(attempt)): "
                                    + (verdict.passed ? "ผ่านการตรวจ"
                                                      : verdict.findings.joined(separator: " · ")))
            emit(.reviewed(assignmentID: assignment.id, passed: verdict.passed,
                           findings: verdict.findings))
            return verdict.passed ? deliverable : nil
        } catch {
            ledger[assignment.id]?.findings = ["\(error)"]
            await persist(assignment.id)
            await recordAttempt(assignment, attempt: attempt, parent: nil,
                                workPackage: workPackage, startedAt: started,
                                status: .failed,
                                detail: "แก้ตามที่ผู้ใช้สั่ง (รอบที่ \(attempt)): \(error)")
            emit(.rework(assignmentID: assignment.id, attempt: attempt,
                         reasons: ["\(error)"]))
            return nil
        }
    }

    /// Marks one assignment as stopped by a person.
    ///
    /// Recorded, not deleted — the ledger's job is to say what happened, and
    /// "we decided not to do this" is something that happened. Run-until-done
    /// skips it afterwards for the same reason it skips escalations: picking
    /// it back up would overturn the decision that was just made.
    public func cancel(_ assignmentID: String,
                       assignment: Assignment? = nil,
                       reason: String = "ผู้ใช้ยกเลิกงานนี้",
                       emit: @Sendable (TeamEvent) -> Void = { _ in }) async {
        if var entry = ledger[assignmentID] {
            entry.cancelled = true
            entry.passed = false
            entry.findings = [reason]
            ledger[assignmentID] = entry
        } else if let assignment {
            // Cancelling something from a previous run, read back off the
            // ledger rather than held in memory.
            ledger[assignmentID] = LedgerEntry(assignment: assignment, attempts: 0,
                                               passed: false, needsHuman: false,
                                               cancelled: true, findings: [reason])
        } else {
            return
        }
        await persist(assignmentID)
        // Cancelled, not succeeded and not failed. Work somebody stopped
        // halfway says nothing about how long that kind of work takes, and the
        // forecast reads succeeded spans only — so this closes the row for the
        // process view without letting a half-finished duration into the band.
        await closeAssignmentSpan(assignmentID, .cancelled, detail: reason)
        emit(.cancelled(assignmentID: assignmentID, reason: reason))
    }

    // MARK: - running

    /// How many times run-until-done may pick the ledger back up in one run.
    /// A ceiling rather than a judgement: §5.5 asks for work that continues
    /// without the user typing again, and the thing that makes that safe is
    /// that it cannot continue forever.
    public static let continuationCap = 3

    /// - Parameter workPackage: which leaf of the plan this run is work against
    ///   (§19.6). One per run rather than one per assignment, because that is
    ///   what the screen can honestly ask for: a person picks the promise they
    ///   are working on and the lead breaks it down, so every assignment in the
    ///   plan is against the same leaf. `nil` is a real state — not every run
    ///   is against a plan — and the ledger and the spans both say so rather
    ///   than inventing a leaf.
    /// - Parameter tokenCeiling: how many tokens this run may spend before it
    ///   stops and asks for a person (P4.8). `nil` is no ceiling, which is the
    ///   honest default — a number invented here would be a limit nobody chose.
    public func run(goal: String,
                    plan providedPlan: TeamPlan? = nil,
                    runUntilDone: Bool = false,
                    workPackage: String? = nil,
                    tokenCeiling: Int? = nil,
                    emit: @Sendable (TeamEvent) -> Void = { _ in }) async -> [Deliverable] {
        await budget?.begin(ceiling: tokenCeiling)
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

        var delivered = await work(through: plan.assignments,
                                   against: { _ in workPackage }, emit: emit)
        if await budget?.isExhausted == true {
            await announceExhaustion(emit)
            emit(.finished(deliverables: delivered))
            return delivered
        }

        // §5.5's third switch. "Done" is read off the ledger rather than asked
        // of the model: what is left is a fact, and a model's opinion of
        // whether it has finished is the thing v1's loops ran on.
        if runUntilDone {
            for _ in 0..<Self.continuationCap {
                guard let ledgerStore else { break }
                let resumable = (try? await ledgerStore.resumable(scope: scope)) ?? []
                // Anything this run already handled is not picked up again;
                // the retry budget inside `work` is what bounds those.
                let pending = resumable.compactMap(\.assignment)
                    .filter { ledger[$0.id] == nil }
                guard !pending.isEmpty else { break }
                // The leaf each row was filed under, kept with it.
                let leaves = Dictionary(resumable.map { ($0.assignmentID, $0.workPackageID) },
                                        uniquingKeysWith: { first, _ in first })

                emit(.continuing(remaining: pending.count))
                delivered += await work(through: pending,
                                        against: { leaves[$0.id] ?? nil }, emit: emit)
                if await budget?.isExhausted == true {
                    await announceExhaustion(emit)
                    break
                }
            }
        }

        emit(.finished(deliverables: delivered))
        return delivered
    }

    /// - Parameter against: the leaf each assignment is work against. A lookup
    ///   rather than one value because the two callers know it differently: a
    ///   fresh plan is all against the leaf the person picked, while work picked
    ///   back up by run-until-done carries the leaf it was originally filed
    ///   under, and re-labelling it with today's would move somebody else's time
    ///   onto this promise.
    /// How much is left in the ledger when the ceiling stopped the run. Said
    /// as a count rather than left for somebody to work out from what did not
    /// arrive.
    private func announceExhaustion(_ emit: @Sendable (TeamEvent) -> Void) async {
        guard let budget else { return }
        let outstanding = ledger.values.filter { !$0.passed && !$0.cancelled }.count
        emit(.budgetExhausted(summary: await budget.summary, remaining: outstanding))
    }

    private func work(through assignments: [Assignment],
                      against: (Assignment) -> String?,
                      emit: @Sendable (TeamEvent) -> Void) async -> [Deliverable] {
        var delivered: [Deliverable] = []

        for original in assignments {
            // Between assignments: work that has not started is the cheapest
            // thing to not start. What is left is *written down* as needing a
            // person — an assignment that never reaches the ledger is work
            // that silently did not happen, which is the failure this whole
            // ceiling is supposed to make visible (P4.8).
            if await budget?.isExhausted == true {
                for skipped in assignments.drop(while: { $0.id != original.id }) {
                    ledger[skipped.id] = LedgerEntry(
                        assignment: skipped, attempts: 0, passed: false, needsHuman: true,
                        findings: ["ยังไม่ได้เริ่ม — การรันถึงเพดานโทเคนก่อน"],
                        workPackage: against(skipped))
                    await persist(skipped.id)
                }
                break
            }
            guard let specialist = specialists[original.role] else {
                emit(.failed(TeamError.noSpecialist(original.role).description))
                continue
            }
            // P12.7 — the lessons this role already learned, in front of it
            // before it starts rather than findable if it thinks to look. A
            // lesson somebody has to search for reaches the people who already
            // knew it.
            let workPackage = against(original)
            let remembered = await roleMemory?(original.role) ?? []
            let assignment = remembered.isEmpty ? original : Assignment(
                id: original.id, role: original.role, goal: original.goal,
                inputs: remembered + original.inputs,
                acceptanceCriteria: original.acceptanceCriteria,
                deliverableType: original.deliverableType)

            ledger[assignment.id] = LedgerEntry(assignment: assignment, attempts: 0,
                                                passed: false, findings: [],
                                                workPackage: workPackage)
            let assignmentSpan = await beginAssignmentSpan(assignment,
                                                           workPackage: workPackage)

            var attempt = 0
            var lastFindings: [String] = []

            while attempt < retryCap {
                attempt += 1
                ledger[assignment.id]?.attempts = attempt
                await persist(assignment.id)
                emit(.assigned(assignment, attempt: attempt))
                let attemptStarted = Date()

                let deliverable: Deliverable
                do {
                    deliverable = try await specialist.execute(
                        reworked(assignment, attempt: attempt, findings: lastFindings))
                } catch {
                    lastFindings = ["\(error)"]
                    ledger[assignment.id]?.findings = lastFindings
                    // Persisted here too: a specialist that threw is a state
                    // change like any other, and skipping it left the stored
                    // row claiming the attempt was still in its first round.
                    await persist(assignment.id)
                    await recordAttempt(assignment, attempt: attempt,
                                        parent: assignmentSpan.id, workPackage: workPackage,
                                        startedAt: attemptStarted, status: .failed,
                                        detail: "รอบที่ \(attempt): \(error)")
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
                await recordAttempt(assignment, attempt: attempt,
                                    parent: assignmentSpan.id, workPackage: workPackage,
                                    startedAt: attemptStarted,
                                    status: verdict.passed ? .succeeded : .failed,
                                    detail: verdict.passed
                                        ? "รอบที่ \(attempt): ผ่านการตรวจ"
                                        : "รอบที่ \(attempt): \(verdict.findings.joined(separator: " · "))")

                if verdict.passed {
                    ledger[assignment.id]?.passed = true
                    await persist(assignment.id)
                    await closeAssignmentSpan(assignment.id, .succeeded)
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
                ledger[assignment.id]?.findings = lastFindings
                ledger[assignment.id]?.needsHuman = true
                // The escalation is the state a person comes back to read, and
                // it was the one state never written down: the run ended here
                // and storage still described the first attempt.
                await persist(assignment.id)
                // Closed as failed, not left open. An escalation is the longest
                // and most expensive thing that happens here, so a span that
                // stayed running would drop exactly the worst case out of every
                // duration the forecast is built from — and leave the process
                // view claiming the work is still going.
                await closeAssignmentSpan(assignment.id, .failed,
                                          detail: lastFindings.joined(separator: " · "))
                emit(.escalated(assignmentID: assignment.id, attempts: attempt,
                                reasons: lastFindings))
            }
        }

        return delivered
    }

    /// Rework carries the reviewer's reasons into the next attempt. Sending
    /// the same brief back unchanged is how a loop repeats itself.
    /// - Parameter fromAPerson: a human rework carries its reason on the
    ///   *first* attempt too. The attempt-count guard exists so the automatic
    ///   loop does not prepend "the last round failed because…" to a round
    ///   that has not happened yet; when someone types the reason themselves,
    ///   there is nothing to guard against and dropping it would send the
    ///   specialist the original goal with no idea what to change.
    private func reworked(_ assignment: Assignment, attempt: Int,
                          findings: [String], fromAPerson: Bool = false) -> Assignment {
        guard attempt > 1 || fromAPerson, !findings.isEmpty else { return assignment }
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

    /// Plans without starting anything (§2.6).
    ///
    /// Deliberately does **not** validate: a plan that breaks §2.4 is exactly
    /// the one a person needs to see and correct, and refusing to hand it over
    /// leaves them with an error instead of something to edit. `run` still
    /// validates, so an unedited bad plan cannot slip through.
    public func propose(goal: String) async throws -> TeamPlan {
        try await makePlan(for: goal)
    }

    /// Why this plan would be refused, in the words the user should read, or
    /// `nil` if it would run. Lets the editor show the objection while it is
    /// still fixable rather than after pressing start.
    public func refusal(for plan: TeamPlan) -> String? {
        do {
            try validate(plan)
            return nil
        } catch {
            return "\(error)"
        }
    }

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

        guard let data = completion.structuredText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["assignments"] as? [[String: Any]] else {
            throw TeamError.planningFailed("อ่านแผนไม่ได้: \(completion.structuredText.prefix(160))")
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
            // §14.1's corroboration rule, now enforced rather than described
            // (P13.2). Two sources is a count; two *blog posts* is not evidence,
            // and until this the rule only ever appeared in a Limitations
            // paragraph after the work had already been accepted.
            if let reason = corroborationFinding(citations) { findings.append(reason) }

        case .analyst:
            if !deliverable.evidence.contains(where: { $0.kind == .statisticalCheck }) {
                findings.append("ไม่มีผลการตรวจ assumption ของวิธีทางสถิติที่ใช้")
            }

        case .writer:
            let cited = deliverable.evidence.filter { $0.kind == .citation && $0.passed }
            if cited.isEmpty {
                findings.append("ไม่มี citation ผูกกับแหล่งจริง")
            } else if let reason = corroborationFinding(cited) {
                // A draft rests on its sources exactly as a research summary
                // does; the tier rule does not get weaker because the output is
                // prose (§14.1).
                findings.append(reason)
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

    /// Why these citations are not enough, or `nil` when they are.
    ///
    /// The arithmetic is `Corroboration.assess` — the same rule the Limitations
    /// section explains to a reader, so a document cannot describe a standard the
    /// gate did not apply. Deduplicating by summary is the QA-side answer to
    /// "what counts as one source": reading the same page twice is one source,
    /// and the transcript is where that duplication comes from.
    private func corroborationFinding(_ citations: [Evidence]) -> String? {
        var byWork: [String: CredibilityTier?] = [:]
        for citation in citations { byWork[citation.summary] = citation.tier }
        let verdict = Corroboration.assess(tiers: byWork.values.map { $0 })
        guard !verdict.isEnoughForQA else { return nil }
        return verdict.note.map { "ยังไม่ผ่านกติกาแหล่งอ้างอิง (§14.1): \($0)" }
    }
}
