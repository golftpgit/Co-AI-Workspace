import SwiftUI
import AgentKit
import ProjectKit

// ─────────────────────────────────────────────────────────────
// The project screen (ARCHITECTURE §19.1, §19.4, §19.6).
//
// Small on purpose: the full Plan area with WBS, Gantt, Kanban and the
// registers is P10.4–P10.12. What has to exist *now* is everything the stage
// gate depends on — a project, its scope statement, and a visible reason why
// the next gate has not opened. Shipping the gate without this screen would
// mean a project that can never leave Initiation, which is a worse bug than
// having no gate at all.
// ─────────────────────────────────────────────────────────────

struct ProjectsView: View {
    @Bindable var model: ProjectsViewModel
    @State private var newName = ""
    @State private var newKind = ProjectKind.blank
    @State private var draft: Project?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            detail.frame(minWidth: 420, maxWidth: .infinity)
        }
        .task { await model.reload() }
    }

    // MARK: - list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("พื้นที่ทำงาน")
                .font(.headline)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)

            List {
                Section {
                    Button {
                        Task { await model.select(.general) }
                    } label: {
                        Label("General — คุยทั่วไป", systemImage: "bubble.left")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .fontWeight(model.selection == .general ? .semibold : .regular)
                }

                Section("โปรเจกต์") {
                    ForEach(model.projects) { project in
                        Button {
                            Task { await model.select(.project(project.id)) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                    Text(project.kind.label)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(project.stage.label)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .fontWeight(model.selection == .project(project.id) ? .semibold : .regular)
                        .accessibilityLabel("เปิดโปรเจกต์ \(project.name) ขั้น\(project.stage.label)")
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                TextField("ชื่อโปรเจกต์ใหม่", text: $newName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("ชนิด", selection: $newKind) {
                        ForEach(ProjectKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    Button("สร้าง") {
                        Task {
                            await model.create(name: newName, kind: newKind)
                            newName = ""
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
    }

    // MARK: - detail

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let status = model.status {
                    Text(status.message)
                        .font(.callout)
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }

                if let project = model.selected {
                    projectDetail(project)
                } else {
                    generalDetail
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General").font(.title3).bold()
            Text("""
                 คุยและสั่งงานสั้น ๆ ได้ทันที ไม่มีทีม ไม่มีบันทึกงาน ไม่มีขั้นของโครงการ \
                 ความรู้ที่เก็บระหว่างคุยจะอยู่ในคลังส่วนกลาง
                 """)
                .foregroundStyle(.secondary)
            Text("งานที่มีเป้าหมายและวันจบ ให้สร้างเป็นโปรเจกต์ — เครื่องมือที่เปลี่ยนข้อมูลจะเดินตามขั้นของโครงการ")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func projectDetail(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name).font(.title3).bold()
            HStack(spacing: 8) {
                Text("ขั้น\(project.stage.label)")
                if let closure = project.closure {
                    Text("· \(closure.label)").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }

        stageStrip(project.stage)

        GroupBox("เหตุผลที่ทำ") {
            TextEditor(text: briefBinding(project))
                .frame(minHeight: 60)
                .font(.body)
                .accessibilityLabel("เหตุผลที่ทำโครงการนี้")
        }

        GroupBox("ขอบเขต") {
            VStack(alignment: .leading, spacing: 10) {
                listEditor("ทำ", lines: project.statement.inScope) { updated in
                    var next = project; next.statement.inScope = updated
                    Task { await model.update(next) }
                }
                listEditor("ไม่ทำ", lines: project.statement.outOfScope) { updated in
                    var next = project; next.statement.outOfScope = updated
                    Task { await model.update(next) }
                }
                listEditor("เกณฑ์รับงาน", lines: project.statement.acceptanceCriteria) { updated in
                    var next = project; next.statement.acceptanceCriteria = updated
                    Task { await model.update(next) }
                }
                Text("ช่อง “ไม่ทำ” ว่างไม่ได้ — ขอบเขตที่ไม่เคยบอกว่าไม่ทำอะไร คือขอบเขตที่บานทุกครั้ง")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        if let gate = model.gate {
            gateBox(gate)
        } else {
            Text("โครงการปิดแล้ว — อ่านได้ แต่เครื่องมือที่เปลี่ยนข้อมูลใช้ไม่ได้แล้ว")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func stageStrip(_ current: ProjectStage) -> some View {
        HStack(spacing: 4) {
            ForEach(ProjectStage.allCases, id: \.self) { stage in
                Text(stage.label)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(stage == current ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(stage <= current ? Color.primary : Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ขั้นของโครงการ ตอนนี้อยู่ขั้น\(current.label)")
    }

    private func gateBox(_ gate: GateEvaluation) -> some View {
        GroupBox("\(gate.gate) → ขั้น\(gate.to.label)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(gate.conditions.enumerated()), id: \.offset) { _, condition in
                    Label {
                        Text(condition.text)
                    } icon: {
                        Image(systemName: condition.satisfied ? "checkmark.circle" : "circle")
                            .foregroundStyle(condition.satisfied ? Color.green : Color.secondary)
                    }
                    .font(.callout)
                }

                HStack {
                    Button("ผ่านขั้นนี้") { Task { await model.advance() } }
                        .disabled(!gate.passed)
                        .keyboardShortcut(.return, modifiers: [.command])
                    Button("ยุติโครงการ") { Task { await model.terminate(reason: "ผู้ใช้สั่งยุติ") } }
                    Spacer()
                }
                if !gate.passed {
                    Text("ขั้นนี้ยังใช้เครื่องมือที่\(allowedText(gate.from))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func allowedText(_ stage: ProjectStage) -> String {
        switch stage {
        case .initiation: "อ่านอย่างเดียว"
        case .planning: "อ่านและร่างเอกสารได้ แต่ยังเปลี่ยนข้อมูลไม่ได้"
        case .execution: "ทำได้ทุกอย่างตามระดับความเสี่ยง"
        case .closing: "เขียนรายงานได้ แต่ตัวเลขต้องไม่ขยับแล้ว"
        case .closed: "อ่านอย่างเดียว"
        }
    }

    // MARK: - editing helpers

    private func briefBinding(_ project: Project) -> Binding<String> {
        Binding(get: { project.brief },
                set: { text in
                    var next = project
                    next.brief = text
                    draft = next
                    Task { await model.update(next) }
                })
    }

    /// One line per item. A grid of add/remove buttons for what is usually
    /// three bullets is more UI than the content deserves.
    private func listEditor(_ title: String,
                            lines: [String],
                            onChange: @escaping ([String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { lines.joined(separator: "\n") },
                set: { text in
                    onChange(text.split(separator: "\n", omittingEmptySubsequences: true)
                                 .map { $0.trimmingCharacters(in: .whitespaces) }
                                 .filter { !$0.isEmpty })
                }))
                .frame(minHeight: 52)
                .accessibilityLabel("รายการ\(title) หนึ่งบรรทัดต่อหนึ่งข้อ")
        }
    }
}
