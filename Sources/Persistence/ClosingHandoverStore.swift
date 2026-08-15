import Foundation
import AgentKit
import ProjectKit
import Knowledge
import Observability

// ─────────────────────────────────────────────────────────────
// Moving what a closed project leaves behind (§19.1.1, P21.4).
//
// The rule lives in `Knowledge.ClosingHandoverPolicy` and is testable without a
// database; this is the half that reads the project's rows and writes the ones
// that move. Split for the reason the rule is worth reading on its own: which
// knowledge follows a project out is an ethical question with a technical
// answer, and burying it inside a store would make it look like plumbing.
// ─────────────────────────────────────────────────────────────

public struct ClosingHandoverStore: ClosingKnowledgeHandover {
    private let knowledge: KnowledgeStore
    private let conflicts: ConflictStore?
    private let log = AppLog.logger("handover")

    public init(knowledge: KnowledgeStore, conflicts: ConflictStore? = nil) {
        self.knowledge = knowledge
        self.conflicts = conflicts
    }

    @discardableResult
    public func handOver(from project: Project) async throws -> HandoverCount {
        let scope = Scope.project(project.id)
        let chunks = try await knowledge.load(scope: scope)
        let moving = ClosingHandoverPolicy.promoted(chunks)

        // Written as one batch, and the ids are the project's own: closing the
        // same project twice, or two projects that cite the same paper, upserts
        // the same rows rather than growing the library a copy at a time.
        if !moving.isEmpty { try await knowledge.save(moving) }

        var precedents = 0
        if let conflicts {
            // A decision the user declared central is already stored as
            // central-scoped; what closing does is make sure the *card* is
            // readable from central too, so the next project meets the decision
            // rather than re-litigating the same pair of sources.
            let stored = (try? await conflicts.load(scope: scope)) ?? []
            for conflict in stored {
                guard let decision = conflict.decision,
                      ClosingHandoverPolicy.isCentralPrecedent(decision) else { continue }
                try await conflicts.promoteToCentral(conflict.id)
                precedents += 1
            }
        }

        let count = HandoverCount(movedUp: moving.count,
                                  keptInProject: chunks.count - moving.count,
                                  precedents: precedents)
        log.info("""
            handover from \(project.id.rawValue, privacy: .public): \
            \(count.movedUp, privacy: .public) up, \
            \(count.keptInProject, privacy: .public) kept, \
            \(count.precedents, privacy: .public) precedents
            """)
        return count
    }
}
