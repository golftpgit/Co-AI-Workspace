import Foundation
import Observation
import Config
import AgentKit
import Observability
import Sidecar
import LLMProviders
import CoreEngine

/// Boot state the UI observes. Everything that can fail at startup fails
/// *visibly* here — v1's habit of swallowing startup errors left blank panels
/// with no explanation (bug B4).
@MainActor
@Observable
public final class AppEnvironment {
    public enum Phase: Equatable {
        case launching
        case ready
        case degraded(String)
    }

    public private(set) var phase: Phase = .launching
    public private(set) var paths: AppPaths?
    public private(set) var config: BootstrapConfig = .default
    public private(set) var bootstrapOutcome: BootstrapStore.LoadOutcome?
    public private(set) var createdDirectories: [String] = []
    public private(set) var sidecarStatuses: [String: SidecarStatus] = [:]
    /// Sidecars that gave up, newest state each poll.
    ///
    /// Kept as its own property rather than filtered at each call site, because
    /// this is the one thing about the strip that has to be true everywhere: a
    /// component that stopped is a fact about the whole app, and it was only
    /// visible on the system screen — which is a screen somebody opens *after*
    /// they already suspect something (AUDIT F-12).
    public var failedSidecars: [(id: String, explanation: String)] {
        sidecarStatuses
            .filter { if case .failed = $0.value { return true }; return false }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.explanation(id: $0.key)) }
    }
    public private(set) var notes: [String] = []
    /// Nil until the database answers. Chat is unavailable without it, and the
    /// UI says which of the two happened rather than showing an empty panel.
    private(set) var engine: Engine?
    private(set) var engineError: String?

    private var sidecars: SidecarManager?
    private var statusPoll: Task<Void, Never>?
    private let log = AppLog.logger("boot")

    public init() {}

    public func boot() async {
        do {
            let paths = try AppPaths.standard()
            let created = try paths.createDirectories()
            self.paths = paths
            self.createdDirectories = created.map(\.lastPathComponent)

            let store = BootstrapStore(paths: paths)
            let (config, outcome) = try store.load()
            self.config = config
            self.bootstrapOutcome = outcome
            if case .repairedInvalid(let reason) = outcome {
                notes.append(t("bootstrap.plist was unusable, so it was rewritten from the defaults (\(reason))",
                           "Boot note. Placeholder is why the file was rejected."))
            }

            let manager = SidecarManager(paths: paths)
            self.sidecars = manager
            await startBundledSidecars(manager, config: config, paths: paths)
            startStatusPolling(manager)
            await buildEngine(config: config, paths: paths)

            phase = .ready
            log.info("boot complete at \(paths.root.path(percentEncoded: false), privacy: .public)")
        } catch {
            phase = .degraded("\(error)")
            log.error("boot failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// P0 wires the manager and reports what is missing; the actual surreal /
    /// searxng binaries are bundled in P1.2 and P3.1 respectively.
    private func startBundledSidecars(_ manager: SidecarManager,
                                      config: BootstrapConfig,
                                      paths: AppPaths) async {
        guard let helpers = Bundle.main.url(forResource: nil, withExtension: nil, subdirectory: "Helpers")
                ?? Bundle.main.resourceURL?.appending(path: "Helpers"),
              FileManager.default.fileExists(atPath: helpers.path(percentEncoded: false)) else {
            notes.append(t("No Helpers folder in the bundle yet — sidecars start once P1.2/P3.1 land",
                           "Boot note when the helper binaries are not packaged."))
            return
        }

        let surreal = helpers.appending(path: "surreal")
        guard FileManager.default.isExecutableFile(atPath: surreal.path(percentEncoded: false)) else {
            notes.append(t("No ‘surreal’ binary in Helpers — starting the sidecar was skipped",
                           "Boot note when the database binary is missing."))
            return
        }

        let spec = SidecarSpec(
            id: "surreal",
            executableURL: surreal,
            arguments: ["start",
                        "--user", "root", "--pass", "root",
                        "--bind", "127.0.0.1:\(config.surrealPort)",
                        "surrealkv://\(paths.databaseDirectory.path(percentEncoded: false))"],
            healthURL: URL(string: "http://127.0.0.1:\(config.surrealPort)/health"))
        do {
            try await manager.start(spec)
        } catch {
            notes.append(t("The ‘surreal’ sidecar would not start: \(String(describing: error))",
                           "Boot note. Placeholder is the underlying error."))
        }

        await startSearXNG(manager: manager, config: config)
    }

    /// Meta-search (§1.4, P3.1). Optional on purpose: everything except T5 web
    /// search works without it, so a machine that has not installed it gets a
    /// note rather than a failed boot.
    ///
    /// The interpreter is a configured path rather than something bundled,
    /// because a Python virtualenv cannot be relocated — its scripts hold
    /// absolute paths — so shipping one inside the .app is packaging work
    /// (P9.6), not a copy step.
    private func startSearXNG(manager: SidecarManager, config: BootstrapConfig) async {
        guard let interpreter = config.searxngPython, !interpreter.isEmpty else {
            notes.append(t("searxngPython is not set — open-web search (T5) will not work (install it with scripts/fetch-searxng.sh, then set it in bootstrap.plist)",
                           "Boot note when the web-search interpreter is unconfigured."))
            return
        }
        guard FileManager.default.isExecutableFile(atPath: interpreter) else {
            notes.append(t("searxngPython points at something that cannot be run: \(interpreter)",
                           "Boot note. Placeholder is the configured path."))
            return
        }

        let settings = URL(fileURLWithPath: interpreter)
            .deletingLastPathComponent()      // bin
            .deletingLastPathComponent()      // venv
            .deletingLastPathComponent()      // searxng
            .appending(path: "config/settings.yml")

        let spec = SidecarSpec(
            id: "searxng",
            executableURL: URL(fileURLWithPath: interpreter),
            arguments: ["-m", "searx.webapp"],
            healthURL: URL(string: "http://127.0.0.1:\(config.searxngPort)/"),
            environment: ["SEARXNG_SETTINGS_PATH": settings.path(percentEncoded: false)],
            // It loads ~70 engine definitions before it answers; the default
            // 15 seconds is measured against a database, not this.
            readinessTimeout: .seconds(45))
        do {
            try await manager.start(spec)
        } catch {
            notes.append(t("The ‘searxng’ sidecar would not start: \(String(describing: error))",
                           "Boot note. Placeholder is the underlying error."))
        }
    }

    /// The database is a sidecar that has just been asked to start, so the
    /// first connection attempt can legitimately lose the race. Retrying for a
    /// few seconds is the difference between a working first launch and a
    /// window that says "the database is unreachable" until the user restarts.
    private func buildEngine(config: BootstrapConfig, paths: AppPaths) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            do {
                let engine = try await Engine.build(config: config, paths: paths)
                self.engine = engine
                // §14.3 — the one thing an App Intent can reach. An intent
                // arrives without a view, so there is no environment for it to
                // be handed; it has to be able to find this.
                IntentBridge.shared.channel = engine.appIntents
                engineError = nil
                noteWhichModelsExist(config, engine: engine)
                log.info("engine ready")
                return
            } catch {
                engineError = "\(error)"
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        notes.append(t("The database would not connect, so Chat is unavailable — \(engineError ?? t("no reason given", "Stand-in when a failure carries no reason."))",
                       "Boot note. Placeholder is why the connection failed."))
        log.error("engine unavailable: \(self.engineError ?? "unknown", privacy: .public)")
    }

    /// Says which tiers this machine actually has.
    ///
    /// The router keeps high-impact work off Apple's on-device model because
    /// its answers are not stable enough to decide on (ARCH E.7). With neither
    /// a local MLX model nor a self-hosted endpoint there is no model for that
    /// work *at all*, and conflict detection and relation extraction return
    /// nothing on every document. Both fail quietly by design (an unreachable
    /// model must not be read as "these sources agree"), which is exactly why
    /// the boot screen has to be the one to mention it.
    private func noteWhichModelsExist(_ config: BootstrapConfig, engine: Engine) {
        let hasEndpoint = !(config.selfHostedEndpoint?.isEmpty ?? true)
        switch (engine.localTier.selected, hasEndpoint) {
        case (nil, false):
            notes.append(t("No MLX model on the machine and no selfHostedEndpoint set — only the on-device model is left, which accuracy-critical work cannot use: no conflict will be found and no relation extracted for the graph (download one on the “Models” tab)",
                           "Boot note when neither a local model nor an endpoint is available."))
        case (nil, true):
            // §9.2 rule 4: the endpoint is not allowed to be the only path.
            notes.append(t("No MLX model on the machine — Tier 0.5, the guarantee floor, is missing. If the endpoint goes down or you are offline, accuracy-critical work has nowhere to run (download one on the “Models” tab)",
                           "Boot note when the guarantee floor is missing."))
        case (let model?, false):
            notes.append(t("No selfHostedEndpoint set — accuracy-critical work runs on \(model.name) on this machine, which is slower but works",
                           "Boot note when only the local model is available. Placeholder is its name."))
        case (_?, true):
            break
        }
    }

    /// Records a change made on the models screen. Bootstrap, not the
    /// database: the router is built during boot, before the database is up,
    /// so which model Tier 0.5 loads has to be readable from a flat file.
    public func rememberLocalModel(_ name: String?) {
        guard let paths, config.localModel != name else { return }
        var updated = config
        updated.localModel = name
        do {
            try BootstrapStore(paths: paths).save(updated)
            config = updated
        } catch {
            log.error("saving local model choice: \(String(describing: error), privacy: .public)")
        }
    }

    /// Bumped every time the model chain changes. Screens that show the chain
    /// watch it, because `.task` runs when a view appears and switching areas
    /// with ⌘1–⌘5 does not promise a fresh view.
    public private(set) var endpointGeneration = 0

    /// Records endpoints and ceilings from the settings screen — **and rebuilds
    /// the chain the router is using.**
    ///
    /// Writing the file used to be all this did. The router was assembled once
    /// during boot, so an endpoint saved here did not exist as far as the app
    /// was concerned until it was restarted, and nothing on screen said so: the
    /// composer's model switch offers `ModelRouter.offered`, and the GX10
    /// somebody had just added was not in that list (AUDIT F-1).
    ///
    /// The file is still written first. It is what survives a restart, and a
    /// chain rebuilt from a registry that failed to save would disagree with
    /// the one the next launch builds.
    public func rememberEndpoints(_ registry: EndpointRegistry, limits: BudgetLimits) {
        guard let paths else { return }
        var updated = config
        updated.endpointRegistry = registry
        updated.budget = limits
        do {
            try BootstrapStore(paths: paths).save(updated)
            config = updated
        } catch {
            log.error("saving endpoints: \(String(describing: error), privacy: .public)")
            return
        }
        rebuildModelChain(from: registry)
    }

    /// Rebuilds the router's chain from a registry, off the main actor.
    ///
    /// Probing every endpoint is network work, and §24/P9.5 measured what that
    /// costs on the main actor: a stall long enough to read as the app hanging.
    private func rebuildModelChain(from registry: EndpointRegistry) {
        guard let engine else { return }
        Task { [engine, log] in
            let built = await EndpointExecutors.build(from: registry)
            // The two local tiers are not configurable here and keep their
            // place at the front of the chain (§9.2 rule 4): Tier 0.5 is the
            // floor everything else falls back to, and a rebuild that dropped
            // it would take the app offline the moment the LAN went away.
            var chain: [any LLMExecutor] = [OnDeviceExecutor(), engine.localTier]
            chain.append(contentsOf: built.executors)
            await engine.router.replaceExecutors(chain)
            // The window is the server's to declare (P15.3, C2). A different
            // endpoint means a different window, and the meter beside the
            // composer would otherwise go on reporting the old one.
            if let window = built.defaultWindow {
                await engine.runner.setPromptBudget(
                    ContextManager.promptBudget(forWindow: window))
            }
            await MainActor.run { self.endpointGeneration += 1 }
            log.info("model chain rebuilt: \(chain.count, privacy: .public) executors")
        }
    }

    private func startStatusPolling(_ manager: SidecarManager) {
        statusPoll?.cancel()
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                let statuses = await manager.allStatuses()
                await MainActor.run { self?.sidecarStatuses = statuses }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Must run before the process exits so no sidecar is left behind.
    public func shutdown() async {
        statusPoll?.cancel()
        await engine?.shutdown()
        await sidecars?.stopAll()
        log.info("shutdown complete")
    }
}
