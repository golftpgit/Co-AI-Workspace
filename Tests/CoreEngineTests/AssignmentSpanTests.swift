import Testing
import Foundation
import AgentKit
import LLMProviders
import Observability
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// Assignment spans (ARCHITECTURE §16, §19.6, §19.7 · P10.15's outstanding half).
//
// `TeamOrchestrator` emitted no spans at all. Every tool call, every model call
// and every chat turn wrote one, and the part of the system that does the actual
// work wrote none — so the schedule had no durations to draw and the forecast
// band had to be built out of chat turns, which is a different and smaller unit
// of work.
//
// What is worth testing is not "a span appears". It is the four ways a duration
// record lies about work:
//
//  • counting only the rounds that went well, so the estimate describes a day
//    where nothing goes wrong;
//  • leaving the span open when the work ends badly, which drops exactly the
//    slowest cases out of the population *and* leaves the process view claiming
//    the work is still running;
//  • letting work somebody stopped halfway count as evidence of how long that
//    kind of work takes;
//  • recording one round as though it were a whole assignment.
// ─────────────────────────────────────────────────────────────

private actor ScriptedSpecialist: Specialist {
    nonisolated let role: Role
    nonisolated let definitionOfDone: [Criterion] = []
    private var replies: [Deliverable]

    init(role: Role, replies: [Deliverable]) {
        self.role = role
        self.replies = replies
    }

    func execute(_ assignment: Assignment) async throws -> Deliverable {
        guard !replies.isEmpty else { throw SpecialistError.modelUnavailable("script exhausted") }
        let reply = replies.removeFirst()
        return Deliverable(assignmentID: assignment.id, summary: reply.summary,
                           evidence: reply.evidence)
    }
}

private let passingBuild = Evidence(kind: .commandExit, summary: "exit code: 0", passed: true)

private func deliverable(_ summary: String, evidence: [Evidence] = []) -> Deliverable {
    Deliverable(assignmentID: "", summary: summary, evidence: evidence)
}

private func assignment(_ id: String = "a1", kind: String = "โค้ดที่ผ่านเทส") -> Assignment {
    Assignment(id: id, role: .engineer, goal: "แก้เทสให้ผ่าน",
               acceptanceCriteria: [Criterion(text: "เทสผ่าน", evidenceRequired: "exit code 0")],
               deliverableType: kind)
}

private func plan(_ assignments: [Assignment]) -> TeamPlan {
    TeamPlan(goal: "แก้เทส", assignments: assignments)
}

private func orchestrator(_ specialist: any Specialist, sink: InMemorySpanSink,
                          retryCap: Int = 3,
                          scope: Scope = .project(ProjectID("pj_spans"))) -> TeamOrchestrator {
    TeamOrchestrator(router: ModelRouter(executors: []),
                     specialists: [specialist.role: specialist],
                     retryCap: retryCap, spans: sink, scope: scope)
}

private extension InMemorySpanSink {
    /// Latest state of each span, by id — a span is recorded twice, open and
    /// closed, and every assertion here is about the closed one.
    func settled(_ name: String) async -> [Span] {
        var latest: [String: Span] = [:]
        for span in await spans where span.name == name { latest[span.id.rawValue] = span }
        return latest.values.sorted { $0.startedAt < $1.startedAt }
    }
}

@Suite("Assignment spans — P10.15")
struct AssignmentSpanTests {

