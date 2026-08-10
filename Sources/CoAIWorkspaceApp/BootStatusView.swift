import SwiftUI
import Config
import Sidecar

/// P0 shell: proves the app launches, reads its config, creates its
/// directories and reports sidecar health. Replaced by the Chat view in P1.10.
struct BootStatusView: View {
    let environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                phaseSection
                pathsSection
                configSection
                sidecarSection
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
            Text("Phase 0 — scaffold").foregroundStyle(.secondary)
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

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
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
        case .repairedInvalid: "ไฟล์เดิมใช้ไม่ได้ จึงเขียนทับด้วยค่าเริ่มต้น"
        }
    }
}
