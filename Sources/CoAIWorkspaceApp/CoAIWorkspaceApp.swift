import SwiftUI
import AppKit
import Config
import Sidecar
import Knowledge
import Instruments
import Persistence

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
    /// Which of the four areas is open (§19.2). The old flat `Screen` list is
    /// still what draws each surface — see `screenView` — but nobody navigates by
    /// it any more.
    @State private var area = Area.chat
    /// What the Workbench's tab bar last selected. Read through `workbenchTab`,
    /// never directly: which tabs exist depends on the scope, and this can name
    /// one the current scope does not have.
    @State private var workbenchTabSelection = SubTab.console
    @State private var knowledgeTab = SubTab.documents
    @State private var systemTab = SubTab.status
    /// The team rail beside Chat (§19.2.6). Off by default: most turns are a
    /// question, and a monitor beside a question is noise.
    @State private var showingRail = false
    @State private var screen = Screen.chat
    /// Owned here rather than built inside the view: a model recreated on each
    /// body pass loses whatever the user just did to it (P1.10's bug).
    @State private var knowledge = KnowledgeViewModel()
    @State private var conflicts = ConflictViewModel()
    @State private var team = TeamViewModel()
    @State private var models = ModelsViewModel()
    @State private var endpoints = EndpointsViewModel()
    @State private var analysis = AnalysisViewModel()
    @State private var instruments = InstrumentsViewModel()
    @State private var coding = CodingViewModel()
    /// Which workspace everything else is looking at (§19.1). Held at the root
    /// because it is not one screen's state: chat, knowledge and the ledger all
    /// read the same selection, which is what replaced the hardcoded
    /// `ProjectID("default")`.
    @State private var projects = ProjectsViewModel()

    /// §19.2's four areas, plus the system. Each one is a different question:
    /// what to ask for · what was agreed · what to do with the data · what is
    /// true. The fifth is not a question, which is why it is outside the four.
    enum Area: String, CaseIterable, Identifiable {
        case chat, plan, workbench, knowledge, system
        var id: String { rawValue }

        var label: String {
            switch self {
            case .chat: "สนทนา"
            case .plan: "แผนงาน"
            case .workbench: "โต๊ะทำงาน"
            case .knowledge: "คลังความรู้"
            case .system: "ระบบ"
            }
        }

        var icon: String {
            switch self {
            case .chat: "bubble.left.and.bubble.right"
            case .plan: "square.stack.3d.up"
            case .workbench: "tablecells"
            case .knowledge: "books.vertical"
            case .system: "gearshape"
            }
        }

        /// ⌘1…⌘5, in the order they appear.
        static func shortcutDigit(for area: Area) -> Character {
            Character(String((allCases.firstIndex(of: area) ?? 0) + 1))
        }
    }

    /// Sub-tabs across every area. One enum rather than four so the shell can
    /// hold "which tab" without four parallel pieces of state that can disagree.
    enum SubTab: String, CaseIterable, Identifiable {
        // Workbench, in the order data travels (§19.2).
        case collect, coding, internalDB, externalDB, console, results
        // Knowledge.
        case documents, conflicts, sources
        // System.
        case models, budget, status, inventory

        var id: String { rawValue }

        var label: String {
            switch self {
            case .collect: "เก็บข้อมูล"
            case .coding: "ลงรหัส"
            case .internalDB: "ฐานข้อมูลภายใน"
            case .externalDB: "ฐานข้อมูลภายนอก"
            case .console: "สคริปต์ + คอนโซล"
            case .results: "ผลลัพธ์ + เอกสาร"
            case .documents: "เอกสาร"
            case .conflicts: "ข้อขัดแย้ง"
            case .sources: "แหล่งและ tier"
            case .models: "โมเดล"
            case .budget: "งบ + endpoint"
            case .status: "สถานะระบบ"
            case .inventory: "ผังหน้าจอ"
            }
        }
    }

    /// The surfaces themselves, unchanged from before the reorganisation. Not
    /// navigation any more — `screenView` maps one of these onto a pane inside an
    /// area, which is how §19.2 could be a re-layout rather than a rewrite.
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

    /// One old screen, drawn. Kept as a function rather than folded into the
    /// area shell below so the reorganisation moved *where* a screen appears and
    /// nothing about what it contains — which is the only version of this change
    /// that R13 permits (§19.2, P10.12).
    @ViewBuilder
    private func screenView(_ screen: Screen, engine: Engine,
                            analysisPane: AnalysisView.Pane? = nil,
                            explorerFocus: AnalysisView.ExplorerFocus = .both) -> some View {
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
                                 area = .plan
                             })
                        // Identity by scope: switching workspace has to build a
                        // new view model, or the conversation list stays the one
                        // from the project you just left.
                        .id(projects.scope.storageKey)
                case .projects:
                    ProjectsView(model: projects,
                                 types: engine.projectTypes,
                                 announce: { message in
                                     await engine.channelRouter.broadcast(message)
                                 })
                        .task {
                            await projects.attach(service: engine.projects)
                            // §19.10 — where each tolerance reading comes from.
                            await projects.attach(spans: engine.spans,
                                                  spend: engine.spendLedger,
                                                  ledger: engine.taskLedger,
                                                  paths: engine.paths)
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
                    AnalysisView(model: analysis, chosen: analysisPane,
                                 explorerFocus: explorerFocus)
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
    }

    var body: some View {
        Group {
            if let engine = environment.engine {
                areaContent(engine)
                    // Which projects exist is the shell's own question, not the
                    // Plan screen's: the switcher in the header, the Workbench's
                    // tab list and the status strip all read it. Attaching only
                    // inside Plan meant the header menu offered nothing but
                    // General until you had opened Plan once — which is exactly
                    // the detour moving that switch to the header was for (§19.1).
                    .task {
                        await projects.attach(service: engine.projects)
                    }
            } else {
                BootStatusView(environment: environment)
            }
        }
        .toolbar {
            // Navigation goes in the middle slot rather than competing with the
            // screen's own actions on the trailing edge, which is what pushed
            // them into the overflow chevron.
            ToolbarItem(placement: .principal) {
              if environment.engine != nil {
                // §19.2 — four areas and the system, not fourteen screens laid
                // out flat. The order is the order of the four questions: what
                // to ask for, what was agreed, what to do with the data, what is
                // true.
                // Text, not `Label`: driving this found the segmented picker
                // rendering five bare icons at 1500pt, and §19.2's whole claim is
                // that the four areas are four different *questions* — an icon
                // does not say which one. The icon stays on the ⌘-shortcut
                // legend and in the inventory, where there is room for both.
                Picker("พื้นที่", selection: $area) {
                    ForEach(Area.allCases) { area in
                        Text(area.label).tag(area)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("สลับพื้นที่ทำงาน")
              }
            }

            ToolbarItemGroup(placement: .automatic) {
              if environment.engine != nil {
                // The workspace switch at the head of the app (§19.1). It used
                // to live only in the Plan area's sidebar, which meant leaving
                // whatever you were doing to change which project you were doing
                // it in.
                Menu {
                    Button("General — คุยทั่วไป") {
                        Task { await projects.select(.general) }
                    }
                    Divider()
                    ForEach(projects.openProjects) { project in
                        Button("\(project.name) · ขั้น\(project.stage.label)") {
                            Task { await projects.select(.project(project.id)) }
                        }
                    }
                } label: {
                    // The name, visible. Same finding as the picker: a menu
                    // whose label collapses to an icon cannot answer "which
                    // project am I in", which is the one thing moving this
                    // switch to the header was for.
                    Text(projects.selected?.name ?? "General")
                }
                .accessibilityLabel("สลับพื้นที่ทำงานระหว่าง General กับโปรเจกต์ — ตอนนี้อยู่ "
                                    + (projects.selected?.name ?? "General"))

                if area == .chat {
                    Toggle(isOn: $showingRail) {
                        Label("เฝ้าดูทีม", systemImage: "sidebar.trailing")
                    }
                    .accessibilityLabel("เปิดหรือปิดแถบเฝ้าดูทีมด้านขวา")
                }
              }
            }
        }
        // §14.4 / P8.7 — a segmented picker in a toolbar is reachable from the
        // keyboard only if the person has turned Full Keyboard Access on, and
        // "you can get there by changing a system setting" is not the same as
        // "you can get there". ⌘1…⌘5 is: it works for everybody, including the
        // people who use it because it is faster.
        .background {
            // ⌘0 still goes to the system status, without spending a toolbar slot
            // on it: with six items the toolbar overflowed into a `»` chevron and
            // hid the team rail toggle behind it, which is the same
            // unreachability this project keeps paying for.
            Button("") { area = .system; systemTab = .status }
                .keyboardShortcut("0", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)

            ForEach(Area.allCases) { target in
                // Typed step by step: as a single expression with string
                // interpolation inside a `ForEach` over an enumerated
                // sequence, the type checker gave up on this line.
                let digit: Character = Area.shortcutDigit(for: target)
                Button("") { area = target }
                    .keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - the four areas (§19.2)

    /// The area, its sub-tabs, and the status strip under all of it (§19.2.3):
    /// the facts that decide what to do next were always one screen away from
    /// whatever was being worked on. Nothing is drawn for General — there is no
    /// stage, no frame and no baseline to report.
    @ViewBuilder
    private func areaContent(_ engine: Engine) -> some View {
        VStack(spacing: 0) {
            // Sub-tabs belong to the area, not to the screen inside it: one
            // picker per level, so "where am I" has one answer (§19.2.6).
            if let tabs = subTabs, tabs.count > 1 {
                Picker("ส่วนของพื้นที่", selection: subTabSelection) {
                    ForEach(tabs) { tab in Text(tab.label).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12).padding(.top, 8)
                .accessibilityLabel("เลือกส่วนของ\(area.label)")
            }

            // `maxWidth/maxHeight: .infinity` because a `VStack` lets its
            // children take their ideal size: driving this found the notebook
            // sitting in the middle of the window with 450pt of dead white to
            // its left, which reads as a broken screen rather than a centred one.
            Group {
                switch area {
                case .chat: chatArea(engine)
                case .plan: planArea(engine)
                case .workbench: workbenchArea(engine)
                case .knowledge: knowledgeArea(engine)
                case .system: systemArea(engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // A row rather than a `safeAreaInset`: as an inset it drew *over* the
            // bottom of the split views under it — the "สร้างโปรเจกต์" form and
            // the notebook list were both half-hidden behind it. A strip that
            // covers the control under it is worse than no strip.
            if projects.selected != nil {
                StatusBarView(model: projects, openPlan: { area = .plan })
            }
        }
    }

    /// Chat is three columns (§19.2.6): history on the left — inside `ChatView`
    /// since P10.14 — the conversation in the middle, and the team on the right
    /// when it is wanted. The rail is off by default because most turns are a
    /// question, and a monitor beside a question is noise.
    @ViewBuilder
    private func chatArea(_ engine: Engine) -> some View {
        if showingRail {
            HSplitView {
                screenView(.chat, engine: engine)
                    .frame(minWidth: 480)
                screenView(.team, engine: engine)
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
            }
        } else {
            screenView(.chat, engine: engine)
        }
    }

    @ViewBuilder
    private func planArea(_ engine: Engine) -> some View {
        screenView(.projects, engine: engine)
    }

    /// The data path, in order: collected → stored (inside, outside) → worked on
    /// → presented. General is missing the first two on purpose (§19.2): there is
    /// no ethics and no scope to collect under, and no project database to be the
    /// inside of.
    @ViewBuilder
    private func workbenchArea(_ engine: Engine) -> some View {
        switch workbenchTab {
        case .collect:
            // Both halves of the data path's first step: M15 designs the
            // instrument and gets it past its gate (P11.2/P11.4), and M16 opens
            // it to the local network once it has (P11.5). Two modules, one tab,
            // because to the person doing it that is one piece of work.
            InstrumentsView(model: instruments)
                .id(projects.scope.storageKey)
                .task {
                    // The project's own analytical store, so answers can be
                    // pulled across into it (§19.17). Passed in rather than
                    // opened here: one project, one `.duckdb`, and the place
                    // that knows which is `WorkspaceStores`.
                    let stores = await engine.stores(for: projects.scope)
                    await instruments.attach(store: InstrumentStore(client: engine.client),
                                             scope: projects.scope,
                                             paths: engine.paths,
                                             analysis: stores.analysis,
                                             spans: engine.spans)
                }
        case .coding:
            // The qualitative half of M15 (§20.3, P11.8). Its own tab rather
            // than a box inside "เก็บข้อมูล" because it is the other order of
            // work: there the instrument is designed before anybody answers,
            // here the text exists and the categories are built out of it.
            CodingView(model: coding)
                .id(projects.scope.storageKey)
                .task {
                    await coding.attach(store: CodebookStore(client: engine.client),
                                        scope: projects.scope,
                                        spans: engine.spans)
                }
        case .internalDB:
            screenView(.analysis, engine: engine,
                       analysisPane: .explorer, explorerFocus: .internalStore)
        case .externalDB:
            screenView(.analysis, engine: engine,
                       analysisPane: .explorer, explorerFocus: .external)
        case .console:
            screenView(.analysis, engine: engine, analysisPane: .notebook)
        case .results:
            screenView(.analysis, engine: engine, analysisPane: .plan)
        default:
            // Reachable only if a tab from another area were assigned here, which
            // `subTabs` never does. Showing the console beats an empty pane.
            screenView(.analysis, engine: engine, analysisPane: .notebook)
        }
    }

    @ViewBuilder
    private func knowledgeArea(_ engine: Engine) -> some View {
        switch knowledgeTab {
        case .conflicts: screenView(.conflicts, engine: engine)
        case .sources: SourcesView(registry: SourceRegistry(),
                                   search: engine.webSource, read: engine.pageReader)
        default: screenView(.knowledge, engine: engine)
        }
    }

    @ViewBuilder
    private func systemArea(_ engine: Engine) -> some View {
        switch systemTab {
        case .models: screenView(.models, engine: engine)
        case .budget: screenView(.endpoints, engine: engine)
        // R13's checklist, in the app: where each of §14.2's screens went, and
        // which of them are honestly not built yet.
        case .inventory: IAInventoryView()
        default: BootStatusView(environment: environment)
        }
    }

    // MARK: - sub-tab plumbing

    private var subTabs: [SubTab]? {
        switch area {
        case .chat, .plan: nil
        case .workbench: workbenchTabs
        case .knowledge: [.documents, .conflicts, .sources]
        case .system: [.models, .budget, .status, .inventory]
        }
    }

    /// General has no "เก็บข้อมูล" and no project database (§19.2).
    private var workbenchTabs: [SubTab] {
        projects.selected == nil
            ? [.externalDB, .console, .results]
            : [.collect, .coding, .internalDB, .externalDB, .console, .results]
    }

    /// The Workbench tab actually shown.
    ///
    /// Leaving a project for General while standing on "เก็บข้อมูล" used to keep
    /// the project's questionnaire on screen — consent text, ethics number and
    /// expert ratings and all — under a header that said General, with no tab in
    /// the bar selected to say where you were. A selection that outlives the thing
    /// it selects is the same defect as a `Scope.project` pointing at nothing
    /// (§19.1), so it is resolved on read rather than trusted.
    private var workbenchTab: SubTab {
        let available = workbenchTabs
        return available.contains(workbenchTabSelection)
            ? workbenchTabSelection
            : (available.first ?? .console)
    }

    private var subTabSelection: Binding<SubTab> {
        switch area {
        case .workbench:
            Binding(get: { workbenchTab }, set: { workbenchTabSelection = $0 })
        case .knowledge:
            Binding(get: { knowledgeTab }, set: { knowledgeTab = $0 })
        default:
            Binding(get: { systemTab }, set: { systemTab = $0 })
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
