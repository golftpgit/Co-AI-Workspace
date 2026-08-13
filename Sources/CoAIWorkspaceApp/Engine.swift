import Foundation
import AppKit
import AgentKit
import Config
import Observability
import Persistence
import LLMProviders
import CoreEngine
import Execution
import ToolBelt
import Knowledge
import EmbeddingRuntime
import MLXRuntime
import Analysis
import Channels
import Roster
import DocGen
import MCPBridge
import ProjectKit

// ─────────────────────────────────────────────────────────────
// Everything the running system is made of, assembled once at boot.
//
// The wiring order is the dependency order from ARCHITECTURE §3: database →
// spans → models → tools → gate → broker → turn runner. Nothing here decides
// anything; the decisions all live in CoreEngine.
// ─────────────────────────────────────────────────────────────

struct Engine: Sendable {
    let client: SurrealClient
    let conversations: ConversationStore
    let spans: SurrealSpanSink
    /// Conflict cards, kept so a decision is made once (§11.6).
    let conflicts: ConflictStore
    /// The half of §11.6 that *sees* a disagreement. Built here rather than
    /// where it is used so that, like every other capability, it is on the
    /// wiring diagram — a detector nothing constructs is a feature that cannot
    /// happen (the same gap as D6's unreachable MCP client).
    let conflictDetector: ConflictDetector
    /// Graph edges, and the model that reads them out of a sentence (§11.4).
    let relations: RelationStore
    let relationExtractor: RelationExtractor
    /// The knowledge base's durable half. The screen keeps an in-memory index
    /// for search and writes through to this, so closing the app does not
    /// throw away what was ingested (P2.7).
    let knowledge: KnowledgeStore
    let router: ModelRouter
    let processes: ProcessRegistry
    let gateway: ToolGateway
    let broker: ApprovalBroker
    let runner: AgentTurnRunner
    /// The team from P4, and the ledger it writes as it goes. Assembled here
    /// for the same reason as everything else on this struct: four specialists
    /// and an orchestrator with twenty passing tests were reachable from
    /// nothing but those tests, which is the fourth time that has happened.
    let team: TeamOrchestrator
    let taskLedger: TaskLedgerStore
    /// §19.1 — projects, and the stage the hook chain reads (§19.4). One
    /// service, held here, so the stage the gate checks and the stage the
    /// screen shows are the same value rather than two copies that drift.
    let projects: ProjectService
    /// Which executors were actually reachable at boot — shown in the UI so
    /// "why is it slow / why can't it run commands" has a visible answer.
    let executorSummary: [String]
    /// Tier 0.5 (P5.1/P5.2) — a slot rather than a fixed model, so a model
    /// downloaded in the app is usable without a restart. Empty means the
    /// floor §9.2 rule 4 promises is missing, which the boot screen has to say.
    let localTier: LocalTier
    /// Where models come from and go: the app's own directory, plus whatever
    /// this machine already had (§9.4).
    let modelCatalog: LocalModelCatalog
    let modelInstaller: ModelInstaller
    /// Every model above Tier 0.5 (§9.3) and what it is allowed to spend
    /// (§9.5). Both live here so the settings screen changes the same objects
    /// the router is using, rather than a copy of them.
    let endpoints: EndpointRegistry
    let endpointChecks: [String: EndpointCheck]
    let governor: BudgetGovernor
    let spendLedger: SurrealSpendLedger
    /// The analysis store (§12.1, P6.1). Opened at boot like everything else
    /// on this struct: a capability that only its own tests can reach is the
    /// mistake this project has made four times.
    let analysis: AnalysisStore?
    /// Where notebooks are kept, and the interpreter that runs their Python
    /// cells (§12.5, P6.4). The kernel is *constructed* here and started by the
    /// screen: resolving an interpreter costs nothing, and launching a Python
    /// process at boot for a screen nobody may open costs a process.
    let notebooks: NotebookStore
    let notebookKernel: NotebookKernel?
    let connectors: ConnectorStore
    /// §12.4 — the pre-registration and the model that reads a proposal into
    /// one. The plan store is durable for the same reason the conflict ledger
    /// is: a method agreed only in memory was never agreed.
    let plans: AnalysisPlanStore
    let gapDetector: GapDetector
    /// §14.1 / P7.9 — templates learned from documents the user uploaded. A
    /// file rather than a row: a template is a thing people copy between
    /// machines, and it has to be readable without the database being up.
    let templates: TemplateStore
    /// §8 — the channels, and the one place an inbound message becomes a turn.
    /// Accounts are configuration; the router is the wiring that makes §8.2's
    /// "every channel through the same core" true by construction.
    let channelAccounts: ChannelAccountStore
    let channelRouter: ChannelRouter
    /// §14.3 — Siri, Shortcuts and Spotlight. Held so the intents in
    /// `WorkspaceIntents.swift` have something to ask; an intent that finds no
    /// channel is a Shortcut that fails without saying why.
    let appIntents: AppIntentsChannel
    /// §7 — agents and skills loaded from files. Held with the errors beside
    /// them: a manifest that failed to load is the one thing about the roster
    /// worth putting on the boot screen, because otherwise a typo looks like a
    /// model that stopped following instructions.
    let roster: [RosterEntry]
    let rosterProblems: [String]
    /// §6.2 — other people's tools. Held here for the reason this whole task
    /// exists: v1's MCP client was complete, tested and reachable from
    /// nothing (D6). A registry on the engine, whose tools are registered in
    /// the gateway below, is what makes it a feature instead of a module.
    let mcpServers: MCPServerStore
    /// §7.1 — packaged MCP servers installed from a folder (P8.4). Held so
    /// installing one can connect it into the running gateway rather than
    /// waiting for a restart, which is the whole of that task's Done-when.
    let plugins: PluginRegistry
    let mcp: MCPRegistry
    let mcpConnected: [MCPRegistry.Connected]
    let mcpProblems: [String]

