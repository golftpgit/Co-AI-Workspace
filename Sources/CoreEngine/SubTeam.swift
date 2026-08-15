import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// The line the whole of §22 rests on: a team is a specialist (P16.1).
//
//     protocol Specialist { func execute(_ assignment: Assignment) async throws -> Deliverable }
//     SubTeam: Specialist
//
// From its parent's side a sub-team is one member: it is handed an
// `Assignment` and returns a `Deliverable`. That is the entire interface, and
// it is the interface the compiler enforces — there is no member here that
// returns a transcript, a ledger or a context window, so the isolation §2.3
// describes is not a rule anybody has to keep.
//
// The lead inside runs its own `TeamOrchestrator` with its own QA, so the work
// is reviewed on the way out and reviewed again by the parent. Two reviews of
// one evidence set (§22.2) — not two opinions, because both read the same
// artefacts against the same criteria.
// ─────────────────────────────────────────────────────────────

public actor SubTeam: Specialist {
    /// The role this team presents to its parent. A team of researchers is a
    /// researcher as far as the level above is concerned, which is what lets
    /// `TeamPlan` validation stay exactly as it is at every depth.
    public nonisolated let role: Role
    public nonisolated let definitionOfDone: [Criterion]
    public nonisolated let charter: TeamCharter
    /// How deep this team sits. Carried so the nesting cap is checked against a
    /// fact rather than against a count somebody remembered to pass down.
    public nonisolated let depth: Int

    private let orchestrator: TeamOrchestrator
    /// What this team may call — already intersected with the parent's set when
    /// it was created (§22.4). Held so a plan made *inside* the team can be
    /// checked against it too.
    private let tools: Set<String>
    private let spans: (any SpanSink)?
    private let log = AppLog.logger("sub-team")

    public init(role: Role,
                charter: TeamCharter,
                depth: Int,
                tools: Set<String>,
                orchestrator: TeamOrchestrator,
                spans: (any SpanSink)? = nil) {
        self.role = role
        self.charter = charter
        self.definitionOfDone = charter.acceptanceCriteria
        self.depth = depth
        self.tools = tools
        self.orchestrator = orchestrator
        self.spans = spans
    }

    /// The parent's whole view of this team.
    ///
    /// Everything that happened inside — the plan, the rework, the transcripts,
    /// which member did what — stays here. What goes up is the deliverable and
    /// its evidence, which is what the parent's QA judges. A parent that could
    /// read the inside would start reviewing *how* rather than *what*, and
    /// §2.3 exists because that is how one team's confusion becomes everybody's.
    public func execute(_ assignment: Assignment) async throws -> Deliverable {
        var span = Span(name: "team.\(charter.domain)", status: .running)
        span.detail = "\(charter.mission) · ชั้นที่ \(depth)"

        let plan = TeamPlan(goal: assignment.goal, assignments: [assignment])
        let delivered = await orchestrator.run(goal: assignment.goal, plan: plan)

        guard let deliverable = delivered.first else {
            span.status = .failed
            span.endedAt = Date()
            await spans?.record(span)
            // Nothing came back that passed the sub-team's own QA. Reported as
            // a failure rather than as an empty success: a parent that received
            // "nothing, and that is fine" would mark the branch done.
            throw SpecialistError.modelUnavailable(
                "ทีม \(charter.domain) ไม่มีผลงานที่ผ่าน QA ของทีมเอง")
        }
        span.status = .succeeded
        span.endedAt = Date()
        await spans?.record(span)
        log.info("\(self.charter.domain, privacy: .public) ส่งผลงานขึ้นชั้นบน")

        // Re-stamped with the parent's assignment id: to the level above, this
        // is the answer to *its* assignment, not to the one the sub-lead handed
        // its own member.
        return Deliverable(assignmentID: assignment.id,
                           summary: deliverable.summary,
                           artifacts: deliverable.artifacts,
                           evidence: deliverable.evidence)
    }

    /// Whether a plan this team wants to run stays inside its authority.
    ///
    /// Checked here as well as at creation, because a team's plan is written
    /// after it exists: a sub-team that was granted three tools and then writes
    /// a plan needing a fourth is the same escalation arriving one step later.
    public func mayRun(_ plan: TeamPlan, requiring required: Set<String>) -> NestingDecision {
        let excess = required.subtracting(tools)
        guard excess.isEmpty else {
            return .refused(.wouldExceedAuthority(tools: Array(excess)))
        }
        return CommandRules.mayCreateSubTeam(
            depth: depth,
            parentTools: tools,
            childTools: required,
            independent: true,
            leadRole: role)
    }
}
