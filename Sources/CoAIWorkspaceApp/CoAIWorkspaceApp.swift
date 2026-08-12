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

    enum Screen: String, CaseIterable, Identifiable {
        case chat, knowledge, conflicts, team, analysis, models, endpoints
        var id: String { rawValue }

        var label: String {
            switch self {
            case .chat: "สนทนา"
            case .knowledge: "คลังความรู้"
            case .conflicts: "ข้อขัดแย้ง"
            case .team: "ทีม"
            case .analysis: "วิเคราะห์"
            case .models: "โมเดล"
            case .endpoints: "ระยะไกล"
            }
        }

        var icon: String {
            switch self {
            case .chat: "bubble.left.and.bubble.right"
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
                case .chat: ChatView(engine: engine)
                case .knowledge:
                    KnowledgeView(model: knowledge)
                        .task {
                            await knowledge.attach(store: engine.knowledge)
                            await knowledge.attach(relations: engine.relations,
                                                   extractor: engine.relationExtractor)
                            knowledge.attach(conflicts: engine.conflicts,
                                             detector: engine.conflictDetector)
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
                        .task {
                            await analysis.attach(store: engine.analysis,
                                                  kernel: engine.notebookKernel,
                                                  library: engine.notebooks)
                            analysis.attach(connectors: engine.connectors)
                            await analysis.attach(plans: engine.plans,
                                                  detector: engine.gapDetector,
                                                  knowledge: engine.knowledge)
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
