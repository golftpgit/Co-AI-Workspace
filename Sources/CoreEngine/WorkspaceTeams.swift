import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// One lead per workspace (ARCHITECTURE §19.1.1, P21.2).
//
// **What this fixes**: there was one `TeamOrchestrator` for the whole app, and
// the screen re-pointed it at whichever workspace was in front by calling
// `use(scope:)`. That is a lead who can only be in one room at a time, and it
// fails in both directions:
//
//  • **Mid-run the switch is refused** — correctly, since half a run's rows
//    landing in one project and half in another is a ledger neither can read.
//    But refusing it silently means the *other* tab then files its work under
//    the project you left, which is the same corruption arriving by the other
//    door.
//  • **The in-memory ledger is one ledger.** `use` empties it on a switch, so
//    coming back to a running project meant the lead had forgotten the run it
//    was in the middle of.
//
// So the lead belongs to the workspace, not to the screen. One orchestrator per
// `Scope`, made on first use and kept — the same shape, and for the same
// reason, as `WorkspaceStoreCache` in the app: two instances on one workspace
// would be two writers, and one instance across two workspaces is what P21.2
// exists to end.
//
// Deliberately *not* here: which workspaces are open on screen. That is
// `OpenWorkspaces`, and a tab being closed is not the same event as its work
// being finished — see `release`.
// ─────────────────────────────────────────────────────────────

public actor WorkspaceTeams {
    private let make: @Sendable (Scope) -> TeamOrchestrator
    private var byScope: [Scope: TeamOrchestrator] = [:]
    private let log = AppLog.logger("workspace-teams")

    /// - Parameter make: builds a lead already pointed at the workspace. Passed
    ///   in rather than assembled here because the specialists, the router and
    ///   the ledger are the app's wiring, and this type's job is only to make
    ///   sure there is exactly one of them per workspace.
    public init(make: @escaping @Sendable (Scope) -> TeamOrchestrator) {
        self.make = make
    }

    /// The lead for a workspace, made the first time it is asked for.
    public func team(for scope: Scope) -> TeamOrchestrator {
        if let existing = byScope[scope] { return existing }
        let team = make(scope)
        byScope[scope] = team
        return team
    }

    public func isOpen(_ scope: Scope) -> Bool { byScope[scope] != nil }

    public var openScopes: [Scope] { Array(byScope.keys) }

    /// Lets go of a workspace's lead — **unless it is working**.
    ///
    /// Closing a tab is closing a window, not stopping the work (§19.1.1): the
    /// run keeps writing rows either way, so dropping the lead here would not
    /// stop anything, it would only lose the thing that knows what is running.
    /// Reopening the tab would then show an idle screen over live work, which is
    /// the worst of the three possible answers.
    ///
    /// - Returns: whether the lead was let go. `false` means work is in flight
    ///   and the workspace is still held.
    @discardableResult
    public func release(_ scope: Scope) async -> Bool {
        guard let team = byScope[scope] else { return true }
        guard await !team.isBusy else {
            log.info("keeping \(scope.storageKey, privacy: .public) — work in flight")
            return false
        }
        byScope[scope] = nil
        return true
    }
}
