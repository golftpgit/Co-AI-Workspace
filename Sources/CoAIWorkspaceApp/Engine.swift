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
import RBridge
import Knowledge
import EmbeddingRuntime
import MLXRuntime
import Analysis
import Channels
import Roster
import DocGen
import MCPBridge
import WebSearch
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
    /// Where things go on disk (§19.1). Held because a project report is a file
    /// as well as a row, and the folder it belongs in is the project's own.
    let paths: AppPaths
    /// §1.4.1 / P13.1 — T5 search and page reading through the app's own headless
    /// web view. Held so the Sources screen can use the same instances the agent's
    /// tools do: a second browser would be a second cookie jar and a second
    /// rate-limit budget.
    let webSource: HeadlessWebSource
    let pageReader: HeadlessPageReader

    let conversations: ConversationStore
    /// The one embedder, shared (§11.5). Exposed because conversation search
    /// needs a query vector (P10.14) and a second instance would be a second
    /// model loaded into the same memory.
    let embedder: MLXEmbedder
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
    /// Which names a person said are one concept (§11.8, P18.3). Alongside
    /// `relations` because both are decisions about the graph, and both are
    /// only worth anything if they survive the next ingest.
    let alignments: AlignmentStore
    let relationExtractor: RelationExtractor
    /// The knowledge base's durable half. The screen keeps an in-memory index
    /// for search and writes through to this, so closing the app does not
    /// throw away what was ingested (P2.7).
    let knowledge: KnowledgeStore
    /// The hook chain's rulebook, so ingest can invalidate it (R14).
    let policySource: PolicyLibrarySource
    let router: ModelRouter
    let processes: ProcessRegistry
    let gateway: ToolGateway
    let broker: ApprovalBroker
    let runner: AgentTurnRunner
    /// The team from P4, and the ledger it writes as it goes. Assembled here
    /// for the same reason as everything else on this struct: four specialists
    /// and an orchestrator with twenty passing tests were reachable from
    /// nothing but those tests, which is the fourth time that has happened.
    ///
    /// **One lead per workspace since P21.2** (§19.1.1). It was a single
    /// orchestrator re-pointed with `use(scope:)` whenever the screen changed
    /// workspace, which cannot be right for a thing that can be in the middle of
    /// a run: mid-run the switch is refused, so the tab you switched *to* then
    /// filed its rows under the project you left.
    let teams: WorkspaceTeams
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
    /// General's analysis store. A project uses its own — see `stores(for:)`.
    let analysis: AnalysisStore?
    /// Where notebooks are kept, and the interpreter that runs their Python
    /// cells (§12.5, P6.4). The kernel is *constructed* here and started by the
    /// screen: resolving an interpreter costs nothing, and launching a Python
    /// process at boot for a screen nobody may open costs a process.
    let notebooks: NotebookStore
    let notebookKernel: NotebookKernel?
    let connectors: ConnectorStore
    /// §19.1 — per-project files. Opened on first use and kept, because two
    /// `AnalysisStore` instances on one file is a second writer, not a slow
    /// path.
    let workspaceStores: WorkspaceStoreCache
    /// §12.4 — the pre-registration and the model that reads a proposal into
    /// one. The plan store is durable for the same reason the conflict ledger
    /// is: a method agreed only in memory was never agreed.
    let plans: AnalysisPlanStore
    let gapDetector: GapDetector
    /// §19.1 / P10.3 — turns the conversation that became work into a draft
    /// brief. Held here for the usual reason: a capability the app cannot
    /// reach is not a feature.
    let briefDrafter: BriefDrafter
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
    /// The project types available to create with (§20.2, P11.1). The six the
    /// app ships, plus anything the person has put in their own folder — which
    /// is what makes adding a type a file rather than a release.
    let projectTypes: [ProjectTypeManifest]
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
        // Before anything reads a secret. A `.app` launched from Finder
        // inherits none of the user's shell — measured with `launchctl getenv`,
        // see `SecretStore` — so without this line every paid endpoint, bot and
        // connector in the app has no way to be given its key (P9.3).
        SecretStore.install(KeychainVault())

        let client = SurrealClient(url: URL(string: "ws://127.0.0.1:\(config.surrealPort)/rpc")!)
        try await client.connect()
        try await client.bootstrap(user: "root", password: "root")

        let spans = SurrealSpanSink(client: client)
        let conversations = ConversationStore(client: client)

        // One browser for the whole app: WebKit is main-actor only, and a second
        // web view would be a second cookie jar and a second thing to keep
        // polite about rate limits (§1.4.1).
        let browser = await MainActor.run { HeadlessBrowser() }
        let webSource = HeadlessWebSource(browser: browser)
        let pageReader = HeadlessPageReader(browser: browser)


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
        /// The window of the endpoint the app will normally talk to, as the
        /// server reports it (§17.1, P15.3). Nil when nothing answered — and
        /// nil stays nil rather than becoming a guessed number.
        var defaultWindow: Int?
        for endpoint in endpoints.endpoints {
            guard let url = endpoint.url else { continue }
            // Probed at boot so the status dots are true when the screen opens,
            // and so a typo in a model name is visible before it is used
            // (E.9 case 8a). The same reply says how big the window is and
            // which model is really being served, so neither is guessed
            // (P15.1/P15.3).
            let check = await probe.check(endpoint)
            endpointChecks[endpoint.id] = check
            if endpoint.id == endpoints.defaultEndpointID || defaultWindow == nil {
                defaultWindow = check.served?.maxModelLength ?? defaultWindow
            }
            executors.append(VLLMExecutor(
                identifier: endpoint.name,
                baseURL: url,
                // Whatever the config says, including nothing: an empty name
                // means "the model this server serves", and `VLLMExecutor`
                // asks. A pinned name that no longer exists takes the endpoint
                // out of the chain with nothing on screen saying why.
                model: endpoint.model,
                apiKey: endpoint.apiKey,
                tier: endpoint.kind == .paid ? .paid : .selfHosted,
                price: endpoint.inputPricePerMillion.flatMap { input in
                    endpoint.outputPricePerMillion.map {
                        TokenPrice(inputPerMillion: input, outputPerMillion: $0)
                    }
                },
                capabilities: .init(
                    // Declared by the server, not by this file. It read 32_768
                    // here for every endpoint, so raising `--max-model-len`
                    // changed nothing and lowering it made the app overflow a
                    // window it believed was bigger.
                    contextWindow: check.served?.maxModelLength ?? 32_768,
                    supportsTools: true,
                    supportsStructuredOutput: true,
                    supportsStreaming: true,
                    supportsVision: false)))
        }

        // §9.5 — only the metered tier passes through it, and only ever to be
        // sent somewhere cheaper rather than to fail.
        let spendLedger = SurrealSpendLedger(client: client)
        let governor = BudgetGovernor(limits: config.budget ?? .conservative,
                                      ledger: spendLedger, spanSink: spans)
        let router = ModelRouter(executors: executors, spanSink: spans, governor: governor)

        let processes = ProcessRegistry(spanSink: spans)
        let broker = ApprovalBroker(spanSink: spans)
        // Built before the project service: lessons from a closed project land
        // in the central knowledge base, so the service needs somewhere to put
        // them (§19.12 condition 7).
        let knowledgeStore = KnowledgeStore(client: client)
        // R14 — P2.6's policy gate, installed. Until 2026-08-15 this line read
        // `HookChain(stageGate:)`, which takes the default `NoPolicyGate`, so
        // no rule in the `policy` scope had ever stopped a call in the built
        // app while eleven tests said otherwise. `check.sh` now fails if the
        // policy gate goes missing from here again.
        let policySource = PolicyLibrarySource(reader: knowledgeStore)
        // §19.4 — the stage gate is wired here rather than defaulted off.
        // `HookChain()` with no reader refuses every project-scoped call, which
        // is the safe default for a library; the app is the place that knows
        // where stages come from.
        let projects = ProjectService(
            store: ProjectStore(client: client),
            plans: WorkPackageStore(client: client),
            exceptions: ExceptionStore(client: client),
            registers: RegisterStore(client: client),
            baselines: BaselineStore(client: client),
            lessons: LessonPublisher(knowledge: knowledgeStore),
            // §19.1.1's handover (P21.4): the external references this project
            // gathered go up with their tiers, the precedents it declared
            // become everybody's, and the participants' words stay exactly
            // where the people who gave them agreed they would.
            handover: ClosingHandoverStore(knowledge: knowledgeStore,
                                           conflicts: ConflictStore(client: client)),
            benefits: BenefitStore(client: client),
            tailoring: TailoringStore(client: client),
            // §19.12 conditions 4–5. Wired here for the reason the whole gate
            // exists: without this the two conditions read "ยังตรวจไม่ได้" and
            // refuse to close, which is correct but useless — the app is the
            // only place that has both the conflict ledger and the plans.
            closingLedger: ClosingLedger(conflicts: ConflictStore(client: client),
                                         plans: AnalysisPlanStore(client: client)),
            reports: ReportStore(client: client),
            // P11.10 — condition 8 reads the project's own response store and
            // the same policy scope the hook chain enforces (R14).
            retentionFacts: WorkspaceRetentionFacts(paths: paths,
                                                    policySource: policySource))
        // §19.10 — an exception raised before the app closed must still stop
        // work after it reopens, so the blocked set is read at boot rather
        // than starting empty and filling in when somebody opens the screen.
        await projects.refreshExceptions()
        // §24.3 / P20.4 — how this role has done with this tool before, read
        // at decision time from the spans that already record it. Cached for a
        // minute: the gate is on the path of every call and this is a query
        // over two thousand rows, but a stale answer here is a call judged by
        // last week's record.
        let proficiency = ProficiencyCache(spans: spans)
        let gateway = ToolGateway(chain: HookChain(stageGate: StageGate(reader: projects),
                                                   policyGate: StoredPolicyGate(source: policySource),
                                                   proficiency: { role, tool in
                                                       await proficiency.record(role: role,
                                                                                tool: tool)
                                                   }),
                                  approver: broker,
                                  spanSink: spans,
                                  modes: .default)
        // §19.11 / P10.8 — the tools that let a specialist file what it
        // noticed. The rule they exist to make testable is that an agent may
        // *propose* and may not decide: `propose_change` writes `proposed` and
        // there is no tool that can approve one.
        await gateway.register([
            RaiseRiskTool(service: { projects }),
            ProposeChangeTool(service: { projects }),
        ])
        // Everything P2 and P3 built is only a feature once it is on the tool
        // list — v1 shipped an MCP client that no session could reach (D6).
        let embedder = MLXEmbedder()
        let declaredViews = DeclaredKnowledgeViews()
        // §21.2 / P12.6 — widenings granted during a conversation. One instance
        // shared by the tool that grants them and the search that reads them,
        // or `widen_view` would report success and change nothing.
        let viewWidenings = ViewWidenings()
        await gateway.register([
            RunShellTool(registry: processes),
            // The only tool with the network open, and the only one that runs
            // code nobody here wrote (§10, P8.4). Scoped per project so the
            // packages a study depends on live with the study.
            InstallPackageTool(registry: processes,
                               directoryForScope: { [paths] scope in
                                   guard case .project(let id) = scope else { return nil }
                                   return paths.project(id).packagesDirectory
                               }),
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
                embedder: embedder,
                // §21.2 / P12.2 — the view a role searches through. A manifest
                // may declare its own; otherwise the standard one for that
                // role applies, so "why did the Writer not see that" is
                // answered by a file rather than by reasoning about a prompt.
                //
                // Through a box because the roster is parsed further down —
                // it needs the tool list this registration is building. Read
                // at call time either way, which is the same rule the index
                // closure above follows.
                views: { [declaredViews] role in declaredViews.view(for: role) },
                widenings: viewWidenings),
            WidenViewTool(widenings: viewWidenings, spans: spans,
                          baseView: { [declaredViews] role in
                              declaredViews.view(for: role) ?? .standard(for: role)
                          }),
            // §1.4.1 / P13.1 — T5 through the app's own headless web view. The
            // tool contract does not change: the agent still calls `web_search`
            // and still has to `fetch_page` before citing anything. What changes
            // is that both now work inside the sandboxed .app with nothing
            // bundled, and that `fetch_page` can read a page whose text is
            // produced by JavaScript.
            // §1.4.1 / P13.1 — T5 through the app's own headless web view. The
            // tool contract does not change: the agent still calls `web_search`
            // and still has to `fetch_page` before citing anything. What changes
            // is that both now work inside the sandboxed .app with nothing
            // bundled, and that `fetch_page` can read a page whose text is
            // produced by JavaScript.
            WebSearchTool(source: webSource),
            FetchPageTool(fetcher: pageReader),
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

        // The window the server reports, minus room for the answer (§17.1,
        // P15.3). It was `16_384` written here — half of a 32k window that was
        // also written into Swift, so changing `--max-model-len` on the server
        // moved neither number.
        //
        // The fallback is the old figure, and it is a floor rather than a
        // guess: measured on 16 GB, a 7.6k-token prompt to a 9B model took
        // ~7.4 GB of unified memory and the server began answering 500. With no
        // endpoint reachable at boot, that is the machine the app is on.
        let promptBudget = defaultWindow.map { ContextManager.promptBudget(forWindow: $0) } ?? 16_384
        let runner = AgentTurnRunner(router: router,
                                     gateway: gateway,
                                     transcript: conversations,
                                     spanSink: spans,
                                     contextManager: ContextManager(budget: promptBudget))

        // The specialists share the router and the same gateway the chat uses,
        // so their tool calls go through the one hook chain (§5.3) rather than
        // a second path around it. Each still sees only its own tools — that
        // is enforced inside the specialist, not here.
        // §5.5 / P4.8 — one budget object per workspace lead, shared with the
        // specialists' environment. Shared rather than counted in two places:
        // the tokens a specialist spends are the tokens the run spent, and two
        // counters would disagree the first time one of them was not updated.
        let runBudget = RunBudget()
        let specialistEnvironment = SpecialistEnvironment(router: router, gateway: gateway,
                                                          budget: runBudget)
        let taskLedger = TaskLedgerStore(client: client)
        // One lead per workspace, built the first time that workspace is worked
        // in (§19.1.1, P21.2). A factory rather than an instance: the wiring
        // below is the app's, and `WorkspaceTeams` only guarantees there is
        // exactly one lead per workspace and that a running one is not thrown
        // away when its tab closes.
        let teams = WorkspaceTeams { scope in
            TeamOrchestrator(
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
                ledgerStore: taskLedger,
                // The same sink every tool call and turn already writes to (§16).
                // Until this the team was the one part of the system that produced
                // no spans at all, so the schedule had no durations to draw and the
                // forecast band had to be built out of chat turns.
                spans: spans,
                // §21.2 / P12.7 — the lessons a closed project left behind, in
                // front of the role that should already know them. Read at
                // assignment time so a project closed this morning teaches this
                // afternoon's work.
                roleMemory: { role in
                    let lessons = (try? await knowledgeStore.load(scope: .central)) ?? []
                    return RoleMemory.brief(for: role, in: lessons)
                },
                budget: runBudget,
                // Pointed at its workspace from birth, so nothing ever has to
                // re-point it — which is the move that could not be made safely
                // mid-run.
                scope: scope)
        }

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
        let workspaceStores = WorkspaceStoreCache(
            paths: paths,
            shared: WorkspaceStores(analysis: analysis, notebooks: notebooks,
                                    connectors: connectors, workingDirectory: nil))
        // §12 — registered here rather than above because this is where the
        // store exists. The Analyst's tool list was `kb_search`, `run_shell`,
        // `run_stat_test`: the specialist whose whole job is analysis could not
        // reach the analysis store at all (found 2026-08-12).
        await gateway.register([
            AnalysisQueryTool(store: { analysis }),
            AnalysisExecuteTool(store: { analysis }),
            PullDBTableTool(store: { analysis }, connectors: { connectors.load() }),
        ])
        // §12.7 — R, if the person has started the bridge. Registered whether
        // or not it is running: a tool that only appears once the bridge is up
        // is a tool the model never learns exists, and the refusal it gets
        // when the bridge is down is the sentence that tells somebody how to
        // start it (P14.2).
        let rBridgeScript = paths.analysisDirectory.appending(path: BridgeScript.fileName)
        let rBridge = { @Sendable in
            RBridgeClient(scriptPath: rBridgeScript.path(percentEncoded: false))
        }
        await gateway.register([
            REvalTool(bridge: rBridge, store: { analysis }),
            RInstallPackageTool(bridge: rBridge),
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
        // Fill the box the knowledge-view lookup reads (§21.2). A manifest that
        // declares nothing leaves the role on its standard view.
        declaredViews.fill(from: roster)

        // §20.2 — project types, read with the same parser. Bundled first so a
        // fresh install can create a research project on day one; the person's
        // own folder is laid on top, so a type they wrote wins over one that
        // shipped with the same name.
        var typesByName: [String: ProjectTypeManifest] = [:]
        var typeProblems: [String] = []
        for directory in [Bundle.main.resourceURL?.appending(path: "project-types"),
                          paths.projectTypesDirectory].compactMap({ $0 }) {
            let loaded = manifests.loadProjectTypes(directory: directory)
            for type in loaded.types { typesByName[type.type] = type }
            typeProblems.append(contentsOf: loaded.errors.map { "\($0)" })
        }
        let projectTypes = typesByName.values.sorted { $0.type < $1.type }
        let rosterProblems = (agents.errors + skills.errors).map { "\($0)" } + typeProblems

        // §20.2 — the `gate:` lines stop being data here. Wired after the types
        // are loaded rather than at construction because the parser that reads
        // them needs the tool list, which needs the gateway, which needs the
        // project service; the alternative was reading the type files twice.
        await projects.attach(typeGates: ProjectTypeGateReader(
            gatesByType: Dictionary(projectTypes.map { ($0.type, $0.gates) },
                                    uniquingKeysWith: { first, _ in first }),
            instruments: InstrumentStore(client: client),
            codebooks: CodebookStore(client: client)))

        var summary: [String] = []
        for executor in executors {
            let reachable = await executor.isAvailable()
            summary.append("\(executor.identifier) — \(reachable ? "พร้อมใช้" : "ยังต่อไม่ได้")")
        }

        return Engine(client: client, paths: paths,
                      webSource: webSource, pageReader: pageReader,
                      conversations: conversations, embedder: embedder, spans: spans,
                      conflicts: ConflictStore(client: client),
                      conflictDetector: ConflictDetector(router: router),
                      relations: RelationStore(client: client),
                      alignments: AlignmentStore(client: client),
                      relationExtractor: RelationExtractor(router: router),
                      knowledge: knowledgeStore, policySource: policySource,
                      router: router, processes: processes, gateway: gateway,
                      broker: broker, runner: runner,
                      teams: teams, taskLedger: taskLedger, projects: projects,
                      executorSummary: summary, localTier: localTier,
                      modelCatalog: modelCatalog, modelInstaller: modelInstaller,
                      endpoints: endpoints, endpointChecks: endpointChecks,
                      governor: governor, spendLedger: spendLedger,
                      analysis: analysis, notebooks: notebooks,
                      notebookKernel: notebookKernel, connectors: connectors,
                      workspaceStores: workspaceStores,
                      plans: AnalysisPlanStore(client: client),
                      gapDetector: GapDetector(router: router),
                      briefDrafter: BriefDrafter(router: router),
                      templates: TemplateStore(
                        file: paths.root.appending(path: "templates.json")),
                      channelAccounts: channelAccounts, channelRouter: channelRouter,
                      appIntents: appIntents,
                      roster: roster, rosterProblems: rosterProblems,
                      projectTypes: projectTypes,
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

extension Engine {
    /// The stores for a workspace. General gets the app-wide ones; a project
    /// gets its own folder, opened the first time it is asked for.
    func stores(for scope: Scope) async -> WorkspaceStores {
        await workspaceStores.stores(for: scope)
    }

    /// The lead for a workspace, made the first time that workspace is worked
    /// in (§19.1.1, P21.2). Same rule as `stores(for:)` and for the same
    /// reason: one per workspace, kept, never re-pointed.
    func team(for scope: Scope) async -> TeamOrchestrator {
        await teams.team(for: scope)
    }
}

/// How well each role does with each tool, for the gate that stops trusting a
/// role that keeps failing (§24.3, P20.4).
///
/// A cache in front of the span query because the hook chain asks on every
/// call and the query reads two thousand rows. One minute, because the number
/// only moves when calls happen and a call judged by last week's record is the
/// failure this exists to prevent.
actor ProficiencyCache {
    private let spans: SurrealSpanSink
    private var records: [ToolProficiency] = []
    private var readAt: ContinuousClock.Instant?

    init(spans: SurrealSpanSink) { self.spans = spans }

    func record(role: Role?, tool: String) async -> ToolProficiency? {
        guard let role else { return nil }
        if readAt == nil || readAt!.duration(to: .now) > .seconds(60) {
            records = (try? await spans.toolProficiency()) ?? []
            readAt = .now
        }
        return records.first { $0.role == role && $0.tool == tool }
    }
}

/// The per-role knowledge views declared in manifests (§21.2, P12.2).
///
/// A box because of an ordering knot: `kb_search` is registered before the
/// roster is parsed, and the roster cannot be parsed until the tool list
/// exists — the parser refuses a manifest naming a tool the system does not
/// have, which is a check worth keeping. Read at call time rather than
/// captured, which is what `kb_search`'s index closure already does and for
/// the same reason: the roster is reloaded while the app runs.
final class DeclaredKnowledgeViews: @unchecked Sendable {
    private let lock = NSLock()
    private var byRole: [Role: KnowledgeView] = [:]

    func fill(from roster: [RosterEntry]) {
        var found: [Role: KnowledgeView] = [:]
        for entry in roster {
            guard let role = entry.manifest.base,
                  let json = entry.manifest.knowledgeViewJSON,
                  let data = json.data(using: .utf8),
                  let view = try? JSONDecoder().decode(KnowledgeView.self, from: data)
            else { continue }
            found[role] = view
        }
        lock.withLock { byRole = found }
    }

    /// `nil` leaves the role on `KnowledgeView.standard(for:)` — the fallback
    /// belongs to the tool, so there is one place that decides it.
    func view(for role: Role) -> KnowledgeView? {
        lock.withLock { byRole[role] }
    }
}
