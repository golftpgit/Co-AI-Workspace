import SwiftUI
import AppKit
import Config
import Sidecar

@main
struct CoAIWorkspaceApp: App {
    @State private var environment = AppEnvironment()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Co-AI Workspace") {
            RootView(environment: environment)
                .frame(minWidth: 860, minHeight: 520)
                .task {
                    appDelegate.environment = environment
                    await environment.boot()
                }
        }
        .defaultSize(width: 1_040, height: 700)
        .windowResizability(.contentMinSize)
    }
}

/// Chat once the engine is up, boot status until then. Startup failures stay
/// visible instead of leaving an empty window with no explanation (v1 bug B4).
private struct RootView: View {
    let environment: AppEnvironment
    @State private var showingStatus = false
    @State private var screen = Screen.chat
    /// Owned here rather than built inside the view: a model recreated on each
    /// body pass loses whatever the user just did to it (P1.10's bug).
    @State private var knowledge = KnowledgeViewModel()
    @State private var conflicts = ConflictViewModel()
    @State private var team = TeamViewModel()
    @State private var models = ModelsViewModel()
    @State private var endpoints = EndpointsViewModel()
    @State private var analysis = AnalysisViewModel()
    /// Which workspace everything else is looking at (§19.1). Held at the root
    /// because it is not one screen's state: chat, knowledge and the ledger all
    /// read the same selection, which is what replaced the hardcoded
    /// `ProjectID("default")`.
    @State private var projects = ProjectsViewModel()

    enum Screen: String, CaseIterable, Identifiable {
        case chat, projects, knowledge, conflicts, team, analysis, models, endpoints
        var id: String { rawValue }

        var label: String {
            switch self {
            case .chat: "สนทนา"
            case .projects: "โปรเจกต์"
            case .knowledge: "คลังความรู้"
            case .conflicts: "ข้อขัดแย้ง"
            case .team: "ทีม"
            case .analysis: "วิเคราะห์"
            case .models: "โมเดล"
            case .endpoints: "ระยะไกล"
            }
        }

        /// ⌘1…⌘8. A number rather than a mnemonic because the order on screen
        /// is the order in the toolbar, and that is what a person counts.
        static func shortcutDigit(for screen: Screen) -> Character {
            let index = (allCases.firstIndex(of: screen) ?? 0) + 1
            return Character(String(index))
        }

        var icon: String {
            switch self {
            case .chat: "bubble.left.and.bubble.right"
            case .projects: "square.stack.3d.up"
            case .knowledge: "books.vertical"
            case .conflicts: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
            case .team: "person.3"
            case .analysis: "tablecells"
            case .models: "cpu"
            case .endpoints: "network"
            }
        }
    }

    var body: some View {
        Group {
            if let engine = environment.engine, !showingStatus {
                switch screen {
                case .chat:
                    ChatView(engine: engine, scope: projects.scope,
                             promote: { draft, conversationID in
                                 await projects.promote(draft,
                                                        conversationID: conversationID,
                                                        conversations: engine.conversations)
                                 // Land on the project that was just made, so
                                 // the next thing on screen is its brief and
                                 // the G1 conditions still to fill in.
                                 screen = .projects
                             })
                        // Identity by scope: switching workspace has to build a
                        // new view model, or the conversation list stays the one
                        // from the project you just left.
                        .id(projects.scope.storageKey)
                case .projects:
                    ProjectsView(model: projects,
                                 announce: { message in
                                     await engine.channelRouter.broadcast(message)
                                 })
                        .task {
                            await projects.attach(service: engine.projects)
                            // §19.10 — where each tolerance reading comes from.
                            await projects.attach(spans: engine.spans,
                                                  spend: engine.spendLedger,
                                                  ledger: engine.taskLedger)
                        }
                case .knowledge:
                    KnowledgeView(model: knowledge)
                        .task {
                            await knowledge.attach(store: engine.knowledge)
                            await knowledge.attach(relations: engine.relations,
                                                   extractor: engine.relationExtractor)
                            knowledge.attach(conflicts: engine.conflicts,
                                             detector: engine.conflictDetector)
                            knowledge.currentProject = projects.selected?.id
                        }
                case .conflicts:
                    ConflictView(model: conflicts)
                        .task { await conflicts.attach(store: engine.conflicts) }
                case .team:
                    TeamView(model: team)
                        .task { await team.attach(team: engine.team,
                                                  ledger: engine.taskLedger,
                                                  gateway: engine.gateway) }
                case .analysis:
                    AnalysisView(model: analysis)
                        // Same identity trick as Chat: switching workspace has
                        // to rebuild the screen, or it keeps showing the tables
                        // of the project you just left (§19.1).
                        .id(projects.scope.storageKey)
                        .task {
                            // Per-project files: its own DuckDB, its own
                            // notebooks, its own connectors.
                            let stores = await engine.stores(for: projects.scope)
                            await analysis.attach(store: stores.analysis,
                                                  kernel: engine.notebookKernel,
                                                  library: stores.notebooks)
                            analysis.attach(connectors: stores.connectors)
                            await analysis.attach(plans: engine.plans,
                                                  detector: engine.gapDetector,
                                                  knowledge: engine.knowledge)
                            analysis.attach(templates: engine.templates)
                        }
                case .endpoints:
                    EndpointsView(model: endpoints)
                        .task {
                            await endpoints.attach(
                                registry: engine.endpoints,
                                checks: engine.endpointChecks,
                                limits: environment.config.budget ?? .conservative,
                                governor: engine.governor,
                                ledger: engine.spendLedger,
                                persist: { [environment] registry, limits in
                                    environment.rememberEndpoints(registry, limits: limits)
                                })
                        }
                case .models:
                    ModelsView(model: models)
                        .task {
                            await models.attach(
                                installer: engine.modelInstaller,
                                catalog: engine.modelCatalog,
                                tier: engine.localTier,
                                persist: { [environment] name in
                                    environment.rememberLocalModel(name)
                                })
                        }
                }
            } else {
                BootStatusView(environment: environment)
            }
        }
        .toolbar {
            if environment.engine != nil, !showingStatus {
                Picker("หน้าจอ", selection: $screen) {
                    ForEach(Screen.allCases) { screen in
                        Label(screen.label, systemImage: screen.icon).tag(screen)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("สลับหน้าจอ")
            }
            if environment.engine != nil {
                Toggle(isOn: $showingStatus) {
                    Label("สถานะระบบ", systemImage: "heart.text.square")
                }
                .accessibilityLabel("สลับไปดูสถานะระบบ")
                .keyboardShortcut("0", modifiers: .command)
            }
        }
        // §14.4 / P8.7 — a segmented picker in a toolbar is reachable from the
        // keyboard only if the person has turned Full Keyboard Access on, and
        // "you can get there by changing a system setting" is not the same as
        // "you can get there". ⌘1…⌘7 is: it works for everybody, including the
        // people who use it because it is faster.
        .background {
            ForEach(Screen.allCases) { target in
                // Typed step by step: as a single expression with string
                // interpolation inside a `ForEach` over an enumerated
                // sequence, the type checker gave up on this line.
                let digit: Character = Screen.shortcutDigit(for: target)
                Button("") { screen = target; showingStatus = false }
                    .keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Sidecars must be torn down on quit; SwiftUI alone gives no reliable hook.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var environment: AppEnvironment?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        Task { @MainActor in
            await environment.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
