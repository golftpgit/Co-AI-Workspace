import Foundation
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
    /// Which executors were actually reachable at boot — shown in the UI so
    /// "why is it slow / why can't it run commands" has a visible answer.
    let executorSummary: [String]
    /// The Tier 0.5 model this machine has, if any (P5.1). Nil means the floor
    /// §9.2 rule 4 promises is missing, which the boot screen has to say.
    let localModel: LocalModel?

    static func build(config: BootstrapConfig, paths: AppPaths) async throws -> Engine {
        let client = SurrealClient(url: URL(string: "ws://127.0.0.1:\(config.surrealPort)/rpc")!)
        try await client.connect()
        try await client.bootstrap(user: "root", password: "root")

        let spans = SurrealSpanSink(client: client)
        let conversations = ConversationStore(client: client)

        var executors: [any LLMExecutor] = [OnDeviceExecutor()]
        // Tier 0.5 — the floor the rest of the chain falls back to (§9.2 rule
        // 4). Found on disk rather than downloaded: boot must not depend on a
        // network, and P5.2 is what installs a model when there is none.
        let localModel = LocalModelCatalog
            .standard(appModelsDirectory: paths.modelsDirectory)
            .preferred()
        if let localModel { executors.append(MLXExecutor(model: localModel)) }
        if let endpoint = config.selfHostedEndpoint, let model = config.selfHostedModel,
           let url = URL(string: endpoint) {
            executors.append(VLLMExecutor(baseURL: url, model: model))
        }
        let router = ModelRouter(executors: executors, spanSink: spans)

        let processes = ProcessRegistry(spanSink: spans)
        let broker = ApprovalBroker(spanSink: spans)
        let gateway = ToolGateway(chain: HookChain(),
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
        ])

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
                      team: team, taskLedger: taskLedger,
                      executorSummary: summary, localModel: localModel)
    }

    /// Nothing the engine started may outlive the app (§13).
    func shutdown() async {
        await broker.cancelAll()
        await processes.stopAll()
        await client.close()
    }
}
