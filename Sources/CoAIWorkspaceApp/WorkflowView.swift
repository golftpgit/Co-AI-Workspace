import SwiftUI
import AgentKit
import CoreEngine

// ─────────────────────────────────────────────────────────────
// Workflow Builder (ARCHITECTURE §14.2, P8.6) — a procedure you can keep and
// run again.
//
// The rules are in `Workflow.swift` (CoreEngine) where `swift test` reaches
// them. This file is the palette, the step list and the run report.
//
// **The palette is the tool list, live.** It is not a hand-written menu: it is
// whatever `ToolGateway` can reach right now, which means an MCP server or a
// plugin that connected a minute ago appears in it without anybody editing
// this file (the P8.5 rule). It also means the palette cannot offer a tool the
// gateway would then refuse as unknown.
//
// **Every step card says what it costs before it runs.** The declared risk
// comes from the gateway's advert, not from the workflow file — a saved
// procedure cannot talk its own steps down, for the same reason a manifest
// cannot (P8.2).
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class WorkflowViewModel {
    private(set) var workflows: [Workflow] = []
    private(set) var palette: [ToolAdvert] = []
    private(set) var known: [String] = []
    private(set) var run: WorkflowRun?
    private(set) var problem: String?
    private(set) var running = false

    /// The one being edited. Held apart from the saved list so editing is not
    /// saving — U20-1's lesson, one level up: typing must not reach the store.
    var draft: Workflow?

    private var store: WorkflowStore?
    private var runner: WorkflowRunner?
    private var context: ToolContext?

    func attach(store: WorkflowStore, gateway: ToolGateway, context: ToolContext) async {
        self.store = store
        self.runner = WorkflowRunner(gateway: gateway)
        self.context = context
        workflows = store.load()
        palette = await gateway.adverts
        known = palette.map(\.name)
    }

    var refusal: String? {
        guard let draft, let runner else { return nil }
        return runner.refusal(for: draft, known: known)
    }

    func newWorkflow() {
        draft = Workflow(name: "ลำดับงานใหม่")
        run = nil
        problem = nil
    }

    func edit(_ workflow: Workflow) {
        draft = workflow
        run = nil
        problem = nil
    }

    func add(_ advert: ToolAdvert) {
        guard draft != nil else { return }
        draft?.steps.append(WorkflowStep(tool: advert.name))
    }

    func removeStep(_ id: String) {
        draft?.steps.removeAll { $0.id == id }
    }

    func move(_ id: String, by offset: Int) {
        guard var steps = draft?.steps,
              let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
        draft?.steps = steps
    }

    func save() {
        guard let store, let draft else { return }
        if let refusal { problem = refusal; return }
        do {
            workflows = try store.upsert(draft)
            problem = nil
        } catch {
            problem = "\(error)"
        }
    }

    func delete(_ id: String) {
        guard let store else { return }
        try? store.remove(id)
        workflows = store.load()
        if draft?.id == id { draft = nil }
    }

    func runDraft() async {
        guard let runner, let draft, let context else { return }
        if let refusal { problem = refusal; return }
        running = true
        run = await runner.run(draft, context: context)
        running = false
    }
}

struct WorkflowView: View {
    @Bindable var model: WorkflowViewModel

