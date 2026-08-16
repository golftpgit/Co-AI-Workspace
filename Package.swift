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
        // M8 — the analysis store (ARCHITECTURE §12.1). Official Swift package
        // rather than a C wrapper of our own; the C++ amalgamation inside it is
        // why a clean build of this project is measured in minutes.
        .package(url: "https://github.com/duckdb/duckdb-swift", from: "1.1.3"),
        // M6 — MCP, both halves (ARCHITECTURE §6.2, P8.3). The official SDK
        // rather than the JSON-RPC client v1 had to write and maintain itself.
        // Pinned at the minor: this SDK is pre-1.0, where a minor bump is
        // allowed to break, and `from:` would take one silently.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk",
                 "0.12.1"..<"0.13.0"),
    ],
    targets: [
        // M2 — shared types/protocols only, no logic. Everything may import this.
        .target(name: "AgentKit"),

        // The one call this project makes into LAPACK, behind a C header that
        // keeps Accelerate out of Swift (ARCHITECTURE §20.4). It exists as a C
        // target for one reason: `ACCELERATE_NEW_LAPACK` is a preprocessor macro,
        // and Swift's `-D` cannot reach the Clang module — without it the only
        // reachable interface is the one deprecated in macOS 13.3.
        .target(name: "CLapack",
                cSettings: [.define("ACCELERATE_NEW_LAPACK", to: "1")],
                linkerSettings: [.linkedFramework("Accelerate")]),

        // Arithmetic with no dependencies and no I/O: distribution tails and the
        // symmetric eigen-decomposition. Split out of `Statistics` in P11.3, when
        // M15 needed a chi-square tail and is not allowed to import M8 (§20.6).
        // One implementation of a continued fraction, not two that agree until
        // they do not.
        .target(name: "StatKit", dependencies: ["CLapack"]),

        // M11 — bootstrap config, paths, (settings + Keychain arrive in P9/P5).
        .target(name: "Config", dependencies: ["AgentKit"]),

        // M12 — spans. P0 ships the type + console sink; the SurrealDB sink is P1.6.
        .target(name: "Observability", dependencies: ["AgentKit"]),

        // Infrastructure shared by M7 (surreal) and M6/WebSearch (searxng).
        .target(name: "Sidecar", dependencies: ["Config", "Observability"]),

        // SurrealDB access + everything durable: conversations, spans and
        // (from P2) the knowledge base. Client written in-house — see
        // ARCHITECTURE §11.5 for why not surrealdb.swift.
        // DocGen is here for P11.9: the manuscript is a DocGen type and the
        // only thing Persistence does with it is keep it, which is the same
        // relationship it already has with ProjectKit and Instruments.
        .target(name: "Persistence", dependencies: ["AgentKit", "Observability", "Knowledge", "ProjectKit",
                                                    "Instruments", "DocGen"]),

        // M5 — every model behind one interface, plus the router that decides
        // which tier serves a request (ARCHITECTURE §9).
        .target(name: "LLMProviders", dependencies: ["AgentKit", "Observability"]),

        // M5/Tier 0.5 — the model we load and run ourselves (§9.4). Its own
        // target for the same reason as EmbeddingRuntime: LLMProviders owns
        // the interface and must stay free of MLX, so everything that merely
        // routes a request does not link a machine-learning framework.
        .target(
            name: "MLXRuntime",
            dependencies: [
                "LLMProviders", "AgentKit", "Observability",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                // Vision-language checkpoints are a different factory, not a
                // different tier: Qwen3-VL answers text like any chat model,
                // and on a 16 GB machine it may well be the only local model
                // the user has (see MLXExecutor.load).
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]),

        // What every executor owes its callers, written once. Used by
        // LLMProvidersTests for the tiers `swift test` can reach and by
        // MLXCheck for the one it cannot — see the target's own header.
        .target(name: "ExecutorContract", dependencies: ["LLMProviders", "AgentKit"]),

        // M8 — analysis: DuckDB, the connectors, and the SQL that runs against
        // them (ARCHITECTURE §12). Knows nothing about agents or models, so it
        // can be measured on its own.
        // Execution is here for the notebook kernel (P6.4): a Python kernel is
        // a process that outlives every cell, and §13 owns processes — spawning
        // one from this target would be a second way to start a child that the
        // kill switch does not know about.
        // OLTP arrived with P11.6b: answers land in SQLite and are pulled into
        // DuckDB from here (§19.17). The edge only goes this way — `OLTP` does
        // not know DuckDB exists, which is what keeps M16 unable to reach it.
        .target(name: "Analysis",
                dependencies: ["AgentKit", "Observability", "Execution", "OLTP", "StatKit",
                               .product(name: "DuckDB", package: "duckdb-swift")]),

        // M3 — the roster: agents, skills and plugins loaded from files
        // (ARCHITECTURE §7). Knows the *names* of tools and their declared
        // risk, and nothing else about them: it must not be able to reach a
        // tool any more than a channel can.
        // ProjectKit came in with P11.1: a project-type manifest names roles,
        // stages and practices, and every one of those is checked at load time
        // rather than where it is used. Checking them means knowing them.
        .target(name: "Roster", dependencies: ["AgentKit", "Observability", "ProjectKit"]),

        // M14 (ARCHITECTURE §19.15) — the project life cycle. It does *not*
        // depend on CoreEngine: the gate reads a stage through
        // `ProjectStageReading` in AgentKit, so the module that owns the
        // decision never has to import the module that owns the data.
        // Knowledge is here because `Retention` reads `PolicyRule` — the
        // retention rules a closing project is checked against are policy
        // documents, not a second vocabulary. The dependency was missing and
        // the package still built, because SwiftPM finds a module in the shared
        // build directory whether or not the target asked for it; a clean build
        // is where that shows up, and this one did not survive one.
        .target(name: "ProjectKit", dependencies: ["AgentKit", "Knowledge"]),

        // M4 — the channels (ARCHITECTURE §8). **This list is the invariant**
        // (P7.4): no ToolBelt, no CoreEngine, so a channel cannot reach a tool
        // or the gateway even by accident. v1's bug B2 was a Telegram bridge
        // that ran tools without passing the hook chain; here the types are not
        // in scope. `scripts/check.sh` fails if this line grows.
        .target(name: "Channels", dependencies: ["AgentKit", "Observability", "Config"]),

        // M10 — documents (ARCHITECTURE §14.1). Citations and the Limitations
        // section are logic over what the rest of the system already recorded,
        // so this target knows about provenance and plans and nothing else —
        // no models, no storage, no file formats.
        .target(name: "DocGen", dependencies: ["AgentKit", "Knowledge", "Observability",
                                            // §19.13 — the three project reports are
                                            // documents, and the mapping from a report to a
                                            // draft belongs next to the other renderers. The
                                            // edge only goes this way: ProjectKit does not
                                            // know what a .docx is.
                                            "ProjectKit"]),

        // M9 — every process the system runs: sandbox profile, process group
        // signals, registry (ARCHITECTURE §13). Knows nothing about agents.
        .target(name: "Execution", dependencies: ["AgentKit", "Observability", "Config"]),

        // M-R — the bridge to a real R (ARCHITECTURE §12.7, P14). Its own
        // target because nothing else may depend on R being installed: the
        // statistics in `Analysis` are Swift and stay that way.
        .target(name: "RBridge", dependencies: ["Execution", "Observability"]),

        // P9.5 — the responsiveness probe. An executable rather than a test:
        // it measures wall-clock stalls, which is a measurement to read rather
        // than an assertion to run in CI.
        .executableTarget(name: "UIResponsivenessCheck"),

        // Driving a real screen, with a real permission granted (§23.2, P8.7).
        .executableTarget(name: "ScreenCheck", dependencies: ["ScreenDriver"]),

        // M6 — the tools themselves. Depends on Execution, never the reverse,
        // and CoreEngine never depends on this: tools plug in via AgentTool.
        // Analysis is here for `run_stat_test` (P6.6): the Statistical
        // Verification Gate is only a feature once the Analyst can reach it —
        // §12.3 is a hook on the Analyst's work, not a library on the shelf.
        // Roster is here for `write_skill` (P8.5): a skill an agent writes has
        // to be validated by the same parser that will load it, and a second
        // copy of §7.2's format in the tool layer would be the copy that
        // drifts. The dependency only goes this way — Roster must never be
        // able to see a tool.
        .target(name: "ToolBelt",
                dependencies: ["AgentKit", "Observability", "Execution",
                               "Knowledge", "WebSearch", "Analysis", "Roster", "DocGen",
                               "RBridge", "ProjectKit"]),

        // M6/MCP — other people's tools (ARCHITECTURE §6.2, P8.3). Its own
        // target rather than part of ToolBelt so the SDK, its NIO and its
        // logging stay out of every other tool's build; it depends on
        // Execution because spawning a server is §13's business, not its own.
        .target(name: "MCPBridge",
                dependencies: ["AgentKit", "Observability", "Execution",
                               .product(name: "MCP", package: "swift-sdk")]),

        // M7 — the knowledge base's own logic: tokenisation, chunking and the
        // lexical half of hybrid search (ARCHITECTURE §11). Deliberately free
        // of storage and models so it can be measured on its own.
        .target(name: "Knowledge", dependencies: ["AgentKit", "Observability"]),

        // M6/WebSearch — reading the web (ARCHITECTURE §1.4). Search results
        // are not evidence; anything worth citing is fetched and read.
        .target(name: "WebSearch", dependencies: ["AgentKit", "Observability", "Knowledge"]),

        // §19.17 — the OLTP gap M16 opened. SQLite (WAL) from the system, no
        // sidecar, no DuckDB. **Its own target on purpose**: it is what makes
        // "no code path from M16 to DuckDB" a fact about the package graph
        // rather than a sentence in a document. DuckDB reads these rows by
        // `ATTACH`ing the file, which is a read the app performs — never a write
        // the server performs.
        .target(name: "OLTP", dependencies: ["AgentKit", "Observability"]),

        // §20.7 Linkage — who answered, kept in a different file from what they
        // answered, sealed with a key from the Keychain. **Not a dependency of
        // FieldServer**, and that is the design: the server can never reach an
        // identity, because the type is not in its module graph.
        .target(name: "Linkage", dependencies: ["AgentKit", "Observability", "OLTP"]),

        // M16 FieldServer — the only surface in the system that takes input from
        // somebody who is not the owner of this machine (§20.7). Its dependency
        // list is an invariant too, in the other direction from M15's: it may
        // reach `Instruments` (to be handed something the gate approved) and
        // `OLTP` (to write answers), and it may **not** reach `Analysis` — there
        // is no code path from M16 to DuckDB (§19.17 invariant 1).
        .target(name: "FieldServer",
                dependencies: ["AgentKit", "Observability", "Instruments", "OLTP"]),

        // M15 Instruments — designing what data is collected with (ARCHITECTURE
        // §20.3). **The dependency list is the invariant**: no networking target
        // here, because serving a form is M16's job and an instrument that could
        // open a socket would be an instrument that could collect data before it
        // passed its gate. `StatKit` is arithmetic with no dependencies of its
        // own — EFA needs an eigen-decomposition and Bartlett's test needs a
        // chi-square tail, and neither of those is a way to reach a socket.
        .target(name: "Instruments",
                dependencies: ["AgentKit", "Knowledge", "Observability", "StatKit"]),

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
        // CoreEngine is here so the orchestrator can be driven against a real
        // ledger store: its own tests assert on the in-memory entries, which is
        // how a run whose writes stopped after the first attempt still passed.
        .executableTarget(name: "EmbeddingCheck",
                          // Analysis is here for §19.2's Workbench Done-when: that
                          // General can query a database with no project, proven by
                          // running one rather than by reading the wiring.
                          dependencies: ["EmbeddingRuntime", "Knowledge", "Persistence",
                                         "Sidecar", "Config", "CoreEngine", "ProjectKit",
                                         // ToolBelt/WebSearch for P13.2: the T5
                                         // rule is only proven by running the
                                         // real tool output into the real QA.
                                         "Analysis", "ToolBelt", "WebSearch"]),

        // The executor contract, run against Tier 0.5 with the real weights.
        // An executable for the same reason as EmbeddingCheck: MLX finds its
        // Metal kernels through the main bundle, and under `swift test` that is
        // SwiftPM's helper. Run by scripts/check.sh.
        // CoreEngine is here for P5.4: the offline floor is only proven by
        // running the work that has nowhere else to go — conflict detection,
        // which fails by saying nothing at all.
        .executableTarget(name: "MLXCheck",
                          dependencies: ["MLXRuntime", "ExecutorContract", "LLMProviders",
                                         "CoreEngine", "Config"]),

        // P15.5 — what Tier 1 can take with several streams open, measured
        // through `ModelRouter` rather than through curl, because the number it
        // produces is the span of control P16 builds an organisation on. An
        // executable for the same reason as MLXCheck: it needs hardware
        // `swift test` does not have, and it takes minutes.
        // CoreEngine and Knowledge are here for P18.1: the conflict criteria
        // are only worth anything if the model this app runs on actually
        // applies them, and that cannot be checked with a scripted answer.
        // M18 — the screen driver (§23, P17). Its own target because it links
        // ApplicationServices and CoreGraphics, and nothing that merely runs a
        // tool should have to.
        .target(name: "ScreenDriver", dependencies: ["AgentKit", "Observability"]),

        .executableTarget(name: "TierOneCheck",
                          dependencies: ["LLMProviders", "AgentKit", "CoreEngine", "Knowledge"]),

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
                           "Knowledge", "EmbeddingRuntime", "MLXRuntime", "Analysis",
                           // §1.4.1 / P13.1 — the app owns the headless web view,
                           // because WebKit is main-actor bound and one browser
                           // per app is the whole point.
                           "Channels", "DocGen", "Roster", "MCPBridge", "ProjectKit",
                           "WebSearch", "Instruments", "FieldServer", "OLTP", "Linkage"],
            // §14.3 — what makes an App Intent findable rather than merely
            // written. Shortcuts and Siri read `Metadata.appintents` from the
            // bundle, and that bundle is produced by `appintentsmetadataprocessor`
            // from constant values the *compiler* has to be asked to emit.
            // Xcode passes these flags for you; SwiftPM does not, so an intent
            // built here without them compiles, links, runs from a test, and is
            // invisible to Siri — the same shape of failure as D6.
            // `scripts/build-app.sh` runs the processor over what these emit.
            swiftSettings: [
                .unsafeFlags(["-emit-const-values",
                              "-Xfrontend", "-const-gather-protocols-file",
                              "-Xfrontend", "Resources/AppIntentsProtocols.json"]),
            ]
        ),

        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "ConfigTests", dependencies: ["Config"]),
        .testTarget(name: "ObservabilityTests", dependencies: ["Observability"]),
        .testTarget(name: "SidecarTests", dependencies: ["Sidecar"]),
        .testTarget(name: "PersistenceTests",
                    dependencies: ["Persistence", "Sidecar", "Config", "Knowledge", "Instruments"]),
        .testTarget(name: "LLMProvidersTests",
                    dependencies: ["LLMProviders", "ExecutorContract"]),
        // Everything about Tier 0.5 that does not need the weights. The rest
        // is MLXCheck.
        .testTarget(name: "MLXRuntimeTests", dependencies: ["MLXRuntime", "LLMProviders"]),
        .testTarget(name: "CoreEngineTests", dependencies: ["CoreEngine", "Knowledge"]),
        .testTarget(name: "KnowledgeTests", dependencies: ["Knowledge"]),
        .testTarget(name: "WebSearchTests", dependencies: ["WebSearch", "Knowledge"]),
        .testTarget(name: "InstrumentsTests", dependencies: ["Instruments", "StatKit"]),
        .testTarget(name: "StatKitTests", dependencies: ["StatKit"]),
        .testTarget(name: "ScreenDriverTests", dependencies: ["ScreenDriver", "AgentKit"]),
        .testTarget(name: "OLTPTests", dependencies: ["OLTP"]),
        .testTarget(name: "LinkageTests", dependencies: ["Linkage"]),
        .testTarget(name: "FieldServerTests", dependencies: ["FieldServer", "Instruments", "OLTP"]),
        .testTarget(name: "EmbeddingRuntimeTests", dependencies: ["EmbeddingRuntime"]),
        .testTarget(name: "ExecutionTests", dependencies: ["Execution", "Config"]),
        .testTarget(name: "RBridgeTests", dependencies: ["RBridge"]),
        .testTarget(name: "AnalysisTests", dependencies: ["Analysis", "OLTP", "DocGen"]),
        .testTarget(name: "ChannelsTests", dependencies: ["Channels"]),
        // CoreEngine is here for the reason P8.3 exists: the Done-when is that
        // an MCP tool reaches a real session's tool list, and the gateway is
        // where that is either true or not (v1 bug D6).
        // Roster is here for P8.4: a plugin is a packaged MCP server, and
        // "installed, therefore usable" is a claim only these two together can
        // check — Roster may not import MCPBridge (it must not be able to
        // reach an AgentTool), so the join lives in the test.
        .testTarget(name: "MCPBridgeTests",
                    dependencies: ["MCPBridge", "CoreEngine", "Roster"]),
        .testTarget(name: "DocGenTests", dependencies: ["DocGen", "Knowledge"]),
        // CoreEngine is here so the role→tool table in Roster is checked
        // against the specialists it mirrors, rather than trusted.
        .testTarget(name: "RosterTests", dependencies: ["Roster", "CoreEngine", "ToolBelt", "ProjectKit"]),
        .testTarget(name: "ProjectKitTests", dependencies: ["ProjectKit"]),
        // Also hosts the end-to-end walking-skeleton test, which needs a real
        // database and a real sidecar alongside the tools and the gate.
        .testTarget(name: "ToolBeltTests",
                    dependencies: ["ToolBelt", "CoreEngine", "Persistence", "Sidecar", "Config",
                                   "Knowledge", "WebSearch", "Roster", "Analysis", "DocGen",
                                   "RBridge"]),
        // P9.3's Done-when is a property of the whole app, not of one module:
        // *no* store writes a secret to disk. It therefore needs a target that
        // can reach every store that has one — which is exactly why the check
        // did not exist before.
        .testTarget(name: "SecretsAuditTests",
                    dependencies: ["AgentKit", "Config", "Channels", "Analysis", "MCPBridge"]),
    ]
)
