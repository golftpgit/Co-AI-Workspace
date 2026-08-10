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

        // M13 — SwiftUI shell.
        .executableTarget(
            name: "CoAIWorkspaceApp",
            dependencies: ["AgentKit", "Config", "Observability", "Sidecar", "Persistence"]
        ),

        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "ConfigTests", dependencies: ["Config"]),
        .testTarget(name: "ObservabilityTests", dependencies: ["Observability"]),
        .testTarget(name: "SidecarTests", dependencies: ["Sidecar"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Sidecar", "Config"]),
    ]
)