    var body: some View {
        HSplitView {
            saved.frame(minWidth: 200, idealWidth: 230)
            builder.frame(minWidth: 380, maxWidth: .infinity)
            paletteColumn.frame(minWidth: 200, idealWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Saved procedures

    private var saved: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ลำดับงานที่บันทึกไว้").fontWeight(.semibold)
                Spacer()
                Button {
                    model.newWorkflow()
                } label: {
                    Image(systemName: "plus").accessibilityLabel("สร้างลำดับงานใหม่")
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
            Divider()

            if model.workflows.isEmpty {
                ContentUnavailableView("ยังไม่มีลำดับงาน", systemImage: "list.number",
                                       description: Text("ลำดับงานคือขั้นตอนที่ทำซ้ำทุกเดือน "
                                                         + "บันทึกไว้แล้วกดรันใหม่ได้ โดยทุกขั้นยังผ่านการอนุมัติเหมือนเดิม"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.workflows) { workflow in
                    Button { model.edit(workflow) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workflow.name)
                                .fontWeight(model.draft?.id == workflow.id ? .semibold : .regular)
                            Text("\(workflow.steps.count) ขั้น · "
                                 + workflow.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("ลำดับงาน \(workflow.name)")
                    .contextMenu {
                        Button("ลบ", role: .destructive) { model.delete(workflow.id) }
                    }
                    // §14.4 rule 3: a context menu needs a second door, because
                    // right-click is a mouse and most Mac keyboards have no menu key.
                    .accessibilityAction(named: "ลบลำดับงานนี้") { model.delete(workflow.id) }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - The steps

    @ViewBuilder
    private var builder: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    TextField("ชื่อลำดับงาน", text: Binding(
                        get: { model.draft?.name ?? "" },
                        set: { model.draft?.name = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Spacer()
                    Button("บันทึก") { model.save() }
                    Button(model.running ? "กำลังรัน…" : "รัน") {
                        Task { await model.runDraft() }
                    }
                    .disabled(model.running || model.refusal != nil)
                }
                .padding(10)

                // The objection while it is still fixable, not after pressing
                // run — the same choice `TeamOrchestrator.refusal` makes (P4.6).
                if let refusal = model.refusal {
                    Text(refusal)
                        .font(.callout).foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                }
                if let problem = model.problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                }

                Divider()

                if draft.steps.isEmpty {
                    ContentUnavailableView("ยังไม่มีขั้นตอน", systemImage: "hand.point.right",
                                           description: Text("เลือกทูลจากรายการทางขวาเพื่อเพิ่มเป็นขั้นตอน"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                                stepCard(index: index, step: step)
                            }
                        }
                        .padding(10)
                    }
                }

                if let run = model.run { Divider(); report(run) }
            }
        } else {
            ContentUnavailableView("เลือกหรือสร้างลำดับงาน", systemImage: "list.number",
                                   description: Text("ลำดับงานที่บันทึกไว้ รันซ้ำได้โดยทุกขั้นยังเดินผ่านประตูอนุมัติเดิม"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stepCard(index: Int, step: WorkflowStep) -> some View {
        let advert = model.palette.first { $0.name == step.tool }
        // Driving this found the gap: the report at the bottom said the run
        // stopped, and the card for the step that stopped it looked exactly
        // like the others. In a ten-step procedure that means reading a name
        // and hunting for it — the U25-5/U28-1 shape again, where the verdict
        // lands somewhere other than the thing it is about.
        let outcome = model.run?.outcomes.first { $0.stepID == step.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                Text(step.tool).fontWeight(.semibold)
                // Risk comes from the gateway, never from the saved file.
                if let advert {
                    Text(riskLabel(advert.declaredRisk))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(riskColour(advert.declaredRisk).opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                Button { model.move(step.id, by: -1) } label: {
                    Image(systemName: "arrow.up").accessibilityLabel("เลื่อนขั้นนี้ขึ้น")
                }
                .buttonStyle(.borderless).disabled(index == 0)
                Button { model.move(step.id, by: 1) } label: {
                    Image(systemName: "arrow.down").accessibilityLabel("เลื่อนขั้นนี้ลง")
                }
                .buttonStyle(.borderless)
                .disabled(index == (model.draft?.steps.count ?? 0) - 1)
                Button { model.removeStep(step.id) } label: {
                    Image(systemName: "trash").accessibilityLabel("ลบขั้น \(step.tool)")
                }
                .buttonStyle(.borderless)
            }
            if let outcome {
                HStack(spacing: 6) {
                    Image(systemName: outcome.succeeded
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(outcome.succeeded ? .green : .orange)
                        .accessibilityHidden(true)
                    Text(outcome.stop?.label ?? "ผ่าน").font(.caption).fontWeight(.medium)
                    Text(outcome.detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
            if let advert {
                Text(advert.description).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("ไม่มีทูลชื่อนี้แล้ว — บันทึกไม่ได้จนกว่าจะแก้หรือลบขั้นนี้")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField("อาร์กิวเมนต์ (JSON)", text: Binding(
                get: { model.draft?.steps.first { $0.id == step.id }?.argumentsJSON ?? "{}" },
                set: { value in
                    guard let i = model.draft?.steps.firstIndex(where: { $0.id == step.id })
                    else { return }
                    model.draft?.steps[i].argumentsJSON = value
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            TextField("ขั้นนี้มีไว้ทำอะไร", text: Binding(
                get: { model.draft?.steps.first { $0.id == step.id }?.note ?? "" },
                set: { value in
                    guard let i = model.draft?.steps.firstIndex(where: { $0.id == step.id })
                    else { return }
                    model.draft?.steps[i].note = value
                }))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            if outcome == nil, model.run?.completed == false {
                // Blank would read as "this one was fine". It never ran.
                Text("ยังไม่ได้รัน — ลำดับหยุดก่อนถึงขั้นนี้")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - What happened

    private func report(_ run: WorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.completed ? "รันครบทุกขั้น" : "หยุดที่ขั้นที่ไม่ผ่าน")
                    .fontWeight(.semibold)
                    .foregroundStyle(run.completed ? .green : .orange)
                if let stop = run.stoppedAt?.stop {
                    // Not "failed": a person declining is the gate working.
                    Text(stop.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(run.outcomes, id: \.stepID) { outcome in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: outcome.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(outcome.succeeded ? .green : .orange)
                        .accessibilityHidden(true)
                    Text(outcome.tool).font(.caption).fontWeight(.medium)
                    Text(outcome.detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    // MARK: - Palette

    private var paletteColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ทูลที่ใช้ได้ตอนนี้").fontWeight(.semibold).padding(10)
            Divider()
            if model.palette.isEmpty {
                ContentUnavailableView("ยังไม่มีทูล", systemImage: "wrench.and.screwdriver",
                                       description: Text("รายการนี้อ่านจาก ToolGateway จริง "
                                                         + "ทูลจาก MCP หรือปลั๊กอินที่เพิ่งต่อจะขึ้นเอง"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.palette, id: \.name) { advert in
                    Button { model.add(advert) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(advert.name).font(.callout).fontWeight(.medium)
                                Text(riskLabel(advert.declaredRisk))
                                    .font(.caption2)
                                    .foregroundStyle(riskColour(advert.declaredRisk))
                            }
                            Text(advert.description).font(.caption2)
                                .foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.draft == nil)
                    .accessibilityLabel("เพิ่มขั้น \(advert.name)")
                }
                .listStyle(.inset)
            }
        }
    }

    private func riskLabel(_ risk: RiskLevel) -> String {
        switch risk {
        case .low: "เสี่ยงต่ำ"
        case .medium: "เสี่ยงปานกลาง"
        case .high: "เสี่ยงสูง"
        }
    }

    private func riskColour(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}
