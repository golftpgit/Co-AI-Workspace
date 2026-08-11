// swift-tools-version: 6.2
import PackageDescription

// Co-AI Workspace — module layout follows ARCHITECTURE.md §3 / §4.
// Targets are added phase by phase (see IMPLEMENTATION_PLAN.md); P0 lands the
// foundation ones only: AgentKit (types), Config, Observability, Sidecar, App.
let package = Package(
    name: "CoAIWorkspace",
    platforms: [.macOS(.v26)],
    // MLX runs the embedding model in our own process rather than over HTTP to
    // whatever the user happens to have installed (ARCHITECTURE E.13). Its
    // Metal kernels cannot be built by SwiftPM — `scripts/build-metallib.sh`
    // produces them once per machine, the same shape as the surreal binary.
    products: [
        .executable(name: "CoAIWorkspace", targets: ["CoAIWorkspaceApp"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
    ],
    targets: [
        // M2 — shared types/protocols only, no logic. Everything may import this.
        .target(name: "AgentKit"),

        // M11 — bootstrap config, paths, (settings + Keychain arrive in P9/P5).
        .target(name: "Config", dependencies: ["AgentKit"]),

        // M12 — spans. P0 ships the type + console sink; the SurrealDB sink is P1.6.
        .target(name: "Observability", dependencies: ["AgentKit"]),

        // Infrastructure shared by M7 (surreal) and M6/WebSearch (searxng).
        .target(name: "Sidecar", dependencies: ["Config", "Observability"]),

        // SurrealDB access + everything durable: conversations, spans and
        // (from P2) the knowledge base. Client written in-house — see
        // ARCHITECTURE §11.5 for why not surrealdb.swift.
        .target(name: "Persistence", dependencies: ["AgentKit", "Observability", "Knowledge"]),

        // M5 — every model behind one interface, plus the router that decides
        // which tier serves a request (ARCHITECTURE §9).
        .target(name: "LLMProviders", dependencies: ["AgentKit", "Observability"]),

        // M9 — every process the system runs: sandbox profile, process group
        // signals, registry (ARCHITECTURE §13). Knows nothing about agents.
        .target(name: "Execution", dependencies: ["AgentKit", "Observability", "Config"]),

        // M6 — the tools themselves. Depends on Execution, never the reverse,
        // and CoreEngine never depends on this: tools plug in via AgentTool.
        .target(name: "ToolBelt",
                dependencies: ["AgentKit", "Observability", "Execution",
                               "Knowledge", "WebSearch"]),

        // M7 — the knowledge base's own logic: tokenisation, chunking and the
        // lexical half of hybrid search (ARCHITECTURE §11). Deliberately free
        // of storage and models so it can be measured on its own.
        .target(name: "Knowledge", dependencies: ["AgentKit", "Observability"]),

        // M6/WebSearch — reading the web (ARCHITECTURE §1.4). Search results
        // are not evidence; anything worth citing is fetched and read.
        .target(name: "WebSearch", dependencies: ["AgentKit", "Observability", "Knowledge"]),

        // M5/M7 — the embedding model, in-process. Depends on Knowledge (which
        // owns the `Embedder` protocol) and never the other way round, so the
        // knowledge logic and its tests stay free of a heavy ML dependency.
        .target(
            name: "EmbeddingRuntime",
            dependencies: [
                "Knowledge", "Observability",
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]),

        // Checks the embedding model against the real weights. An executable
        // rather than a test target: MLX finds its Metal kernels through the
        // main bundle, and under `swift test` that is SwiftPM's helper, which
        // has no idea where ours are. Run by scripts/check.sh.
        .executableTarget(name: "EmbeddingCheck",
                          dependencies: ["EmbeddingRuntime", "Knowledge", "Persistence",
                                         "Sidecar", "Config"]),

        // M1 — hook chain, approval broker, tool gateway, agent loop. Every
        // decision the system makes lives here (ARCHITECTURE §5).
        .target(name: "CoreEngine",
                dependencies: ["AgentKit", "Observability", "LLMProviders", "Persistence",
                               "Knowledge"]),
        // Kept out of CoreEngine's own tests: this one needs a model.

        // M13 — SwiftUI shell.
        .executableTarget(
            name: "CoAIWorkspaceApp",
            dependencies: ["AgentKit", "Config", "Observability", "Sidecar", "Persistence",
                           "LLMProviders", "CoreEngine", "Execution", "ToolBelt",
                           "Knowledge", "EmbeddingRuntime"]
        ),

        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "ConfigTests", dependencies: ["Config"]),
        .testTarget(name: "ObservabilityTests", dependencies: ["Observability"]),
        .testTarget(name: "SidecarTests", dependencies: ["Sidecar"]),
        .testTarget(name: "PersistenceTests",
                    dependencies: ["Persistence", "Sidecar", "Config", "Knowledge"]),
        .testTarget(name: "LLMProvidersTests", dependencies: ["LLMProviders"]),
        .testTarget(name: "CoreEngineTests", dependencies: ["CoreEngine", "Knowledge"]),
        .testTarget(name: "KnowledgeTests", dependencies: ["Knowledge"]),
        .testTarget(name: "WebSearchTests", dependencies: ["WebSearch", "Knowledge"]),
        .testTarget(name: "EmbeddingRuntimeTests", dependencies: ["EmbeddingRuntime"]),
        .testTarget(name: "ExecutionTests", dependencies: ["Execution", "Config"]),
        // Also hosts the end-to-end walking-skeleton test, which needs a real
        // database and a real sidecar alongside the tools and the gate.
        .testTarget(name: "ToolBeltTests",
                    dependencies: ["ToolBelt", "CoreEngine", "Persistence", "Sidecar", "Config",
                                   "Knowledge", "WebSearch"]),
    ]
)
