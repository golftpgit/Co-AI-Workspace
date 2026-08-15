import SwiftUI
import AppKit
import Config
import Sidecar
import Knowledge
import Instruments
import Persistence
import AgentKit
import CoreEngine
import ProjectKit

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
    /// Which area each open tab was last on (§19.1.1, P21.1).
    ///
    /// This is what makes a tab remember where you were. Held here rather than
    /// in `OpenWorkspaces`, which is a domain type in ProjectKit and has no
    /// business knowing the app's screen areas — and held by tab *id* rather
    /// than by `Tab`, so a closed and reopened project starts fresh rather than
    /// resuming a place from before it was closed.
    @State private var areaByTab: [String: Area] = [:]
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
    /// Which half of "สคริปต์ + คอนโซล" is showing. The notebook runs the
    /// commands and the file list is where their output lands (§14.2, P8.6),
    /// so they belong in one tab with a switch rather than two tabs apart.
    @State private var consolePane = ConsolePane.notebook
    @State private var workflows = WorkflowViewModel()
    /// Owned here rather than built inside the view: a model recreated on each
    /// body pass loses whatever the user just did to it (P1.10's bug).
    @State private var knowledge = KnowledgeViewModel()
    @State private var conflicts = ConflictViewModel()
    @State private var team = TeamViewModel()
    @State private var models = ModelsViewModel()
    @State private var endpoints = EndpointsViewModel()
    @State private var analysis = AnalysisViewModel()
    /// P11.9 — assembling the five-chapter manuscript. Its own model rather
    /// than more fields on `AnalysisViewModel`, which is already the largest
    /// on the project.
    @State private var manuscripts = ManuscriptViewModel()
    @State private var channels = ChannelsViewModel()
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
        case documents, graph, conflicts, sources
        // System.
        case models, budget, channels, status, inventory

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
            case .graph: "กราฟ"
            case .conflicts: "ข้อขัดแย้ง"
            case .sources: "แหล่งและ tier"
            case .models: "โมเดล"
            case .budget: "งบ + endpoint"
            case .channels: "ช่องทาง"
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
                    KnowledgeBaseView(model: knowledge)
                        .task {
                            await knowledge.attach(store: engine.knowledge)
                            knowledge.attach(policySource: engine.policySource)
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
                        // Rebuilt on a workspace switch, like Chat and Analysis:
                        // the ledger, the open leaves and the lead's own scope
                        // all belong to one project, and a screen that kept the
                        // last one's rows would be offering to rework somebody
                        // else's work.
                        .id(projects.scope.storageKey)
                        .task { await team.attach(team: engine.team,
                                                  ledger: engine.taskLedger,
                                                  gateway: engine.gateway,
                                                  projects: engine.projects,
                                                  scope: projects.scope) }
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
                                                  library: stores.notebooks,
                                                  cellRuns: CellRunStore(client: engine.client))
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
                    // Remembering where each tab was, and restoring it on the
                    // way back. Switching to the project you were planning and
                    // landing on Chat is the small daily cost of treating a
                    // workspace as a mode rather than a place.
                    .onChange(of: area) { _, now in
                        areaByTab[projects.workspaces.active.id] = now
                    }
                    .onChange(of: projects.workspaces.active) { _, now in
                        area = areaByTab[now.id] ?? .chat
                    }
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
                        Task { await projects.focus(.general) }
                    }
                    Divider()
                    // Opens a tab rather than replacing where you are (P21.1).
                    // Archived projects are listed too: reading one is normal,
                    // and leaving them out would make "closed" mean "gone".
                    ForEach(projects.projects) { project in
                        ProjectMenuButton(project: project, projects: projects)
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
            // Above the area's own sub-tabs, and above every area, because a
            // workspace is not one area's state — chat, the plan and the ledger
            // all read it (§19.1.1, P21.1). Hidden while only General is open,
            // so somebody who never opens a project never sees a tab bar with
            // one tab in it.
            if projects.workspaces.entries.count > 1 {
                WorkspaceTabBar(projects: projects)
                Divider()
            }

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

    /// The two halves of the console tab (§14.2, P8.6).
    enum ConsolePane: String, CaseIterable, Identifiable {
        case notebook, files, workflows
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notebook: "สมุดงาน"
            case .files: "ไฟล์"
            case .workflows: "ลำดับงาน"
            }
        }
    }

    /// Which folder the file viewer shows. A project sees its own folder; in
    /// General there is no project folder, so it sees the app-wide documents
    /// directory — the place DocGen writes when nothing is selected.
    /// Saved procedures live beside the workspace's other list files.
    private func workflowFile(_ engine: Engine) -> URL {
        if case .project(let id) = projects.scope {
            return engine.paths.project(id).root.appending(path: "workflows.json")
        }
        return engine.paths.root.appending(path: "workflows.json")
    }

    private func filesRoot(_ engine: Engine) -> URL {
        if case .project(let id) = projects.scope {
            return engine.paths.project(id).root
        }
        return engine.paths.documentsDirectory
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
            CodingView(model: coding, ingest: { transcript in
                // The knowledge screen's own model does the work, so the index,
                // the dedup and the conflict review are the ones the library
                // already uses — a second path into the knowledge base would be
                // a second set of rules about what is in it.
                await knowledge.attach(store: engine.knowledge)
                knowledge.scope = projects.scope
                await knowledge.ingest(transcript: transcript)
                coding.report(knowledge.status.map {
                    CodingViewModel.Status(message: $0.message, isError: $0.isError)
                })
            })
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
            VStack(spacing: 0) {
                Picker("มุมมอง", selection: $consolePane) {
                    ForEach(ConsolePane.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                .padding(.vertical, 8)

                Divider()

                switch consolePane {
                case .notebook:
                    screenView(.analysis, engine: engine, analysisPane: .notebook)
                case .workflows:
                    // The palette is whatever the gateway can reach, so this
                    // screen needs the live gateway rather than a tool list
                    // captured at boot (§10, P8.5).
                    WorkflowView(model: workflows)
                        .id(projects.scope.storageKey)
                        .task {
                            await workflows.attach(
                                store: WorkflowStore(file: workflowFile(engine)),
                                gateway: engine.gateway,
                                context: ToolContext(scope: projects.scope))
                        }
                case .files:
                    // The workspace's own folder, inside the container, so a
                    // sandboxed app reaches it without anybody granting
                    // anything. In a project that is the whole project folder —
                    // `files/` is where `run_shell` writes and `documents/` is
                    // where DocGen does, and both are things people come here
                    // looking for.
                    FilesView(root: filesRoot(engine))
                        .id(projects.scope.storageKey)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            // Two things live here: the pre-registered method (§12.4) and the
            // manuscript it eventually becomes (§20.8). One picker, because
            // they are two stages of the same document rather than two screens.
            ResultsPane(analysis: analysis, manuscripts: manuscripts, engine: engine,
                        scope: projects.scope,
                        analysisView: { screenView(.analysis, engine: engine,
                                                   analysisPane: .plan) })
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
        // §11.4 / P2.7 — the relations have been extracted and stored since
        // P2.7 and, until now, read by no view at all.
        case .graph:
            EntityGraphView(model: knowledge)
                .id(projects.scope.storageKey)
                .task {
                    await knowledge.attach(store: engine.knowledge)
                    await knowledge.attach(relations: engine.relations,
                                           extractor: engine.relationExtractor)
                    // Without this the scope picker's "โปรเจกต์" option has no
                    // project to mean, exactly as on the documents tab.
                    knowledge.currentProject = projects.selected?.id
                }
        default: screenView(.knowledge, engine: engine)
        }
    }

    @ViewBuilder
    private func systemArea(_ engine: Engine) -> some View {
        switch systemTab {
        case .models: screenView(.models, engine: engine)
        case .budget: screenView(.endpoints, engine: engine)
        // §8.2 / §15's "Channels" settings category. Its own sub-tab because
        // until now the store existed and no screen read it, so a bot could
        // only be configured by editing JSON beside the database.
        case .channels:
            ChannelsView(model: channels)
                .task { channels.attach(store: engine.channelAccounts) }
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
        case .knowledge: [.documents, .graph, .conflicts, .sources]
        case .system: [.models, .budget, .channels, .status, .inventory]
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

// ─────────────────────────────────────────────────────────────
// Opening a workspace (§19.1.1, P21.1)

/// One row of the "open a project" menu.
///
/// Its own view because the menu is inside a `ToolbarItemGroup` builder, where
/// the type-checker gave up on the whole expression once the row grew a second
/// condition. Splitting it is not a style choice — it is the difference between
/// the app compiling and not.
private struct ProjectMenuButton: View {
    let project: Project
    let projects: ProjectsViewModel

    var body: some View {
        Button(label) { Task { await projects.open(project) } }
    }

    /// An archive says so in the menu, before it is opened — otherwise the only
    /// signal is that everything turns out to be disabled once you are in it.
    private var label: String {
        project.isOpen
            ? "\(project.name) · ขั้น\(project.stage.label)"
            : "\(project.name) · ปิดแล้ว (อ่านอย่างเดียว)"
    }
}

/// The strip of open workspaces (§19.1.1, P21.1).
///
/// The thing that makes a project a tab rather than a mode: the ones you are
/// not looking at are still there, named, one click away. Before this the app
/// held a single selection, so opening the second project cost you the first.
struct WorkspaceTabBar: View {
    let projects: ProjectsViewModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(projects.workspaces.entries) { entry in
                    tab(entry)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func tab(_ entry: OpenWorkspaces.Entry) -> some View {
        let isActive = entry.tab == projects.workspaces.active
        return HStack(spacing: 4) {
            Button {
                Task { await projects.focus(entry.tab) }
            } label: {
                HStack(spacing: 4) {
                    if entry.isArchived {
                        // An archive is readable and not writable, and the tab
                        // is where that has to be visible — a person who cannot
                        // see it will read a refused edit as a bug.
                        //
                        // Hidden from the accessibility tree because it is
                        // decoration for something the spoken label already
                        // says in words; announcing "lock" as well is noise.
                        Image(systemName: "lock").font(.caption2)
                            .accessibilityHidden(true)
                    }
                    Text(entry.title).font(.caption).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .fontWeight(isActive ? .semibold : .regular)
            .accessibilityLabel(spoken(entry, isActive: isActive))

            // General has no close button because it cannot be closed: it is
            // where work that is not a promise happens, and there is nowhere
            // else to fall back to.
            if entry.tab != .general {
                Button {
                    Task { await projects.closeTab(entry.tab) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("ปิดแท็บ \(entry.title) — ปิดแค่หน้าต่าง ไม่ใช่ปิดโครงการ")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .contain)
    }

    private func spoken(_ entry: OpenWorkspaces.Entry, isActive: Bool) -> String {
        var parts = ["แท็บ \(entry.title)"]
        if entry.isArchived { parts.append("ปิดแล้ว อ่านอย่างเดียว") }
        parts.append(isActive ? "กำลังดูอยู่" : "กดเพื่อสลับมา")
        return parts.joined(separator: " · ")
    }
}
