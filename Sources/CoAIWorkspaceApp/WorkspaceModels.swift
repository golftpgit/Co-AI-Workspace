import Foundation
import AgentKit
import CoreEngine
import EmbeddingRuntime
import Observability

// ─────────────────────────────────────────────────────────────
// One set of screen models per open workspace (ARCHITECTURE §19.1.1, P21.2).
//
// **The defect this ends**: the app held one `TeamViewModel`, one
// `AnalysisViewModel`, one of each — and re-pointed them at whichever workspace
// was in front. So a workspace was a *mode the models were put into*, and two
// things followed from that, both of them bugs:
//
//  • **Running work was owned by the screen.** Chat built its view model inside
//    the view, and the view's identity is the scope — so switching tabs threw
//    the model away and the turn in flight streamed into nothing. The team's run
//    survived (its `Task` lives on the model) but the model was re-pointed
//    underneath it, so the rows of the project you left and the project you
//    arrived at merged into one list.
//  • **Coming back reloaded everything.** Every `.task` re-attached on every
//    switch, which is where "switching tabs still reloads the screen's data"
//    came from at the end of P21.1.
//
// The models therefore belong to the workspace, not to the screen — the same
// answer, and the same shape, as `WorkspaceStoreCache` for files and
// `WorkspaceTeams` for the lead. Made on first use, kept afterwards, and handed
// to whichever view is drawing that tab.
//
// **What is deliberately still shared**: the models with no scope at all —
// models, budget, channels, the project list itself. Giving those a copy per
// tab would mean two screens editing one registry and disagreeing about it,
// which is the mirror image of the bug above.
// ─────────────────────────────────────────────────────────────

/// Everything one open workspace is holding: its screens' state, and the work
/// they have in flight.
@MainActor
final class Workspace {
    let scope: Scope
    let chat: ChatViewModel
    let team = TeamViewModel()
    let analysis = AnalysisViewModel()
    let manuscripts = ManuscriptViewModel()
    let instruments = InstrumentsViewModel()
    let coding = CodingViewModel()
    let workflows = WorkflowViewModel()
    let knowledge: KnowledgeViewModel

    /// Which screens have been wired up already.
    ///
    /// Attaching is wiring — which store, which gateway, which scope — and it
    /// is done once per workspace. Before P21.2 it ran again on every tab
    /// switch, because the view was rebuilt and its `task` ran again; now the
    /// model outlives the view, so re-running it would re-read the database to
    /// arrive at the state the model is already holding.
    private var wired: Set<String> = []

    init(scope: Scope, engine: Engine, embedder: MLXEmbedder) {
        self.scope = scope
        self.chat = ChatViewModel(engine: engine, scope: scope)
        // One embedder for the app, not one per workspace: the model is
        // gigabytes of weights, and a second instance would be a second copy of
        // them for a second project's search box.
        self.knowledge = KnowledgeViewModel(embedder: embedder)
    }

    /// True the first time each screen asks, false forever after.
    func needsWiring(_ screen: String) -> Bool { wired.insert(screen).inserted }

    /// Which project this workspace is, if it is one. `nil` in General, where
    /// the screens that ask disable the option rather than filling it in with a
    /// made-up id.
    var projectID: ProjectID? {
        if case .project(let id) = scope { return id }
        return nil
    }

    /// Whether this workspace has work in flight — a turn, a team run, a
    /// notebook cell, a workflow. Read from the models themselves rather than
    /// tracked beside them, so it cannot claim idle while something runs.
    var isBusy: Bool {
        chat.isRunning || team.isRunning || analysis.isRunning || workflows.running
    }
}

/// Opens each workspace's models once and hands the same ones out afterwards.
@MainActor
final class WorkspaceModels {
    private var byScope: [Scope: Workspace] = [:]
    /// Shared for the reason given in `Workspace.init`.
    private let embedder = MLXEmbedder()
    private let log = AppLog.logger("workspace-models")

    /// The models for a workspace, made the first time it is drawn — and never
    /// again, which is also P1.10's rule: a model rebuilt on a body pass loses
    /// whatever the user had just done to it.
    func workspace(for scope: Scope, engine: Engine) -> Workspace {
        if let existing = byScope[scope] { return existing }
        let made = Workspace(scope: scope, engine: engine, embedder: embedder)
        byScope[scope] = made
        return made
    }

    /// Lets go of a workspace when its tab closes — **unless it is working**.
    ///
    /// Closing a tab closes a window, not the work (§19.1.1). Dropping the
    /// models of a running workspace would not stop the run; it would only lose
    /// the thing that can see it, and reopening the tab would show an idle
    /// screen over live work. Same rule as `WorkspaceTeams.release`, and it has
    /// to be the same rule, because they are two halves of one answer.
    ///
    /// - Returns: whether the models were let go.
    @discardableResult
    func release(_ scope: Scope) -> Bool {
        guard let workspace = byScope[scope] else { return true }
        guard !workspace.isBusy else {
            log.info("keeping \(scope.storageKey, privacy: .public) — work in flight")
            return false
        }
        byScope[scope] = nil
        return true
    }

    var openScopes: [Scope] { Array(byScope.keys) }
}
