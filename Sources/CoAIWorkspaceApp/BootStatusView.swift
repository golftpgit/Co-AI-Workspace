import SwiftUI
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
                    PluginsSection(model: plugins)
                        .task {
                            await plugins.attach(registry: engine.plugins,
                                                 mcp: engine.mcp,
                                                 gateway: engine.gateway)
                        }
                }
                if !environment.notes.isEmpty { notesSection }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("สถานะการเริ่มระบบ")
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
                Text("กำลังเริ่มระบบ…")
            case .ready:
                statusDot(.green)
                Text("พร้อมใช้งาน").fontWeight(.medium)
            case .degraded(let reason):
                statusDot(.red)
                VStack(alignment: .leading) {
                    Text("เริ่มระบบไม่สำเร็จ").fontWeight(.medium)
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var pathsSection: some View {
        if let paths = environment.paths {
            section("ที่เก็บข้อมูล") {
                labeled("Data directory", paths.root.path(percentEncoded: false))
                labeled("Bootstrap", paths.bootstrapFile.lastPathComponent)
                if !environment.createdDirectories.isEmpty {
                    labeled("สร้างใหม่รอบนี้", environment.createdDirectories.joined(separator: ", "))
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
                labeled("โหลดแบบ", describe(outcome))
            }
        }
    }

    private var sidecarSection: some View {
        section("Sidecars") {
            if environment.sidecarStatuses.isEmpty {
                Text("ยังไม่มี sidecar ที่ลงทะเบียน").foregroundStyle(.secondary)
            } else {
                ForEach(environment.sidecarStatuses.sorted(by: { $0.key < $1.key }), id: \.key) { id, status in
                    HStack(spacing: 8) {
                        statusDot(color(for: status))
                        Text(id).fontWeight(.medium)
                        Text(describe(status)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("sidecar \(id): \(describe(status))")
                }
            }
        }
    }

    /// Which models answered a readiness probe at boot. Without this, "why
    /// can't it run commands" is invisible — tool calling needs a tier above
    /// on-device (ARCHITECTURE §9.1).
    private var engineSection: some View {
        section("เอนจิน") {
            if let engine = environment.engine {
                labeled("ฐานข้อมูล", "เชื่อมต่อแล้ว")
                ForEach(Array(engine.executorSummary.enumerated()), id: \.offset) { _, line in
                    labeled("โมเดล", line)
                }
                // §7: a manifest that did not load is worth saying out loud —
                // a silent one looks like an agent that stopped behaving.
                labeled("ทะเบียน (§7)",
                        "\(engine.roster.count) รายการ"
                            + (engine.rosterProblems.isEmpty ? ""
                               : " · โหลดไม่ได้ \(engine.rosterProblems.count) ไฟล์"))
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
            } else {
                HStack(spacing: 8) {
                    statusDot(.orange)
                    Text(environment.engineError.map { "ยังเริ่มไม่สำเร็จ — \($0)" } ?? "กำลังเริ่ม…")
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var notesSection: some View {
        section("หมายเหตุ") {
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
            return "ยังไม่ได้ตั้งค่าเซิร์ฟเวอร์"
        }
        let tools = engine.mcpConnected.reduce(0) { $0 + $1.toolNames.count }
        let servers = "\(engine.mcpConnected.count) เซิร์ฟเวอร์ · \(tools) เครื่องมือ"
        return engine.mcpProblems.isEmpty ? servers
            : servers + " · ต่อไม่ได้ \(engine.mcpProblems.count)"
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
            Text(value).textSelection(.enabled)
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

    private func describe(_ status: SidecarStatus) -> String {
        switch status {
        case .stopped: "หยุดอยู่"
        case .starting: "กำลังเริ่ม…"
        case .running(let pid): "ทำงานอยู่ (pid \(pid))"
        case .restarting(let n): "กำลังเริ่มใหม่ (ครั้งที่ \(n))"
        case .failed(let reason): "ล้มเหลว — \(reason)"
        }
    }

    private func describe(_ outcome: BootstrapStore.LoadOutcome) -> String {
        switch outcome {
        case .loaded: "อ่านจากไฟล์เดิม"
        case .createdDefault: "สร้างไฟล์ใหม่จากค่าเริ่มต้น"
        // P9.2 — both of these replaced or refused somebody's file, so both say
        // that a copy of the old one is still there. "Your settings moved" is
        // only reassuring if you can check.
        case .migrated(let from, let steps):
            "ย้ายจากรุ่น \(from) เป็นรุ่น \(BootstrapConfig.currentSchemaVersion) "
                + "(ขั้นที่ \(steps.map(String.init).joined(separator: ", "))) — "
                + "ไฟล์เดิมเก็บไว้เป็น bootstrap.v\(from).backup.plist"
        case .newerThanExpected(let version):
            "ไฟล์ตั้งค่าเป็นรุ่น \(version) ซึ่งใหม่กว่าที่แอปรุ่นนี้รู้จัก "
                + "(\(BootstrapConfig.currentSchemaVersion)) — รอบนี้ใช้ค่าเริ่มต้นและ**ไม่แก้ไฟล์เดิม**"
        case .repairedInvalid:
            "ไฟล์เดิมใช้ไม่ได้ จึงเขียนทับด้วยค่าเริ่มต้น — "
                + "ไฟล์เดิมเก็บไว้เป็น bootstrap.unreadable.backup.plist"
        }
    }
}
