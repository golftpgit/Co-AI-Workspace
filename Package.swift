// swift-tools-version: 6.2
import PackageDescription

// Co-AI Workspace — module layout follows ARCHITECTURE.md §3 / §4.
// Targets are added phase by phase (see IMPLEMENTATION_PLAN.md); P0 lands the
// foundation ones only: AgentKit (types), Config, Observability, Sidecar, App.
let package = Package(
    name: "CoAIWorkspace",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "CoAIWorkspace", targets: ["CoAIWorkspaceApp"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
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
        .target(name: "Persistence", dependencies: ["AgentKit", "Observability"]),

        // M5 — every model behind one interface, plus the router that decides
        // which tier serves a request (ARCHITECTURE §9).
        .target(name: "LLMProviders", dependencies: ["AgentKit", "Observability"]),

        // M9 — every process the system runs: sandbox profile, process group
        // signals, registry (ARCHITECTURE §13). Knows nothing about agents.
        .target(name: "Execution", dependencies: ["AgentKit", "Observability", "Config"]),

        // M6 — the tools themselves. Depends on Execution, never the reverse,
        // and CoreEngine never depends on this: tools plug in via AgentTool.
        .target(name: "ToolBelt", dependencies: ["AgentKit", "Observability", "Execution"]),

        // M1 — hook chain, approval broker, tool gateway, agent loop. Every
        // decision the system makes lives here (ARCHITECTURE §5).
        .target(name: "CoreEngine",
                dependencies: ["AgentKit", "Observability", "LLMProviders", "Persistence"]),

        // M13 — SwiftUI shell.
        .executableTarget(
            name: "CoAIWorkspaceApp",
            dependencies: ["AgentKit", "Config", "Observability", "Sidecar", "Persistence",
                           "LLMProviders", "CoreEngine", "Execution", "ToolBelt"]
        ),

        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "ConfigTests", dependencies: ["Config"]),
        .testTarget(name: "ObservabilityTests", dependencies: ["Observability"]),
        .testTarget(name: "SidecarTests", dependencies: ["Sidecar"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Sidecar", "Config"]),
        .testTarget(name: "LLMProvidersTests", dependencies: ["LLMProviders"]),
        .testTarget(name: "CoreEngineTests", dependencies: ["CoreEngine"]),
        .testTarget(name: "ExecutionTests", dependencies: ["Execution", "Config"]),
        // Also hosts the end-to-end walking-skeleton test, which needs a real
        // database and a real sidecar alongside the tools and the gate.
        .testTarget(name: "ToolBeltTests",
                    dependencies: ["ToolBelt", "CoreEngine", "Persistence", "Sidecar", "Config"]),
    ]
)