    @Test("an assignment that passes is one span, opened and closed")
    func passingAssignment() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("แก้แล้ว", evidence: [passingBuild]),
        ]), sink: sink)

        _ = await team.run(goal: "แก้เทส", plan: plan([assignment()]))

        let assignments = await sink.settled(Span.assignmentName)
        #expect(assignments.count == 1)
        #expect(assignments.first?.status == .succeeded)
        #expect(assignments.first?.endedAt != nil, "a span with no end has no duration")
        #expect(assignments.first?.role == .engineer)
    }

    // The first of the four lies. An estimate that counted only work which
    // passed first time would promise a schedule that holds on the days nothing
    // goes wrong, which are not the days anybody needs an estimate for.
    @Test("the span covers every attempt, not only the one that passed")
    func spansTheWholeAssignment() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("เสร็จแล้ว"),                              // no evidence — sent back
            deliverable("เสร็จจริงๆ"),                             // sent back again
            deliverable("แก้แล้ว", evidence: [passingBuild]),      // accepted
        ]), sink: sink)

        _ = await team.run(goal: "แก้เทส", plan: plan([assignment()]))

        let assignments = await sink.settled(Span.assignmentName)
        let attempts = await sink.settled(Span.attemptName)
        #expect(assignments.count == 1, "each round became its own assignment")
        #expect(attempts.count == 3, "the rework rounds are invisible")
        #expect(assignments.first?.status == .succeeded)
        // Three rounds happened inside one assignment, and the parent is what
        // the forecast reads.
        #expect(attempts.allSatisfy { $0.parent == assignments.first?.id })
        #expect(attempts.filter { $0.status == .failed }.count == 2)
    }

    // The second. An escalation is the longest and most expensive thing that
    // happens here; a span left running has no `ended_at`, so it silently drops
    // out of every duration query — removing precisely the worst case from the
    // population — and the process view goes on showing it as live work.
    @Test("an escalation closes the span as failed rather than leaving it running")
    func escalationClosesTheSpan() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("เสร็จแล้ว"), deliverable("เสร็จแล้ว"), deliverable("เสร็จแล้ว"),
        ]), sink: sink)

        _ = await team.run(goal: "แก้เทส", plan: plan([assignment()]))

        let span = await sink.settled(Span.assignmentName).first
        #expect(span?.status == .failed)
        #expect(span?.endedAt != nil)
        #expect(span?.detail?.isEmpty == false, "closed with no reason recorded")
    }

    @Test("a specialist that throws every round still closes the span")
    func thrownFailureClosesTheSpan() async {
        let sink = InMemorySpanSink()
        // An empty script throws on the first call.
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: []), sink: sink)

        _ = await team.run(goal: "แก้เทส", plan: plan([assignment()]))

        #expect(await sink.settled(Span.assignmentName).first?.status == .failed)
        #expect(await sink.settled(Span.attemptName).count == 3)
    }

    // The third. Work stopped halfway stopped for reasons that have nothing to
    // do with how long that kind of work takes.
    @Test("cancelling closes the span as cancelled, so it is not a duration")
    func cancellingClosesTheSpan() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("แก้แล้ว", evidence: [passingBuild]),
        ]), sink: sink)

        await team.cancel("never_started", assignment: assignment("never_started"),
                          reason: "เปลี่ยนใจ")

        // Nothing was ever opened, so nothing is closed: a cancelled row that
        // never ran is not a zero-length piece of work.
        #expect(await sink.settled(Span.assignmentName).isEmpty)
    }

    // The fourth. A human send-back is one more round on a promise already
    // made; recording it as a whole assignment would put a single round into a
    // population of whole assignments and drag the band down every time
    // somebody asks for a small fix.
    @Test("a human rework is an attempt, never a second assignment")
    func humanReworkIsAnAttempt() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("แก้แล้ว", evidence: [passingBuild]),
        ]), sink: sink)

        _ = await team.rework(assignment(), note: "ยังไม่ครอบคลุมเคสว่าง")

        #expect(await sink.settled(Span.assignmentName).isEmpty)
        let attempts = await sink.settled(Span.attemptName)
        #expect(attempts.count == 1)
        #expect(attempts.first?.deliverableKind == nil,
                "a single round entered the population of whole assignments")
    }

    // The field that says which population a duration belongs to. On the parent
    // and nowhere else: on the children too, a query that forgot the name
    // filter would count one assignment four times.
    @Test("the deliverable kind is on the assignment span and on nothing else")
    func kindIsOnTheParentOnly() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("เสร็จแล้ว"),
            deliverable("แก้แล้ว", evidence: [passingBuild]),
        ]), sink: sink)

        _ = await team.run(goal: "แก้เทส",
                           plan: plan([assignment(kind: "  โค้ดที่ผ่านเทส  ")]))

        // Normalised, so the same promise typed with stray spaces is one
        // population rather than two of one.
        #expect(await sink.settled(Span.assignmentName).first?.deliverableKind
                    == "โค้ดที่ผ่านเทส")
        #expect(await sink.settled(Span.attemptName).allSatisfy { $0.deliverableKind == nil })
    }

    @Test("the leaf the run is against rides on the span")
    func workPackageIsCarried() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("แก้แล้ว", evidence: [passingBuild]),
        ]), sink: sink)

        _ = await team.run(goal: "แก้เทส", plan: plan([assignment()]),
                           workPackage: "wp_7")

        #expect(await sink.settled(Span.assignmentName).first?.workPackage == "wp_7")
        #expect(await sink.settled(Span.attemptName).allSatisfy { $0.workPackage == "wp_7" })
        // And on the ledger entry, which is the other half of the same link:
        // `LedgerRow.work_package` has existed since P10.4 with nothing writing it.
        #expect(await team.entries.first?.workPackage == "wp_7")
    }

    @Test("a run against no leaf says so rather than inventing one")
    func noWorkPackageIsARealState() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("แก้แล้ว", evidence: [passingBuild]),
        ]), sink: sink)

        _ = await team.run(goal: "แก้เทส", plan: plan([assignment()]))

        #expect(await sink.settled(Span.assignmentName).first?.workPackage == nil)
    }

    @Test("the span is filed under the workspace the lead is pointed at")
    func spansCarryTheScope() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("แก้แล้ว", evidence: [passingBuild]),
        ]), sink: sink, scope: .project(ProjectID("pj_alpha")))

        _ = await team.run(goal: "แก้เทส", plan: plan([assignment()]))

        #expect(await sink.settled(Span.assignmentName).first?.scope
                    == .project(ProjectID("pj_alpha")))
    }

    // The scope was a `let` fixed at boot, so every piece of team work in the
    // app was filed under General whichever project was open — and the tolerance
    // strip, the forecast and the schedule all read by project.
    @Test("the lead can be pointed at another workspace")
    func scopeFollowsTheProject() async {
        let sink = InMemorySpanSink()
        let team = orchestrator(ScriptedSpecialist(role: .engineer, replies: [
            deliverable("แก้แล้ว", evidence: [passingBuild]),
        ]), sink: sink, scope: .central)

        await team.use(scope: .project(ProjectID("pj_beta")))
        _ = await team.run(goal: "แก้เทส", plan: plan([assignment()]))

        #expect(await sink.settled(Span.assignmentName).first?.scope
                    == .project(ProjectID("pj_beta")))
    }

    @Test("no sink means no spans and no crash")
    func worksWithoutASink() async {
        let team = TeamOrchestrator(router: ModelRouter(executors: []),
                                    specialists: [.engineer: ScriptedSpecialist(
                                        role: .engineer,
                                        replies: [deliverable("แก้แล้ว", evidence: [passingBuild])])])
        #expect(await team.run(goal: "แก้เทส", plan: plan([assignment()])).count == 1)
    }
}
