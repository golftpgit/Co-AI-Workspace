import SwiftUI
import AgentKit
import CoreEngine

// ─────────────────────────────────────────────────────────────
// The Team screen (ARCHITECTURE §2.2, P4.7).
//
// The Done-when is that work running in parallel is visible from one place, so
// the list is the screen and everything else is around it. Three things are on
// every row because leaving any of them out sends the user somewhere else to
// find it:
//
//   which role holds it · how many attempts it has taken ·
//   and, when QA sent it back, the reasons it gave.
//
// "Escalated" without reasons is the state that made v1's loops unreadable, so
// the reasons are on the row rather than behind a disclosure.
// ─────────────────────────────────────────────────────────────

struct TeamView: View {
    @Bindable var model: TeamViewModel

    private var hasNoGoal: Bool {
        model.goal.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !model.draft.isEmpty {
                PlanEditor(model: model)
            } else if model.rows.isEmpty {
                ContentUnavailableView(
                    t("No team work yet", "Empty state on the team rail."),
                    systemImage: "person.3",
                    description: Text(localised: "Type a goal above and let the team lead plan it, or skip the lead and instruct a specialist yourself — either way the plan comes back for you to edit before anything starts",
                                      "Empty-state explanation on the team rail."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let plan = model.plan { PlanSummary(plan: plan) }
                        ForEach(model.rows) { AssignmentRow(model: model, row: $0) }
                    }
                    .padding(Space.section)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localised: "Team", "Heading of the team rail.").font(.headline)
                if model.unfinishedCount > 0 {
                    Text(localised: "\(model.unfinishedCount) unfinished",
                         "Count of team assignments still running. Placeholder is how many.")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                TextField(t("The goal of this piece of work, for example: summarise the guidance on antibiotics before surgery",
                            "Placeholder in the field where a person states what the team should achieve."),
                          text: $model.goal)
                    .textFieldStyle(.roundedBorder)
                    // Enter asks for a plan; it never starts work, because
                    // nothing starts before the user has seen the plan (§2.6).
                    .onSubmit { Task { await model.propose() } }
                    .disabled(model.isRunning)
                    .accessibilityLabel(t("Goal to give the team", "Screen-reader label for the goal field."))

                // §5.5 / P4.8 — the third thing a person walking away wants to
                // bound, beside "how many times" and "how much money": how many
                // tokens this run may spend. Blank is no ceiling, which is what
                // it has always been; the field does not invent one.
                TextField(t("Token ceiling", "Field limiting how many tokens this run may spend."),
                          text: $model.tokenCeiling)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .disabled(model.isRunning)
                    .accessibilityLabel(t("Token ceiling for this run", "Screen-reader label for the token ceiling field."))
                    .accessibilityHint(t("leave empty for no limit · at the ceiling, the remaining work waits for a person to decide",
                                         "Screen-reader hint explaining what the ceiling does."))

                if model.isRunning {
                    ProgressView().controlSize(.small)
                    // Stopping is not the same as finishing, and the screen
                    // says so afterwards rather than clearing the rows.
                    Button(t("Stop", "Button that cancels the turn the assistant is running right now.")) {
                        model.cancel()
                    }
                        .accessibilityLabel(t("Stop the team", "Screen-reader label for the button that halts the team run."))
                } else if model.draft.isEmpty {
                    if model.isPlanning { ProgressView().controlSize(.small) }
                    Button(t("Have the team lead plan it",
                             "Button that asks the lead to propose a plan for the goal.")) {
                        Task { await model.propose() }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(hasNoGoal || model.isPlanning)
                        .accessibilityLabel(t("Have the team lead propose a plan for this goal",
                                              "Screen-reader label for the plan button."))

                    // §2.6's first row: the dropdown that skips the lead is
                    // still here, and is not a fallback for when planning fails.
                    Menu(t("Skip the team lead", "Menu for instructing one specialist directly.")) {
                        ForEach(Role.assignable, id: \.self) { role in
                            Button(role.label) { model.draftDirect(role: role) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(hasNoGoal || model.isPlanning)
                    .accessibilityLabel(t("Instruct a single specialist directly", "Screen-reader label."))
                }
            }

            workPackagePicker

            if let status = model.status {
                Label(status.message, systemImage: status.isError
                      ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(status.isError ? .orange : .secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(Space.box)
    }

    /// Which leaf of the plan this run is against (§19.6, P10.4).
    ///
    /// The same control the chat header has, for the same reason and now for a
    /// second one: an assignment is where most of a project's hours actually
    /// go, and until this the ledger's `work_package` column was written by
    /// nobody — so "how much time has this promise cost" could only ever see
    /// chat. Choosing nothing stays legitimate; not every run is against a plan.
    @ViewBuilder
    private var workPackagePicker: some View {
        if !model.workPackages.isEmpty {
            HStack(spacing: 8) {
                Picker(t("Work package", "Picker: which planned unit of work this conversation counts against."),
                       selection: $model.workPackage) {
                    Text(localised: "Not tied to a work package",
                         "Picker option: this conversation is a question, not work against a promise.")
                        .tag(String?.none)
                    ForEach(model.workPackages) { package in
                        Text(package.title).tag(String?.some(package.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                .labelsHidden()
                .disabled(model.isRunning)
                .accessibilityLabel(t("Choose the work package this team run belongs to", "Screen-reader label."))
                .help(t("Time the team spends on this run is counted against the package you pick",
                        "Tooltip on the team run's work package picker."))
                Text(localised: "Time for every assignment in this plan is counted against the package you pick",
                     "Note under the work package picker on the team rail.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

// MARK: - editing the plan before it runs (§2.6)

/// The plan while it is still the user's. Nothing has been assigned yet, so
/// every field is a text field and the refusal §2.4 would raise is shown here,
/// where it can still be fixed, instead of arriving as an error after starting.
private struct PlanEditor: View {
    @Bindable var model: TeamViewModel
    @State private var refusal: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(t("Nothing has started — every field is editable until you approve it",
                        "Heading of the plan editor, before any work runs."),
                      systemImage: "square.and.pencil")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let refusal {
                    Label(refusal, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                ForEach($model.draft) { $item in
                    DraftCard(item: $item) { model.removeDraft(item.id) }
                }

                HStack {
                    Button(t("Add assignment", "Button that adds a row to the draft plan."),
                           systemImage: "plus") { model.addDraftAssignment() }
                    Spacer()
                    Button(t("Discard this plan", "Button that throws the draft away."),
                           role: .destructive) { model.discardDraft() }
                    Button(t("Approve and start", "Button that accepts the plan and sets the team running.")) {
                        Task { await model.start() }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.draftIsRunnable || refusal != nil)
                        .accessibilityLabel(t("Approve this plan and let the team begin", "Screen-reader label."))
                }
            }
            .padding(Space.section)
        }
        .task(id: model.draft) { refusal = await model.refusal() }
    }
}

private struct DraftCard: View {
    @Binding var item: TeamViewModel.Draft
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(t("Assigned to", "Picker: which specialist takes this assignment."), selection: $item.role) {
                    ForEach(Role.assignable, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(t("Choose the specialist for this assignment", "Screen-reader label."))

                TextField(t("What to do", "Text field holding one assignment's instruction."), text: $item.goal)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(t("Assignment detail", "Screen-reader label for the assignment goal field."))

                Button(t("Delete", "Button that removes an assignment from the draft plan."),
                       systemImage: "trash", action: remove)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(t("Remove this assignment from the plan", "Screen-reader label."))
            }

            TextField(t("What must be delivered, for example: a summary document",
                        "Text field naming the kind of thing this assignment produces."),
                      text: $item.deliverableType)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(t("Kind of deliverable required", "Screen-reader label."))

            VStack(alignment: .leading, spacing: 3) {
                Text(localised: "Acceptance criteria — one per line, written as  criterion | evidence that must be seen",
                     "Instruction above the criteria editor, giving the exact format expected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Required, not optional: an assignment with no criteria cannot
                // be reviewed, and §2.5 reviews evidence rather than opinions.
                TextEditor(text: $item.criteria)
                    .font(.callout)
                    .frame(minHeight: 54)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(.quaternary))
                    .accessibilityLabel(t("Acceptance criteria for this assignment, one per line", "Screen-reader label."))
                if item.assignment == nil {
                    Text(localised: "Cannot start yet — it needs both an instruction and at least one acceptance criterion",
                         "Shown when a draft assignment is not yet startable.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(Space.box)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.sheet))
    }
}

private struct PlanSummary: View {
    let plan: TeamPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(t("The team lead's plan — \(plan.assignments.count) assignments",
                    "Heading over a plan that has started. Placeholder is how many assignments it holds."),
                  systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(plan.goal)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(Space.box)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: Radius.box))
    }
}

private struct AssignmentRow: View {
    @Bindable var model: TeamViewModel
    let row: TeamViewModel.Row
    @State private var askingRework = false
    @State private var note = ""
    @State private var confirmingCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoleChip(role: row.role)
                Text(row.goal)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Spacer()
                ProgressChip(progress: row.progress, attempts: row.attempts)
            }

            if let summary = row.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !row.findings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.progress == .passed
                         ? t("notes from review", "Heading over QA notes on work that passed.")
                         : t("why it was sent back", "Heading over QA reasons on work that failed."))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(row.findings.enumerated()), id: \.offset) { _, finding in
                        Text("• \(finding)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(Space.row)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: Radius.box))
            }

            actions
        }
        .padding(Space.box)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.sheet))
        .sheet(isPresented: $askingRework) { reworkSheet }
        .confirmationDialog(t("Cancel this assignment?", "Title of the confirmation before cancelling work."),
                            isPresented: $confirmingCancel,
                            titleVisibility: .visible) {
            Button(t("Cancel the assignment", "Confirming button that stops the assignment."),
                   role: .destructive) {
                Task { await model.cancel(row) }
            }
            Button(t("No", "Button that dismisses the cancel confirmation."), role: .cancel) {}
        } message: {
            Text(localised: "It is recorded that a person stopped it — Run-until-done will not pick it up again",
                 "Explains the consequence of cancelling. 'Run-until-done' is a mode name and stays as is.")
        }
    }

    /// §2.6: the plan, and every piece of it, stays the user's to change. Until
    /// now the only control was stopping the whole run, which is a blunt answer
    /// to "this one is wrong".
    @ViewBuilder
    private var actions: some View {
        if row.progress != .running {
            HStack(spacing: 12) {
                Button(t("Send back…", "Button that returns finished work for another attempt.")) {
                    note = ""; askingRework = true
                }
                    .disabled(!model.isReworkable(row))
                    .help(model.isReworkable(row)
                          ? t("Send it back for another attempt, with a reason",
                              "Tooltip on the rework button.")
                          : t("This assignment's record has no acceptance criteria, so it cannot be recreated",
                              "Tooltip on a disabled rework button."))
                if row.progress != .cancelled {
                    Button(t("Cancel", "Button that stops a running assignment."),
                           role: .destructive) { confirmingCancel = true }
                }
                Spacer()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private var reworkSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localised: "Send back: \(row.goal)",
                 "Title of the rework sheet. Placeholder is the assignment's goal.")
                .font(.headline)
            // Required, not optional. "try again" with no reason is the
            // instruction that made v1's loops repeat themselves, and this
            // note goes to the specialist in the same place QA's findings do.
            Text(localised: "Say what needs changing — this text is sent as the same kind of reason QA gives",
                 "Instruction in the rework sheet, explaining where the note goes.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $note)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: Radius.box).stroke(.quaternary))
            HStack {
                Spacer()
                Button(t("Close", "Button that dismisses the rework sheet.")) { askingRework = false }
                Button(t("Send it back", "Button that files the rework with its reason.")) {
                    askingRework = false
                    Task { await model.rework(row, note: note) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.section)
        .frame(width: 460)
    }
}

private struct RoleChip: View {
    let role: Role

    var body: some View {
        Text(role.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.secondary.opacity(0.18), in: Capsule())
            .accessibilityLabel(t("Role \(role.label)", "Screen-reader label for a role badge. Placeholder is the role name."))
    }
}

extension Role {
    /// The roles a person can hand work to. The lead plans and QA reviews;
    /// neither takes an assignment, so neither belongs in a picker of who
    /// could do this piece of work.
    static var assignable: [Role] { [.researcher, .analyst, .engineer, .writer] }

    var label: String {
        switch self {
        case .teamLead: t("Team lead", "Picker option: the team lead is accountable.")
        case .researcher: "Researcher"
        case .analyst: "Analyst"
        case .engineer: "Engineer"
        case .writer: "Writer"
        case .reviewer: "QA"
        }
    }
}

private struct ProgressChip: View {
    let progress: TeamViewModel.Progress
    let attempts: Int

    var body: some View {
        HStack(spacing: 4) {
            if progress == .running { ProgressView().controlSize(.mini) }
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .accessibilityLabel(t("\(text), \(attempts) attempts so far",
                              "Screen-reader label for an assignment's status. Placeholders: the status text and how many attempts."))
    }

    // Attempts are on the chip rather than hidden: a task that passed on the
    // third try and one that passed immediately are not the same result.
    private var text: String {
        switch progress {
        case .running: t("running (attempt \(attempts))",
                         "Assignment status. Placeholder is which attempt this is.")
        case .passed: attempts > 1
            ? t("passed (on attempt \(attempts))",
                "Assignment status after more than one try. Placeholder is which attempt passed.")
            : t("passed", "Assignment status: accepted first time.")
        case .failed: t("sent back (attempt \(attempts))",
                        "Assignment status. Placeholder is which attempt was rejected.")
        case .escalated: t("needs a person to decide (\(attempts) attempts)",
                           "Assignment status. Placeholder is how many attempts were made.")
        case .cancelled: t("cancelled by the user", "Assignment status: a person stopped it.")
        }
    }

    private var icon: String {
        switch progress {
        case .running: "clock"
        case .passed: "checkmark.circle"
        case .failed: "arrow.uturn.backward"
        case .escalated: "hand.raised"
        case .cancelled: "xmark.circle"
        }
    }

    private var tint: Color {
        switch progress {
        case .running: .secondary
        case .passed: .green
        case .failed: .orange
        case .escalated: .red
        case .cancelled: .secondary
        }
    }
}
