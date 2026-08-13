import Foundation
import AgentKit
import Config
import Analysis
import Observability

// ─────────────────────────────────────────────────────────────
// The stores that belong to one workspace (ARCHITECTURE §19.1, P10.1).
//
// The knowledge base, the task ledger and the conversations are partitioned by
// `Scope` inside one database, which is right: they are rows, they are queried
// together, and SurrealDB is the thing that owns them. Files are not rows. An
// analysis database, a notebook folder and a working directory are objects on
// disk, and "which project does this file belong to" has to be answerable by
// looking at where it is.
//
// So a project gets its own folder and its own instances, made on first use and
// kept afterwards. General keeps the app-wide ones it always had — it is a real
// place to work, not the leftovers.
// ─────────────────────────────────────────────────────────────

struct WorkspaceStores: Sendable {
    /// Nil when the file could not be opened. A corrupt `.duckdb` in one
    /// project must not stop the others, or the app, from opening.
    let analysis: AnalysisStore?
    let notebooks: NotebookStore
    let connectors: ConnectorStore
    /// Where this workspace's shell commands run. Inside the app container, so
    /// a sandboxed app can reach it without the user granting anything.
    let workingDirectory: URL?
}

/// Opens each workspace's stores once and hands the same ones out afterwards.
///
/// Two instances of `AnalysisStore` on one file is not a slow path, it is a
/// second writer — so "make one per screen" was never an option, and caching
/// here is what makes per-project stores safe rather than merely tidy.
actor WorkspaceStoreCache {
    private let paths: AppPaths
    private let shared: WorkspaceStores
    private var byScope: [String: WorkspaceStores] = [:]
    private let log = AppLog.logger("workspace-stores")

    init(paths: AppPaths, shared: WorkspaceStores) {
        self.paths = paths
        self.shared = shared
    }

    func stores(for scope: Scope) -> WorkspaceStores {
        guard case .project(let id) = scope else { return shared }
        if let existing = byScope[scope.storageKey] { return existing }

        let project = paths.project(id)
        do {
            try project.createDirectories()
        } catch {
            // Fall back to the app-wide stores rather than leaving the screen
            // with nothing: a project whose folder cannot be made is a broken
            // installation, and it should say so on the screen it breaks,
            // not by looking empty.
            log.error("cannot create folders for \(id.rawValue, privacy: .public): \(error)")
            return shared
        }

        let stores = WorkspaceStores(
            analysis: try? AnalysisStore(fileURL: project.analysisDatabase),
            notebooks: NotebookStore(directory: project.notebooksDirectory),
            connectors: ConnectorStore(file: project.connectorsFile),
            workingDirectory: project.filesDirectory)
        byScope[scope.storageKey] = stores
        return stores
    }
}
