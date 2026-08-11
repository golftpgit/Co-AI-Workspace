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
    /// Which executors were actually reachable at boot — shown in the UI so
    /// "why is it slow / why can't it run commands" has a visible answer.
    let executorSummary: [String]

    static func build(config: BootstrapConfig, paths: AppPaths) async throws -> Engine {
        let client = SurrealClient(url: URL(string: "ws://127.0.0.1:\(config.surrealPort)/rpc")!)
        try await client.connect()
        try await client.bootstrap(user: "root", password: "root")

        let spans = SurrealSpanSink(client: client)
        let conversations = ConversationStore(client: client)

        var executors: [any LLMExecutor] = [OnDeviceExecutor()]
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

        let runner = AgentTurnRunner(router: router,
                                     gateway: gateway,
                                     transcript: conversations,
                                     spanSink: spans)

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
                      broker: broker, runner: runner, executorSummary: summary)
    }

    /// Nothing the engine started may outlive the app (§13).
    func shutdown() async {
        await broker.cancelAll()
        await processes.stopAll()
        await client.close()
    }
}
