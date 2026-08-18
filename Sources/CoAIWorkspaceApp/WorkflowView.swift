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
        draft = Workflow(name: t("New workflow", "Default name for a workflow somebody just created."))
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
                Text(localised: "Saved workflows", "Heading over the workflow list.").fontWeight(.semibold)
                Spacer()
                Button {
                    model.newWorkflow()
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel(t("Create a new workflow", "Screen-reader label."))
                }
                .buttonStyle(.borderless)
            }
            .padding(Space.box)
            Divider()

            if model.workflows.isEmpty {
                ContentUnavailableView(t("No workflow yet", "Empty state in the workflow list."),
                                       systemImage: "list.number",
                                       description: Text(localised: "A workflow is the sequence you repeat every month — save it once and run it again, with every step still going through the same approvals",
                                                         "Empty-state explanation in the workflow list."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.workflows) { workflow in
                    Button { model.edit(workflow) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workflow.name)
                                .fontWeight(model.draft?.id == workflow.id ? .semibold : .regular)
                            Text(localised: "\(workflow.steps.count) steps · \(workflow.updatedAt.formatted(date: .abbreviated, time: .shortened))",
                                 "A workflow row. Placeholders: how many steps and when it was last changed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("Workflow \(workflow.name)",
                                          "Screen-reader label. Placeholder is the workflow name."))
                    .contextMenu {
                        Button(t("Delete", "Context-menu item that removes a file."),
                               role: .destructive) { model.delete(workflow.id) }
                    }
                    // §14.4 rule 3: a context menu needs a second door, because
                    // right-click is a mouse and most Mac keyboards have no menu key.
                    .accessibilityAction(named: t("Delete this workflow", "Screen-reader action name.")) {
                        model.delete(workflow.id)
                    }
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
                    TextField(t("Workflow name", "Text field holding the workflow's name."), text: Binding(
                        get: { model.draft?.name ?? "" },
                        set: { model.draft?.name = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Spacer()
                    Button(t("Save", "Button that stores the edited entities.")) { model.save() }
                    Button(model.running
                           ? t("running…", "Button label while a workflow is executing.")
                           : t("Run", "Button that executes the SQL in the editor.")) {
                        Task { await model.runDraft() }
                    }
                    .disabled(model.running || model.refusal != nil)
                }
                .padding(Space.box)

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
                    ContentUnavailableView(t("No steps yet", "Empty state inside a workflow."),
                                           systemImage: "hand.point.right",
                                           description: Text(localised: "Pick a tool from the list on the right to add it as a step",
                                                             "Empty-state instruction inside a workflow."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                                stepCard(index: index, step: step)
                            }
                        }
                        .padding(Space.box)
                    }
                }

                if let run = model.run { Divider(); report(run) }
            }
        } else {
            ContentUnavailableView(t("Choose or create a workflow", "Empty state before a workflow is selected."),
                                   systemImage: "list.number",
                                   description: Text(localised: "A saved workflow can be re-run with every step still passing through the same approval gate",
                                                     "Empty-state explanation before a workflow is selected."))
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
                    Image(systemName: "arrow.up")
                        .accessibilityLabel(t("Move this step up", "Screen-reader label."))
                }
                .buttonStyle(.borderless).disabled(index == 0)
                Button { model.move(step.id, by: 1) } label: {
                    Image(systemName: "arrow.down")
                        .accessibilityLabel(t("Move this step down", "Screen-reader label."))
                }
                .buttonStyle(.borderless)
                .disabled(index == (model.draft?.steps.count ?? 0) - 1)
                Button { model.removeStep(step.id) } label: {
                    Image(systemName: "trash")
                        .accessibilityLabel(t("Delete the \(step.tool) step",
                                              "Screen-reader label. Placeholder is the tool name."))
                }
                .buttonStyle(.borderless)
            }
            if let outcome {
                HStack(spacing: 6) {
                    Image(systemName: outcome.succeeded
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(outcome.succeeded ? .green : .orange)
                        .accessibilityHidden(true)
                    Text(outcome.stop?.label
                         ?? t("passed", "Assignment status: accepted first time."))
                        .font(.caption).fontWeight(.medium)
                    Text(outcome.detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
            if let advert {
                Text(advert.description).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(localised: "There is no tool by that name any more — this cannot be saved until the step is fixed or removed",
                     "Shown on a workflow step whose tool has gone.")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField(t("Arguments (JSON)", "Text field holding a workflow step's arguments."), text: Binding(
                get: { model.draft?.steps.first { $0.id == step.id }?.argumentsJSON ?? "{}" },
                set: { value in
                    guard let i = model.draft?.steps.firstIndex(where: { $0.id == step.id })
                    else { return }
                    model.draft?.steps[i].argumentsJSON = value
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            TextField(t("What this step is for", "Text field: why a workflow step exists."), text: Binding(
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
                Text(localised: "Not run — the workflow stopped before reaching this step",
                     "Shown on a step the run never got to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Space.box)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: Radius.box))
    }

    // MARK: - What happened

    private func report(_ run: WorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.completed
                     ? t("every step ran", "Workflow run outcome: it finished.")
                     : t("stopped at the step that did not pass", "Workflow run outcome: it halted."))
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
        .padding(Space.box)
    }

    // MARK: - Palette

    private var paletteColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localised: "Tools available now", "Heading over the palette of tools.")
                .fontWeight(.semibold).padding(Space.box)
            Divider()
            if model.palette.isEmpty {
                ContentUnavailableView(t("No tools yet", "Empty state in the tool palette."),
                                       systemImage: "wrench.and.screwdriver",
                                       description: Text(localised: "This list is read from the real ToolGateway — tools from a newly connected MCP server or plug-in appear on their own",
                                                         "Empty-state explanation in the tool palette."))
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
                    .accessibilityLabel(t("Add a \(advert.name) step",
                                          "Screen-reader label. Placeholder is the tool name."))
                }
                .listStyle(.inset)
            }
        }
    }

    private func riskLabel(_ risk: RiskLevel) -> String {
        switch risk {
        case .low: t("low risk", "Risk level of a work package.")
        case .medium: t("medium risk", "Risk level of a work package.")
        case .high: t("high risk", "Risk level of a work package.")
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
