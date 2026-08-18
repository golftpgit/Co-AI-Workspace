import SwiftUI
import AgentKit
import Config
import Sidecar

/// System status: config, paths, sidecar health and whether the engine came
/// up. Since P1.10 the app opens on Chat and this is what the toolbar toggle
/// shows — and what the user sees instead of an empty window when boot fails.
struct BootStatusView: View {
    let environment: AppEnvironment
    /// P8.4 — owned here rather than rebuilt on each body pass, for the reason
    /// every other view model on this project is owned by its screen.
    @State private var plugins = PluginsViewModel()
    @State private var mcpServers = MCPServersViewModel()
    @State private var rBridge: RBridgeViewModel?
    @ScaledMetric private var labelColumn: CGFloat = 150

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                phaseSection
                pathsSection
                configSection
                sidecarSection
                engineSection
                if let engine = environment.engine {
                    Divider()
                    // Servers named by command, above the packaged plugins:
                    // both end up as MCP tools, and until now only the second
                    // half had a screen.
                    MCPServersView(model: mcpServers)
                        .task { mcpServers.attach(store: engine.mcpServers) }
                    Divider()
                    // §12.7 — R is the one dependency the app cannot install
                    // and must not pretend to manage, so its section is a
                    // status and two instructions (P14.1).
                    if let rBridge {
                        RBridgeSection(model: rBridge)
                    }
                    Divider()
                    PluginsSection(model: plugins)
                        .task {
                            await plugins.attach(registry: engine.plugins,
                                                 mcp: engine.mcp,
                                                 gateway: engine.gateway)
                        }
                }
                if !environment.notes.isEmpty { notesSection }
            }
            .padding(Space.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(t("System start-up status", "Screen-reader label for the whole boot screen."))
        .task {
            // Built once the paths exist rather than at construction: the
            // bridge script goes beside the analysis store, and where that is
            // is a boot-time answer.
            if rBridge == nil, let paths = environment.paths {
                rBridge = RBridgeViewModel(directory: paths.analysisDirectory)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Co-AI Workspace").font(.largeTitle.bold())
            Text("Phase 1 — walking skeleton").foregroundStyle(.secondary)
        }
    }

    private var phaseSection: some View {
        HStack(spacing: 10) {
            switch environment.phase {
            case .launching:
                ProgressView().controlSize(.small)
                Text(localised: "Starting up…", "Boot phase: the app is still bringing services up.")
            case .ready:
                statusDot(.green)
                Text(localised: "Ready", "Boot phase: everything came up.").fontWeight(.medium)
            case .degraded(let reason):
                statusDot(.red)
                VStack(alignment: .leading) {
                    Text(localised: "Start-up did not finish", "Boot phase: something failed and the reason follows.").fontWeight(.medium)
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var pathsSection: some View {
        if let paths = environment.paths {
            section(t("Where data is kept", "Section heading on the boot screen.")) {
                labeled("Data directory", paths.root.path(percentEncoded: false))
                labeled("Bootstrap", paths.bootstrapFile.lastPathComponent)
                if !environment.createdDirectories.isEmpty {
                    labeled(t("Created this run", "Row label: directories that did not exist before this launch."),
                            environment.createdDirectories.joined(separator: ", "))
                }
            }
        }
    }

    private var configSection: some View {
        section("Bootstrap config") {
            labeled("Schema version", "\(environment.config.schemaVersion)")
            labeled("SurrealDB port", "\(environment.config.surrealPort)")
            labeled("SearXNG port", "\(environment.config.searxngPort)")
            labeled("Log level", environment.config.logLevel.rawValue)
            if let outcome = environment.bootstrapOutcome {
                labeled(t("Loaded by", "Row label: how the bootstrap file was obtained."), describe(outcome))
            }
        }
    }

    private var sidecarSection: some View {
        section("Sidecars") {
            if environment.sidecarStatuses.isEmpty {
                Text(localised: "No sidecar is registered", "Shown when the sidecar list is empty.").foregroundStyle(.secondary)
            } else {
                ForEach(environment.sidecarStatuses.sorted(by: { $0.key < $1.key }), id: \.key) { id, status in
                    HStack(spacing: 8) {
                        statusDot(color(for: status))
                        Text(id).fontWeight(.medium)
                        Text(describe(status, id: id)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("sidecar \(id): \(describe(status, id: id))")
                }
            }
        }
    }

    /// Which models answered a readiness probe at boot. Without this, "why
    /// can't it run commands" is invisible — tool calling needs a tier above
    /// on-device (ARCHITECTURE §9.1).
    private var engineSection: some View {
        section(t("Engine", "Section heading on the boot screen.")) {
            if let engine = environment.engine {
                labeled(t("Database", "Row label on the boot screen."),
                        t("connected", "Row value: the database answered."))
                ForEach(Array(engine.executorSummary.enumerated()), id: \.offset) { _, line in
                    labeled(t("Model", "Row label: one line per model tier that answered a probe."), line)
                }
                // §7: a manifest that did not load is worth saying out loud —
                // a silent one looks like an agent that stopped behaving.
                labeled(t("Roster (§7)", "Row label: the agent manifest."),
                        t("\(engine.roster.count) entries", "Row value. Placeholder is a count of roster entries.")
                            + (engine.rosterProblems.isEmpty ? ""
                               : t(" · \(engine.rosterProblems.count) files failed to load",
                                   "Appended when some roster files could not be read. Placeholder is a count of files.")))
                ForEach(Array(engine.rosterProblems.enumerated()), id: \.offset) { _, problem in
                    Text("• \(problem)")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // §6.2: and the same for MCP. A server that did not start is
                // a tool list that is quietly shorter than the one the agent
                // was written against — D6's failure, seen from the outside.
                labeled("MCP (§6.2)", mcpSummary(engine))
                ForEach(Array(engine.mcpProblems.enumerated()), id: \.offset) { _, problem in
                    Text("• \(problem)")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // P9.4: a list file that would not decode. The data was kept
                // and the app carried on — which is right, and was also the
                // whole of the previous behaviour: the only trace was a line
                // in the unified log, so what the person experienced was their
                // bot list being empty one morning with no reason given.
                let unreadable = FileStoreIncidents.shared.all
                if !unreadable.isEmpty {
                    labeled(t("Files that could not be read", "Row label for files whose contents would not decode."),
                            t("\(unreadable.count) files · the originals have been backed up",
                              "Row value. Placeholder is a count of files. Says the data was kept, not lost."))
                    ForEach(Array(unreadable.enumerated()), id: \.offset) { _, failure in
                        Text("• \(failure.summary)")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    statusDot(.orange)
                    Text(environment.engineError.map {
                        t("Not started yet — \($0)", "Engine failed to start. Placeholder is the reason.")
                    } ?? t("Starting…", "The engine is still coming up."))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var notesSection: some View {
        section(t("Notes", "Section heading on the boot screen.")) {
            ForEach(Array(environment.notes.enumerated()), id: \.offset) { _, note in
                Text("• \(note)").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - building blocks

    /// Counted in tools, not in servers: "2 servers" says nothing about
    /// whether the thing an agent needs is on the list.
    private func mcpSummary(_ engine: Engine) -> String {
        guard !engine.mcpConnected.isEmpty || !engine.mcpProblems.isEmpty else {
            return t("no server is configured", "MCP summary when nothing has been set up.")
        }
        let tools = engine.mcpConnected.reduce(0) { $0 + $1.toolNames.count }
        let servers = t("\(engine.mcpConnected.count) servers · \(tools) tools",
                        "MCP summary. Placeholders: a count of servers and a count of tools. Counted in tools because that is what an agent needs.")
        return engine.mcpProblems.isEmpty ? servers
            : servers + t(" · \(engine.mcpProblems.count) could not connect",
                          "Appended to the MCP summary. Placeholder is a count of servers that failed.")
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // `@ScaledMetric`, not a constant: a label column fixed at 150pt
            // clips its own text at the larger Dynamic Type sizes, which is
            // exactly the setting the people who need it are using.
            Text(label).foregroundStyle(.secondary)
                .frame(width: labelColumn, alignment: .leading)
            // `markdown:` rather than `Text(value)`: these come from `describe`,
            // which builds them with `+`, and a concatenated string is not a
            // string literal — so its `**bold**` would print its own asterisks.
            Text(markdown: value).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func statusDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }

    private func color(for status: SidecarStatus) -> Color {
        switch status {
        case .running: .green
        case .starting, .restarting: .orange
        case .stopped: .gray
        case .failed: .red
        }
    }

    /// P9.4: what the status means for the person, not the exit code on its
    /// own. "failed — exited 1" left the user to work out for themselves that
    /// nothing durable in the app was going to work.
    private func describe(_ status: SidecarStatus, id: String) -> String {
        status.explanation(id: id)
    }

    private func describe(_ outcome: BootstrapStore.LoadOutcome) -> String {
        switch outcome {
        case .loaded: t("read from the existing file", "How the bootstrap config was loaded.")
        case .createdDefault: t("a new file was written from the defaults",
                                "How the bootstrap config was loaded.")
        // P9.2 — both of these replaced or refused somebody's file, so both say
        // that a copy of the old one is still there. "Your settings moved" is
        // only reassuring if you can check.
        case .migrated(let from, let steps):
            t("migrated from version \(from) to version \(BootstrapConfig.currentSchemaVersion) (steps \(steps.map(String.init).joined(separator: ", "))) — the old file is kept as bootstrap.v\(from).backup.plist",
              "The settings file was upgraded. Placeholders: the old version, the new version, the migration steps that ran, and the old version again in the backup filename.")
        case .newerThanExpected(let version):
            t("the settings file is version \(version), newer than this build understands (\(BootstrapConfig.currentSchemaVersion)) — the defaults are being used this run and **the file was left alone**",
              "The settings file came from a newer build. Placeholders: the file's version and this build's version.")
        case .repairedInvalid:
            t("the existing file was unusable and was replaced with the defaults — the old one is kept as bootstrap.unreadable.backup.plist",
              "The settings file would not parse.")
        }
    }
}

/// What a stopped component looks like from wherever the person happens to be.
///
/// The status has existed since P0.4 and was shown on one screen. That is enough
/// for somebody already looking for it and no use at all to somebody in the
/// middle of a conversation, which is the state the app is usually in when a
/// sidecar dies (AUDIT F-12).
///
/// Deliberately not dismissible: it disappears when the thing it describes is
/// fixed, and a banner a person can wave away is a banner they will wave away.
struct SidecarFailureBanner: View {
    let environment: AppEnvironment

    var body: some View {
        let failures = environment.failedSidecars
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: Space.tight) {
                ForEach(failures, id: \.id) { failure in
                    HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(failure.explanation)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(t("Service \(failure.id) has stopped — \(failure.explanation)",
                                          "Screen-reader label on the sidecar failure banner. Placeholders: the service name and why it stopped."))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.box)
            // Solid, not glass: it carries the reason somebody has to read
            // (§24.2).
            .background(.orange.opacity(0.12))
            Divider()
        }
    }
}
