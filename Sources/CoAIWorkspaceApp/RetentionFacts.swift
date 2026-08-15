import Foundation
import AgentKit
import Config
import CoreEngine
import Knowledge
import OLTP
import ProjectKit
import Observability

// ─────────────────────────────────────────────────────────────
// The two facts the closing gate needs about retention (§20.5, §19.12
// condition 8, P11.10), assembled where both stores exist.
//
// This lives in the app rather than in ProjectKit for the same reason
// `ClosingLedger` lives in Persistence: ProjectKit must not learn about M16's
// SQLite file or M7's policy scope to ask two questions about them. The app is
// the only place that already holds both.
//
// **Why `heldHumanData` is optional and what each answer means.** A project
// that never opened a form has no participants to have promised anything to,
// and asking it to name a retention policy is the ceremony R10 warns about. A
// project that did has to name a real one. And a response store that cannot be
// opened is neither — it is a question nobody answered, which the gate shows
// as a grey dash and does not treat as clearance.
//
// The distinction that matters: **a project folder with no responses database
// is not a failure to read.** It is the ordinary shape of a project that never
// collected anything, and it answers `false` rather than `nil`.
// ─────────────────────────────────────────────────────────────

struct WorkspaceRetentionFacts: RetentionFactsReading {
    let paths: AppPaths
    let policySource: PolicyLibrarySource
    private let log = AppLog.logger("retention")

    func heldHumanData(scope: Scope) async -> Bool? {
        guard case .project(let id) = scope else {
            // General is not a study. Nothing is collected under it (§19.1).
            return false
        }
        let file = paths.project(id).responsesDatabase
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            // Never opened a form. See the header — this is an answer, not a gap.
            return false
        }
        do {
            return try await ResponseStore(path: file).hasAnySubmission()
        } catch {
            // The file is there and will not open. Saying "nobody answered"
            // here would let a corrupt database wave a project past the one
            // condition that exists to protect the people in it.
            log.error("cannot read responses for \(id.rawValue, privacy: .public): \(error)")
            return nil
        }
    }

    func retentionRules(scope: Scope) async -> [RetentionRule] {
        do {
            // The same rulebook the hook chain enforces (R14), so a policy that
            // stops a command and a policy that satisfies the closing gate can
            // never be two different documents.
            let library = try await policySource.library()
            return RetentionPolicyReader.rules(in: library.allRules)
        } catch {
            log.error("cannot read the policy scope: \(error)")
            return []
        }
    }
}