    static func build(config: BootstrapConfig, paths: AppPaths) async throws -> Engine {
        let client = SurrealClient(url: URL(string: "ws://127.0.0.1:\(config.surrealPort)/rpc")!)
        try await client.connect()
        try await client.bootstrap(user: "root", password: "root")

        let spans = SurrealSpanSink(client: client)
        let conversations = ConversationStore(client: client)

        var executors: [any LLMExecutor] = [OnDeviceExecutor()]
        // Tier 0.5 — the floor the rest of the chain falls back to (§9.2 rule
        // 4). Resolved from disk, never downloaded here: boot must not depend
        // on a network, and choosing a model is the user's call on the models
        // screen. The tier joins the router either way, so the first download
        // does not need a restart to become usable.
        let modelCatalog = LocalModelCatalog(searchPaths: LocalModelCatalog
            .standard(appModelsDirectory: paths.modelsDirectory).searchPaths)
        var chosen: LocalModel?
        if let name = config.localModel { chosen = await modelCatalog.model(named: name) }
        if chosen == nil { chosen = await modelCatalog.preferred() }
        let localTier = LocalTier(model: chosen)
        executors.append(localTier)
        let modelInstaller = ModelInstaller(
            destination: paths.modelsDirectory,
            quotaGigabytes: config.modelQuotaGigabytes ?? BootstrapConfig.defaultModelQuotaGigabytes)
        // §9.3: several endpoints rather than one, each declaring whether it
        // costs money. The old single pair migrates itself (`effectiveEndpoints`).
        let endpoints = config.effectiveEndpoints
        var endpointChecks: [String: EndpointCheck] = [:]
        let probe = EndpointProbe()
        for endpoint in endpoints.endpoints {
            guard let url = endpoint.url else { continue }
            // Probed at boot so the status dots are true when the screen opens,
            // and so a typo in a model name is visible before it is used
            // (E.9 case 8a).
            endpointChecks[endpoint.id] = await probe.check(endpoint)
            executors.append(VLLMExecutor(
                identifier: endpoint.name,
                baseURL: url,
                model: endpoint.model,
                apiKey: endpoint.apiKey,
                tier: endpoint.kind == .paid ? .paid : .selfHosted,
                price: endpoint.inputPricePerMillion.flatMap { input in
                    endpoint.outputPricePerMillion.map {
                        TokenPrice(inputPerMillion: input, outputPerMillion: $0)
                    }
                }))
        }

        // §9.5 — only the metered tier passes through it, and only ever to be
        // sent somewhere cheaper rather than to fail.
        let spendLedger = SurrealSpendLedger(client: client)
        let governor = BudgetGovernor(limits: config.budget ?? .conservative,
                                      ledger: spendLedger, spanSink: spans)
        let router = ModelRouter(executors: executors, spanSink: spans, governor: governor)

        let processes = ProcessRegistry(spanSink: spans)
        let broker = ApprovalBroker(spanSink: spans)
        // §19.4 — the stage gate is wired here rather than defaulted off.
        // `HookChain()` with no reader refuses every project-scoped call, which
        // is the safe default for a library; the app is the place that knows
        // where stages come from.
        let projects = ProjectService(store: ProjectStore(client: client))
        let gateway = ToolGateway(chain: HookChain(stageGate: StageGate(reader: projects)),
                                  approver: broker,
                                  spanSink: spans,
                                  modes: .default)
        // Everything P2 and P3 built is only a feature once it is on the tool
        // list — v1 shipped an MCP client that no session could reach (D6).
        let knowledgeStore = KnowledgeStore(client: client)
        let embedder = MLXEmbedder()
        await gateway.register([
            RunShellTool(registry: processes),
            KBSearchTool(
                index: { [knowledgeStore, embedder] in
                    // Read at call time: documents are added while the app
                    // runs, and a tool holding a snapshot answers from a
                    // knowledge base that no longer exists.
                    var index = KnowledgeIndex(profile: embedder.profile)
                    for scope in [Scope.central, .policy] {
                        let chunks = (try? await knowledgeStore.load(scope: scope)) ?? []
                        try? index.insert(contentsOf: chunks.map {
                            $0.embeddingProfileID == embedder.profile.id ? $0 : $0.withoutEmbedding()
                        })
                    }
                    return index
                },
                embedder: embedder),
            WebSearchTool(),
            FetchPageTool(),
            // §12.3's gate. On the tool list rather than inside the Analyst so
            // it goes through the one hook chain like everything else, and so
            // the notebook's operator can ask for the same check by hand.
            StatTestTool(),
            // The four tools that closed a gap found by reading the plan
            // (2026-08-12): every one of these wraps a capability that was
            // finished, tested and reachable from nothing — `URLIngestor` was
            // referenced by exactly one file, its own. Sixth instance of D6.
            IngestURLTool(
                index: { [knowledgeStore, embedder] in
                    var index = KnowledgeIndex(profile: embedder.profile)
                    for scope in [Scope.central, .policy] {
                        let chunks = (try? await knowledgeStore.load(scope: scope)) ?? []
                        try? index.insert(contentsOf: chunks.map {
                            $0.embeddingProfileID == embedder.profile.id ? $0 : $0.withoutEmbedding()
                        })
                    }
                    return index
                },
                // Written through before the tool answers: an ingest held only
                // in memory is one the person loses without being told.
                persist: { [knowledgeStore] chunks in try await knowledgeStore.save(chunks) },
                embedder: embedder),
            SaveDocumentTool(directory: paths.documentsDirectory),
        ])
        // §7.3 / P8.5 — the agent writing down what it worked out. Registered
        // like any other tool, because that is the whole point: it goes through
        // the hook chain rather than around it. The tool list it validates a
        // skill against is read at call time from this same gateway, so a
        // skill may name a tool that arrived after boot — an MCP server's, or
        // a plugin's.
        await gateway.register(WriteSkillTool(
            directory: paths.skillsDirectory,
            knownTools: { [gateway] in Set(await gateway.registeredNames) }))

        // The budget is what this machine can actually serve, not what the
        // endpoint advertises. VLLMExecutor declares a 32k window; measured on
        // 16 GB, a 7.6k-token prompt to a 9B model took ~7.4 GB of unified
        // memory and the server started answering 500 — so the transcript is
        // kept well under that and compaction (§5.6) is what holds it there.
        let runner = AgentTurnRunner(router: router,
                                     gateway: gateway,
                                     transcript: conversations,
                                     spanSink: spans,
                                     contextManager: ContextManager(budget: 16_384))

        // The specialists share the router and the same gateway the chat uses,
        // so their tool calls go through the one hook chain (§5.3) rather than
        // a second path around it. Each still sees only its own tools — that
        // is enforced inside the specialist, not here.
        let specialistEnvironment = SpecialistEnvironment(router: router, gateway: gateway)
        let taskLedger = TaskLedgerStore(client: client)
        let team = TeamOrchestrator(
            router: router,
            specialists: [
                .researcher: Researcher(environment: specialistEnvironment),
                .analyst: Analyst(environment: specialistEnvironment),
                .engineer: Engineer(environment: specialistEnvironment),
                .writer: Writer(environment: specialistEnvironment),
            ],
            // Spelled out rather than left to the default argument: review is
            // the step that decides whether work is done (§2.5), and a default
            // makes it look optional on the diagram that says what this app is
            // made of.
            reviewer: QAReviewer(),
            ledgerStore: taskLedger)

        // Nil rather than a failed boot: analysis is one screen among several,
        // and a corrupt `.duckdb` must not be the reason chat will not open.
        let analysis = try? AnalysisStore(
            fileURL: paths.analysisDirectory.appending(path: "analysis.duckdb"))
        let notebooks = NotebookStore(
            directory: paths.analysisDirectory.appending(path: "notebooks"))
        // §12.2 — saved connections to other people's databases. A file rather
        // than a row: it has to be readable before anything is connected to
        // anything, and a person should be able to open it and see that their
        // password is not in it.
        let connectors = ConnectorStore(
            file: paths.analysisDirectory.appending(path: "connectors.json"))
        // §12 — registered here rather than above because this is where the
        // store exists. The Analyst's tool list was `kb_search`, `run_shell`,
        // `run_stat_test`: the specialist whose whole job is analysis could not
        // reach the analysis store at all (found 2026-08-12).
        await gateway.register([
            AnalysisQueryTool(store: { analysis }),
            AnalysisExecuteTool(store: { analysis }),
            PullDBTableTool(store: { analysis }, connectors: { connectors.load() }),
        ])
        // Nil on a machine with no Python: the notebook's SQL cells still work,
        // and the screen says which half is missing rather than failing at the
        // first Python cell.
        let notebookKernel = try? NotebookKernel(workingDirectory: paths.analysisDirectory)

        // §8 — Telegram, if an account is configured and its token is in the
        // environment. Started here so the phone works from boot rather than
        // from whenever somebody opens a screen; an account that is not ready
        // says why and is skipped, because a channel that cannot run must not
        // stop the app from starting.
        let channelAccounts = ChannelAccountStore(
            file: paths.root.appending(path: "channels.json"))
        let channelRouter = ChannelRouter(runner: runner, conversations: conversations,
                                          modes: .default)
        for account in channelAccounts.load() where account.isReady {
            let channel: any RunnableChannel
            switch account.platform {
            case .telegram: channel = TelegramChannel(account: account, answering: broker)
            case .discord: channel = DiscordChannel(account: account, answering: broker)
            case .line: channel = LINEChannel(account: account, answering: broker)
            case .appIntents:
                // Not configured in the file and not one of many: there is a
                // single Siri, it is always on, and it is built below.
                continue
            }
            await broker.subscribe(channel)
            await channelRouter.register(channel, for: account.id)
            await channel.start(handler: channelRouter)
        }

        // §14.3 — Siri, Shortcuts and Spotlight. Always registered rather than
        // configured: there is nothing to configure, and an intent that finds
        // no channel is a Shortcut that fails with nothing to say.
        let appIntents = AppIntentsChannel()
        await broker.subscribe(appIntents)
        await channelRouter.register(appIntents, for: AppIntentsChannel.accountID)
        await appIntents.start(handler: channelRouter)

        // §8.1 — the channel that only speaks. Subscribed to the broker so an
        // approval reaches the person when the window is not the thing they
        // are looking at; it can answer nothing, which is why it is safe to
        // have it announce everything the others would.
        let notifier = Notifier(delivery: UserNotificationDelivery(),
                                userIsWatching: { await MainActor.run { NSApp.isActive } })
        await broker.subscribe(notifier)

        // §6.2 — MCP servers, connected and put on the tool list. This runs
        // before the roster is read, and that order is the point: a manifest
        // may name `mcp__…` in its `tools:`, and P8.1 validates those names
        // against what is registered. Registered after the built-ins so a
        // server cannot shadow `run_shell` by offering a tool of that name —
        // the namespace prevents it, and the order means it could not win
        // anyway.
        let mcpServers = MCPServerStore(file: paths.root.appending(path: "mcp-servers.json"))
        // §7.1 — a plugin is a packaged MCP server, so it joins the same list
        // rather than getting a second connection path. The difference between
        // the two is where the package came from and who may delete it.
        let plugins = PluginRegistry(directory: paths.pluginsDirectory)
        let mcp = MCPRegistry()
        let mcpOutcome = await mcp.connectAll(
            mcpServers.load() + plugins.installed().map(Self.server(for:)))
        await gateway.register(mcp.tools())
        let mcpProblems = mcpOutcome.failures.map { "MCP '\($0.name)': \($0.reason)" }

        // §7 — the roster. Validated against the tools that are actually
        // registered, so a name that does not exist is caught here rather than
        // mid-turn.
        let adverts = await gateway.adverts
        let manifests = ManifestParser(
            knownTools: Set(adverts.map(\.name)),
            toolRisks: Dictionary(uniqueKeysWithValues: adverts.map { ($0.name, $0.declaredRisk) }))
        let agents = manifests.load(directory: paths.agentsDirectory, kind: ManifestKind.agent)
        let skills = manifests.load(directory: paths.skillsDirectory, kind: ManifestKind.skill)
        let roster = (agents.manifests + skills.manifests).map(manifests.entry(for:))
        let rosterProblems = (agents.errors + skills.errors).map { "\($0)" }

        var summary: [String] = []
        for executor in executors {
            let reachable = await executor.isAvailable()
            summary.append("\(executor.identifier) — \(reachable ? "พร้อมใช้" : "ยังต่อไม่ได้")")
        }

        return Engine(client: client, conversations: conversations, spans: spans,
                      conflicts: ConflictStore(client: client),
                      conflictDetector: ConflictDetector(router: router),
                      relations: RelationStore(client: client),
                      relationExtractor: RelationExtractor(router: router),
                      knowledge: knowledgeStore,
                      router: router, processes: processes, gateway: gateway,
                      broker: broker, runner: runner,
                      team: team, taskLedger: taskLedger, projects: projects,
                      executorSummary: summary, localTier: localTier,
                      modelCatalog: modelCatalog, modelInstaller: modelInstaller,
                      endpoints: endpoints, endpointChecks: endpointChecks,
                      governor: governor, spendLedger: spendLedger,
                      analysis: analysis, notebooks: notebooks,
                      notebookKernel: notebookKernel, connectors: connectors,
                      plans: AnalysisPlanStore(client: client),
                      gapDetector: GapDetector(router: router),
                      templates: TemplateStore(
                        file: paths.root.appending(path: "templates.json")),
                      channelAccounts: channelAccounts, channelRouter: channelRouter,
                      appIntents: appIntents,
                      roster: roster, rosterProblems: rosterProblems,
                      mcpServers: mcpServers, plugins: plugins, mcp: mcp,
                      mcpConnected: mcpOutcome.connected, mcpProblems: mcpProblems)
    }

    /// How an installed package becomes a server to launch (§7.1, P8.4).
    ///
    /// The whole join between M3 and M6, written once: Roster describes a
    /// package and may not import MCPBridge — `MCPTool` is an `AgentTool`, and
    /// the roster is no more allowed to reach one than a channel is.
    static func server(for plugin: InstalledPlugin) -> MCPServerConfig {
        MCPServerConfig(id: "plugin:\(plugin.id)",
                        name: plugin.name,
                        command: plugin.command,
                        arguments: plugin.arguments,
                        workingDirectory: plugin.workingDirectory,
                        environmentVariables: plugin.environmentVariables)
    }

    /// Nothing the engine started may outlive the app (§13).
    func shutdown() async {
        await broker.cancelAll()
        await processes.stopAll()
        // The kernel is a process too, and it is not in the registry — it
        // outlives every cell by design, so it has to be closed by name.
        await notebookKernel?.stop()
        // Same rule, same reason: an MCP server is a child process, and it is
        // not in the registry either.
        await mcp.shutdown()
        await appIntents.stop()
        await channelRouter.stopAll()
        await client.close()
    }
}
