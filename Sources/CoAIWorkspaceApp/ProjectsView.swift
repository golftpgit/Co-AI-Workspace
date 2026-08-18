import SwiftUI
import AgentKit
import Roster
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
    /// The types read from files at boot (§20.2). Passed in rather than looked
    /// up here, because "which types exist" is an answer the engine has already
    /// worked out and a screen that recomputed it could disagree with it.
    let types: [ProjectTypeManifest]
    @State private var newName = ""
    @State private var newType: String?
    @State private var newPackageTitle = ""
    @State private var selectedParent: String?
    @State private var decision = ""
    @State private var decider = ""
    @State private var registerTitle = ""
    @State private var registerKind = RegisterKind.risk
    @State private var draft = Draft()
    @State private var saving = false
    /// The closing tab's forms (§19.12). Plain state rather than a sheet: every
    /// one of these is a gate condition, and putting a gate condition behind a
    /// modal is what made the Executive seat unreachable for five phases.
    @State private var benefitDraft = BenefitDraft()
    @State private var measurements: [String: String] = [:]
    @State private var tailoringReason = ""
    @State private var dispositionAction = DataDisposition.Action.keep
    @State private var dispositionPolicy = ""
    /// Per-leaf editing buffers, keyed by package id. Same reason as `draft`.
    @State private var criteriaDrafts: [String: String] = [:]
    /// Titles and tolerance limits, buffered the same way and for the same
    /// reason: both are text fields on values the gate reads.
    @State private var titleDrafts: [String: String] = [:]
    @State private var limitDrafts: [String: String] = [:]
    @State private var tab = PlanTab.overview

    /// The Plan area's sections (§19.2). Driving the screen by hand is what
    /// showed why they are needed: with everything on one page, reaching the
    /// registers meant scrolling past four boxes, and the gate — the one thing
    /// that says what to do next — was below all of them.
    enum PlanTab: String, CaseIterable, Identifiable {
        case overview, plan, board, team, closing
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: t("Overview", "Plan sub-tab: the project brief, scope and standards.")
            case .plan: t("Plan + sequence", "Plan sub-tab: the work breakdown and what depends on what.")
            case .board: t("Board", "Plan sub-tab: work packages as a kanban board.")
            case .team: t("Team & RACI", "Plan sub-tab: who is accountable for each package.")
            case .closing: t("Benefits & closing", "Plan sub-tab: measured benefits and the conditions for closing.")
            }
        }
    }

    /// One benefit being typed. Numbers as text on purpose: a `TextField` bound
    /// to a `Double` shows `0` for an empty field, and a baseline of zero that
    /// nobody typed is exactly the fake measurement §19.12 is about.
    struct BenefitDraft: Equatable {
        var title = ""
        var measure = ""
        var baseline = ""
        var target = ""
        var owner = ""
        var reviewAt = Date()

        var isReady: Bool {
            !title.trimmingCharacters(in: .whitespaces).isEmpty
                && Double(baseline) != nil && Double(target) != nil
        }
    }
    /// Sends an exception report out through every running channel. Passed in
    /// rather than reached for: this screen does not know what a channel is.
    let announce: (String) async -> Void
    /// Hands a leaf to the team screen as a draft assignment (§19.6, P10.4).
    /// A closure rather than the team model itself: the plan screen has no
    /// business knowing how a run is started, and which team lead belongs to
    /// this workspace is the shell's question (§19.1.1).
    var startWork: ((WorkPackage) -> Bool)?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            detail.frame(minWidth: 420, maxWidth: .infinity)
        }
        .task { await model.reload() }
        .onChange(of: model.selected?.id.rawValue) { _, _ in seedDraftIfNeeded(model.selected) }
        .onChange(of: model.projects.count) { _, _ in seedDraftIfNeeded(model.selected) }
        // Debounce: every edit restarts this, and only a pause commits. The
        // sleep is cancelled by the next keystroke, so a sentence is one write
        // rather than one write per character.
        .task(id: draft) {
            guard !draft.projectID.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await commitDraft()
        }
        .task(id: criteriaDrafts) {
            guard !criteriaDrafts.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            for package in model.wbs.packages { commitCriteria(for: package) }
        }
        .task(id: titleDrafts) {
            guard !titleDrafts.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            for package in model.wbs.packages { commitTitle(for: package) }
        }
    }

    // MARK: - list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localised: "Workspaces", "Sidebar heading over General and the project list.")
                .font(.headline)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)

            List {
                Section {
                    Button {
                        Task { await model.focus(.general) }
                    } label: {
                        Label(t("General — everyday conversation",
                                "Sidebar row: work outside any project. 'General' is that workspace's name."),
                              systemImage: "bubble.left")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .fontWeight(model.selection == .general ? .semibold : .regular)
                }

                Section(t("Projects", "Sidebar section over the list of projects.")) {
                    ForEach(model.projects) { project in
                        Button {
                            Task { await model.open(project) }
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
                        .accessibilityLabel(t("Open project \(project.name), stage \(project.stage.label)",
                                              "Screen-reader label for a project row. Placeholders: its name and its stage."))
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                TextField(t("New project name", "Text field for creating a project."), text: $newName)
                    // A placeholder is not a label: it disappears the moment
                    // somebody types, and VoiceOver announced this as an
                    // unnamed text field (measured with the driver, E.30).
                    .accessibilityLabel(t("New project name", "Screen-reader label for the new-project name field."))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker(t("Type", "Picker: which kind of project this is."), selection: $newType) {
                        ForEach(types) { type in
                            Text(type.label).tag(String?.some(type.type))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(t("Type of the new project", "Screen-reader label for the project type picker."))
                    Button(t("Create", "Button that creates the project.")) {
                        guard let chosen = types.first(where: { $0.type == newType })
                            ?? types.first else { return }
                        let name = newName
                        newName = ""
                        Task { await model.create(name: name, type: chosen) }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || types.isEmpty)
                }
                if let chosen = types.first(where: { $0.type == newType }) {
                    // What choosing this type will actually do, before it is
                    // chosen. A picker whose options only differ in a word is a
                    // picker people pick the first item of.
                    Text(chosen.description).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if types.isEmpty {
                    Text(localised: "Project types could not be loaded — see System → System status for the message",
                         "Shown when the project-type files failed to load, pointing at where the reason is.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(Space.box)
            .task(id: types.count) {
                if newType == nil { newType = types.first?.type }
            }
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
            .padding(Space.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General").font(.title3).bold()
            Text(localised: "Ask and give short instructions straight away. No team, no work record, no project stages. Anything learned along the way goes to the shared knowledge base.",
                 "Explains what the General workspace is, on the screen that lists workspaces.")
                .foregroundStyle(.secondary)
            Text(localised: "Work with a goal and an end date belongs in a project — there, tools that change data follow the project's stage",
                 "Says when to create a project instead of using General.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func projectDetail(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name).font(.title3).bold()
            HStack(spacing: 8) {
                Text(localised: "Stage \(project.stage.label)",
                     "Shows which stage a project is in. Placeholder is the stage name.")
                if let closure = project.closure {
                    Text("· \(closure.label)").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }

        stageStrip(project.stage)

        // The gate sits directly under the stage strip, not at the bottom of
        // the page. It is the only thing here that answers "what do I do
        // next", and driving the screen by hand showed it four sections down,
        // below everything it is supposed to be steering.
        if let gate = model.gate {
            gateBox(gate)
        } else {
            Text(localised: "The project is closed — readable, but tools that change data no longer run",
                 "Shown in place of the gate box for a closed project.")
                .font(.callout).foregroundStyle(.secondary)
        }

        if let pending = model.pendingEdit { changeRequestBar(pending) }

        Picker(t("Section of the plan", "Picker over the Plan area's sub-tabs."), selection: $tab) {
            ForEach(PlanTab.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(t("Choose a section of the plan", "Screen-reader label for the plan sub-tab picker."))

        if tab == .overview {
        GroupBox(t("Why this is being done", "Box heading over the project brief.")) {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $draft.brief)
                    .frame(minHeight: 60)
                    .font(.body)
                    .accessibilityLabel(t("Why this project is being done", "Screen-reader label for the brief editor."))
                savedHint
            }
        }

        // §19.5 — G1 asks for a person's name here, and until this field
        // existed the gate could never open from the app: the condition was
        // enforced, the type was there, and the screen had no door. That is
        // the fifth time this project has shipped something unreachable, and
        // the first time driving the screen caught it the same day.
        GroupBox(t("Seats a person holds", "Box heading over the roles that can never be given to an agent.")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(localised: "Business owner (Executive)",
                         "Row label. 'Executive' is the role name from the standard and stays as is.")
                        .font(.callout).frame(width: 220, alignment: .leading)
                    TextField(t("Person's name", "Text field for the business owner's name."), text: $draft.executive)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(t("Name of the business owner", "Screen-reader label."))
                }
                HStack {
                    Text(localised: "User representative (Senior User)",
                         "Row label. 'Senior User' is the role name from the standard and stays as is.")
                        .font(.callout).frame(width: 220, alignment: .leading)
                    TextField(t("Person's name (optional)", "Text field for the user representative's name."),
                              text: $draft.seniorUser)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(t("Name of the user representative", "Screen-reader label."))
                }
                Text(localised: "These seats always belong to a person — there is no way to hand one to an agent, however much you might want to",
                     "Note under the human-only roles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox(t("Scope", "Box heading over what the project will and will not do.")) {
            VStack(alignment: .leading, spacing: 10) {
                lineEditor(t("In", "Editor label: what the project will do."), text: $draft.inScope)
                lineEditor(t("Out", "Editor label: what the project will not do."), text: $draft.outOfScope)
                lineEditor(t("Acceptance criteria", "Editor label: what makes the work acceptable."),
                           text: $draft.acceptance)
                Text(localised: "One per line · “Out” may not be empty — a scope that never says what it will not do is a scope that grows every time",
                     "Note under the scope editors, explaining why the out-of-scope list is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        toleranceBox()

        baselineBox()
        }

        if tab == .plan {
            wbsBox(project)
            scheduleBox()
            timelineBox()
            projectionBox()
        }

        if tab == .board {
            kanbanBox()
            registerBox()
        }

        if tab == .team {
            raciBox(project)
            raciTableBox()
        }

        if tab == .closing {
            reportsBox()
            benefitsBox()
            conformanceBox()
            dispositionBox(project)
        }
    }

    // MARK: - reporting (§19.13)

    /// The three reports, and the last thing each one said. Issuing is a button
    /// rather than a schedule because a report on a timer that nobody reads is
    /// the thing status reporting usually degrades into — the cycle can come
    /// later; being able to produce one from real rows is the point.
    @ViewBuilder
    private func reportsBox() -> some View {
        GroupBox(t("Reports", "Box heading over progress reports.")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ForEach(ReportKind.allCases, id: \.self) { kind in
                        Button(kind.label) { issue(kind) }
                    }
                    Spacer()
                    // §19.13 / P10.13 — how often somebody wants telling. The
                    // cycle never issues anything itself: it says one is due,
                    // and the button above is what issues it, so nothing can
                    // arrive by a path that skips what manual issuing checks.
                    Picker(t("Issue automatically", "Picker: how often a progress report is issued on its own."),
                           selection: $model.reportCycle) {
                        ForEach(ReportSchedule.Cycle.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel(t("How often progress reports are issued automatically",
                                          "Screen-reader label for the report schedule picker."))
                }
                .controlSize(.small)

                if let due = model.reportDue {
                    HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                        Label(t("A progress report is due", "Shown when the schedule says a report should be issued."),
                              systemImage: "clock.badge")
                            .font(.callout).foregroundStyle(.orange)
                        Button(t("Issue now", "Button that writes the due progress report.")) { issue(.highlight) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    if let gap = due.gapNote {
                        // Three weeks away is one report and this sentence, not
                        // three reports: backfilled ones put numbers under
                        // dates nobody was working on.
                        Text(gap).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if model.reports.isEmpty {
                    Text(localised: "No reports yet — every line of a report is assembled from the plan, the register, spans, the baseline and the benefit ledger. None of it is text a model wrote.",
                         "Shown when no report has been issued, and states where report content comes from.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.reports) { report in
                    DisclosureGroup {
                        Text(report.rendered)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(localised: "\(report.kind.label) · stage \(report.stageAtIssue.label) · \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))",
                             "A report row. Placeholders: the kind of report, the stage it was issued in, and when.")
                            .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func issue(_ kind: ReportKind) {
        Task {
            // A report is also something to tell people about, on whatever
            // channel they are on (§19.13, §8.2) — the same text that is in the
            // file, not a summary of it.
            if let text = await model.issueReport(kind) { await announce(text) }
        }
    }

    // MARK: - benefits, conformance and closing (§19.12, §19.16)

    /// The benefit ledger. Deliberately editable after the project closes: the
    /// review date is usually months out, and a system that requires reopening a
    /// project to record what it achieved gets the review skipped.
    @ViewBuilder
    private func benefitsBox() -> some View {
        GroupBox(t("Benefits", "Box heading over what the project is meant to achieve, measured.")) {
            VStack(alignment: .leading, spacing: 8) {
                if model.benefits.isEmpty {
                    Text(localised: "Nothing listed yet — a project can deliver every work package and still achieve nothing, if nobody wrote down what was wanted",
                         "Shown when the benefit ledger is empty.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.benefits.benefits) { benefit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(benefit.title).font(.callout)
                            Spacer()
                            if let achieved = benefit.achievement {
                                Text(localised: "\(Int(achieved * 100))% of target",
                                     "How much of a benefit's target has been reached. Placeholder is a percentage.")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(achieved >= 1 ? Color.green : Color.orange)
                            } else {
                                Text(benefit.isDue()
                                     ? t("due to be measured", "Benefit status: the review date has arrived.")
                                     : t("not due to be measured yet", "Benefit status: the review date is still ahead."))
                                    .font(.caption)
                                    .foregroundStyle(benefit.isDue() ? Color.orange : Color.secondary)
                            }
                            Button(t("Delete", "Button that removes a benefit from the ledger.")) {
                                Task { await model.removeBenefit(benefit) }
                            }
                                .controlSize(.small)
                        }
                        Text(localised: "\(benefit.measure) · from \(format(benefit.baselineValue)) → \(format(benefit.target)) · measured by \(benefit.owner.label) · due \(benefit.reviewAt.formatted(date: .abbreviated, time: .omitted))",
                             "A benefit's definition. Placeholders: what is measured, the baseline value, the target, who measures it, and when it is due.")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let result = benefit.result {
                            Text(localised: "measured \(format(result.value)) by \(result.measuredBy)\(result.note.isEmpty ? "" : " — \(result.note)")",
                                 "A recorded benefit measurement. Placeholders: the value, who measured it, and an optional note.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                TextField(t("Measured value", "Text field for recording what a benefit measured."),
                                          text: Binding(
                                    get: { measurements[benefit.id] ?? "" },
                                    set: { measurements[benefit.id] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                                TextField(t("Name of who measured it", "Text field beside a benefit measurement."),
                                          text: $decider)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)
                                Button(t("Record", "Button that saves a benefit measurement.")) {
                                    recordMeasurement(benefit)
                                }
                                    .disabled(Double(measurements[benefit.id] ?? "") == nil
                                              || decider.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField(t("Benefit wanted", "Text field naming a new benefit."), text: $benefitDraft.title)
                            .textFieldStyle(.roundedBorder)
                        TextField(t("Measure + unit", "Text field: what is measured and in what unit."),
                                  text: $benefitDraft.measure)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        TextField(t("Baseline today", "Text field: the value before the project."),
                                  text: $benefitDraft.baseline)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 110)
                        TextField(t("Target value", "Text field: the value being aimed at."),
                                  text: $benefitDraft.target)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 110)
                        DatePicker(t("Measure on", "Date picker: when the benefit is reviewed."),
                                   selection: $benefitDraft.reviewAt,
                                   displayedComponents: .date)
                            .labelsHidden()
                        TextField(t("Who measures it", "Text field: who is responsible for the measurement."),
                                  text: $benefitDraft.owner)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 130)
                        Button(t("Add", "Button that adds the benefit to the ledger.")) { addBenefit() }
                            .disabled(!benefitDraft.isReady)
                    }
                    Text(localised: "A baseline is required, because “better” with no starting point cannot be checked afterwards · a target below the baseline is fine (reducing time, say) — the direction is worked out for you",
                     "Note under the new-benefit fields, explaining why a baseline is mandatory.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The conformance matrix, and the one thing that makes it worth reading:
    /// every green row names what it counted, and a row satisfied by a decision
    /// not to do the practice looks different from one satisfied by doing it.
    @ViewBuilder
    private func conformanceBox() -> some View {
        let gaps = model.conformance.filter { !$0.satisfied }
        GroupBox(t("Conformance to the standard (ISO 21502 · 17 practices)",
                   "Box heading over the conformance matrix. The standard's name and number stay as they are.")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.conformance) { status in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: status.satisfied
                              ? (status.isTailored ? "minus.circle" : "checkmark.circle.fill")
                              : "exclamationmark.circle")
                            .foregroundStyle(status.satisfied
                                             ? (status.isTailored ? Color.secondary : Color.green)
                                             : Color.orange)
                        Text(status.practice.label)
                            .font(.callout).frame(width: 180, alignment: .leading)
                        if let evidence = status.evidence {
                            Text(evidence).font(.caption).foregroundStyle(.secondary)
                        } else if let record = status.tailoring {
                            Text(localised: "not done: \(record.reason) — decided by \(record.decidedBy)",
                                 "A conformance row satisfied by a recorded decision not to do the practice. Placeholders: the reason and who decided.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(localised: "neither evidence nor a decision not to do it",
                                 "A conformance row with nothing behind it either way.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                if !gaps.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localised: "Record which practice is not being done, and why — a project cannot close while any of them is unanswered",
                             "Instruction above the tailoring fields.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(gaps) { status in
                            HStack {
                                Text(status.practice.label)
                                    .font(.callout).frame(width: 180, alignment: .leading)
                                TextField(t("Reason for not doing it", "Text field: why a practice is being skipped."),
                                          text: $tailoringReason)
                                    .textFieldStyle(.roundedBorder)
                                TextField(t("Name of who decided", "Text field beside a decision that must carry a person's name."),
                                          text: $decider)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                                Button(t("Record", "Button that saves the decision not to do a practice.")) {
                                    tailor(status.practice)
                                }
                                    .disabled(tailoringReason.trimmingCharacters(in: .whitespaces).isEmpty
                                              || decider.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func dispositionBox(_ project: Project) -> some View {
        GroupBox(t("Data and files left behind", "Box heading over what happens to the project's data when it closes.")) {
            VStack(alignment: .leading, spacing: 6) {
                if let decided = project.dataDisposition, decided.isDecided {
                    Text(localised: "\(decided.action.label) · under policy “\(decided.policy)” · decided by \(decided.decidedBy)",
                         "A recorded data-disposition decision. Placeholders: the action, the policy it followed, and who decided.")
                        .font(.callout)
                } else {
                    Text(localised: "Not decided yet — this is the eighth condition for closing the project",
                         "Shown when nobody has said what happens to the data.")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Picker(t("What happens to what is left", "Picker over data-disposition actions."),
                           selection: $dispositionAction) {
                        ForEach(DataDisposition.Action.allCases, id: \.self) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    .labelsHidden()
                    TextField(t("Policy applied", "Text field: which policy the disposition follows."),
                              text: $dispositionPolicy)
                        .textFieldStyle(.roundedBorder)
                    TextField(t("Name of who decided", "Text field beside a decision that must carry a person's name."),
                              text: $decider)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                    Button(t("Record", "Button that saves the data-disposition decision.")) {
                        decideDisposition()
                    }
                        .disabled(dispositionPolicy.trimmingCharacters(in: .whitespaces).isEmpty
                                  || decider.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
                Text(localised: "The decision is recorded; no file is deleted for you — deleting somebody else's data cannot be undone",
                     "Note under the disposition control, saying plainly what the app will and will not do.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addBenefit() {
        let draft = benefitDraft
        benefitDraft = BenefitDraft()
        Task {
            await model.addBenefit(title: draft.title, measure: draft.measure,
                                   baselineValue: Double(draft.baseline) ?? 0,
                                   target: Double(draft.target) ?? 0,
                                   reviewAt: draft.reviewAt, owner: draft.owner)
        }
    }

    private func recordMeasurement(_ benefit: Benefit) {
        guard let value = Double(measurements[benefit.id] ?? "") else { return }
        let person = decider
        measurements[benefit.id] = nil
        Task { await model.measure(benefit, value: value, by: person) }
    }

    private func tailor(_ practice: Practice) {
        let reason = tailoringReason
        let person = decider
        tailoringReason = ""
        Task { await model.tailor(practice, reason: reason, by: person) }
    }

    private func decideDisposition() {
        let policy = dispositionPolicy
        let person = decider
        let action = dispositionAction
        Task { await model.decideDisposition(action: action, policy: policy, by: person) }
    }

    // MARK: - editing an agreed plan (§19.2.4, P10.16)

    /// The bar §19.2.4 asks for: not a block and not a warning afterwards, but
    /// the consequence stated where the hand already is, with two buttons.
    @ViewBuilder
    private func changeRequestBar(_ proposal: PlanChangeProposal) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(proposal.title).font(.callout).bold()
                Text(proposal.headline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(localised: "Difference from the baseline after this edit: \(proposal.driftAfter)",
                     "States the drift the pending edit would create. Placeholder summarises it.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(t("Confirm and open a change request",
                             "Button that applies the edit and files the change request it requires.")) {
                        Task { await model.confirmPendingEdit() }
                    }
                        .keyboardShortcut(.defaultAction)
                    Button(t("Cancel", "Button that abandons the pending plan edit.")) { model.cancelPendingEdit() }
                    Spacer()
                    Text(localised: "The next gate stays shut until somebody decides this request",
                         "States the consequence of filing a change request, where the hand already is.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(t("This plan has been agreed — editing it becomes a change request",
                    "Heading of the bar shown when editing a baselined plan."),
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("Change request awaiting confirmation: \(proposal.headline)",
                              "Screen-reader label for the change-request bar. Placeholder summarises the change."))
    }

    /// §21.1 layer 3 / P12.8 — what each role has actually been able to do.
    ///
    /// Beside RACI because that is where somebody decides who to give work to,
    /// and this is the only place in the app that answers "have they done this
    /// kind of thing before". A tool used fewer than five times shows no
    /// percentage: one call out of one is 100%, and a panel that prints that
    /// teaches people either to trust it wrongly or to stop reading it.
    @ViewBuilder private var proficiencyPanel: some View {
        if !model.proficiency.isEmpty {
            DisclosureGroup(t("Each role's proficiency with the tools",
                              "Collapsed panel beside RACI: what each role has actually been able to do.")) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Role.allCases, id: \.self) { role in
                        let rows = model.proficiency(for: role)
                        if !rows.isEmpty {
                            Text(role.rawValue).font(.caption).fontWeight(.medium)
                            ForEach(rows, id: \.tool) { row in
                                Text("· \(row.tool) — \(row.summary)")
                                    .font(.caption2)
                                    .foregroundStyle(row.isTooFewToJudge ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    // The threshold from the type, not a number typed again
                    // here: two copies of it drift, and the caption is the only
                    // place a reader learns why some rows have no percentage.
                    Text(localised: "Counted across projects · a call a rule stopped is not held against the role, and a tool used fewer than \(ToolProficiency.leastMeaningfulSample) times shows no percentage, because 1 out of 1 is 100% and says nothing",
                         "Caption under the proficiency panel. Placeholder is the smallest sample the panel will put a percentage on.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }

    // MARK: - order, board and RACI (§19.7–§19.9)

    /// Not a Gantt, and it says so. §19.7: the horizontal axis of a real Gantt
    /// is calendar time. The spans now carry a work package *and* a duration —
    /// `SurrealSpanSink.assignments(project:)` returns the rows a bar would be
    /// drawn from — so what stands between this and a calendar axis is no longer
    /// missing data. It is one unanswered question: a leaf touched on Monday and
    /// again on Thursday did not take four days, and a bar spanning them says it
    /// did (P10.9). What *is* true today is the order, which chain decides the
    /// end, and how long each leaf has actually cost.
    @ViewBuilder
    private func scheduleBox() -> some View {
        let ordered = Schedule.order(model.wbs)
        let paths = Schedule.criticalPaths(model.wbs)
        let critical = Set(paths.flatMap { $0 })
        let ready = Set(Schedule.ready(model.wbs).map(\.id))

        GroupBox(t("Order of work and the critical path",
                   "Box heading over the sequence view. Deliberately not called a Gantt.")) {
            VStack(alignment: .leading, spacing: 6) {
                // §19.2.4, said out loud rather than only enforced by the absence
                // of a gesture: the end date is a result, so there is nothing here
                // to drag. Wanting it sooner means changing what it depends on.
                Text(localised: "These bars cannot be dragged, on purpose — the end date is a result of the order and the real pace, not a value you set · to finish sooner, change what it depends on: cut scope, remove a dependency, or move to a different tier",
                     "Explains why the sequence view has no drag gesture. 'tier' is a term of art in this app.")
                    .font(.caption2).foregroundStyle(.secondary)
                if ordered.isEmpty {
                    Text(localised: "No work packages yet", "Shown when the plan is empty.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, package in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 22, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            // The bar is position in the order, not duration.
                            // Drawing a length here would be drawing a number
                            // nobody measured.
                            RoundedRectangle(cornerRadius: Radius.control)
                                .fill(critical.contains(package.id)
                                      ? Color.accentColor : Color.secondary.opacity(0.35))
                                .frame(width: 26, height: 12)
                                .padding(.leading, CGFloat(index) * 14)
                            Text(package.title).font(.callout)
                            if let seconds = model.elapsed[package.id], seconds > 0 {
                                // Measured, not estimated — this is time that
                                // actually happened against this leaf.
                                Text(formatDuration(seconds))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if critical.contains(package.id) {
                                Text(localised: "critical path",
                                     "Tag on a work package that sits on the chain deciding the end date.")
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                            if ready.contains(package.id) {
                                Text(localised: "ready to start",
                                     "Tag on a work package whose dependencies are all finished.")
                                    .font(.caption2).foregroundStyle(.green)
                            }
                            Spacer()
                            dependencyPicker(package)
                        }
                    }
                    if paths.isEmpty {
                        Text(localised: "No dependencies yet — every package could start at once, so no chain decides the end",
                             "Shown when there is no critical path because nothing depends on anything.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if paths.count > 1 {
                        Text(localised: "\(paths.count) chains are equally long — a delay on any of them delays the project",
                             "Shown when several critical paths tie. Placeholder is how many.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(localised: "The horizontal axis here is order, not time — the real time axis is in the next box",
                     "Says plainly what this view's axis means, so it is not read as a Gantt chart.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where the work that has not started would land (§19.7, P10.9's third
    /// axis).
    ///
    /// Kept out of the calendar chart above rather than drawn onto it, and
    /// that is the point: what happened and what might happen are different
    /// kinds of claim, and a picture that puts them on one axis in one style
    /// invites somebody to read a forecast as a record. Every row here is a
    /// range, never a date.
    @ViewBuilder
    private func projectionBox() -> some View {
        if let projection = model.projection,
           !(projection.leaves.isEmpty && projection.unforecastable.isEmpty) {
            GroupBox(t("Work not started — if it started now",
                       "Box heading over the forecast for unstarted work.")) {
                VStack(alignment: .leading, spacing: Space.row) {
                    Text(localised: "p50–p90 ranges from work that really finished in this system, not dates somebody set · work already under way is not here, because the real thing is already measured on the time axis above",
                         "Caption over the forecast rows, saying where the ranges come from.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(projection.leaves) { row in
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Text(row.title).font(.callout).lineLimit(1)
                            Spacer(minLength: Space.row)
                            Text(dayRange(row.p50Finish, row.p90Finish))
                                .font(.system(.caption, design: .monospaced))
                            Text(localised: "from \(row.sampleCount) tasks",
                                 "Names the sample a forecast row was computed from. Placeholder is a count.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(t("\(row.title) would likely finish between \(dayRange(row.p50Finish, row.p90Finish))",
                                              "Screen-reader label for a forecast row. Placeholders: the package title and a date range."))
                    }

                    if let finish = projection.p90Finish, !projection.leaves.isEmpty {
                        Text(localised: "If everything runs in this order, the work that can be estimated finishes around \(finish.formatted(date: .abbreviated, time: .omitted)) (the p90 edge)",
                             "Summary line under the forecast rows. Placeholder is a date.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    // Named, not omitted: a list that quietly drops what it
                    // cannot forecast reads as a list of all the work.
                    ForEach(projection.unforecastable, id: \.packageID) { row in
                        Label("\(row.title) — \(row.reason)", systemImage: "questionmark.circle")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func dayRange(_ p50: Date, _ p90: Date) -> String {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        return "\(p50.formatted(format)) – \(p90.formatted(format))"
    }

    /// The schedule on a calendar axis (§19.7, P10.9) — the thing four plan
    /// items said could not be drawn honestly.
    ///
    /// A row is one mark per piece of work, and **a gap stays a gap**. The
    /// obvious drawing — one bar per leaf from first touch to last — reads as
    /// four days of work when a leaf was touched on Monday and again on
    /// Thursday, and shading it to show that only forty minutes was real does
    /// not help: the eye reads the rectangle, not the fill.
    @ViewBuilder
    private func timelineBox() -> some View {
        if let timeline = model.timeline {
            GroupBox(t("Real time axis — work that actually happened, on a calendar",
                       "Box heading over the timeline of recorded work.")) {
                VStack(alignment: .leading, spacing: 6) {
                    if timeline.isEmpty {
                        Text(localised: "No work with recorded time in this project yet — marks appear on their own once work finishes",
                             "Shown when the timeline has nothing to draw.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(localised: "\(axisLabel(timeline)) · each mark is one piece of work that really happened **a gap between marks is time nobody spent on this** — not work that dragged on",
                             "Caption over the timeline. Placeholder is the span the axis covers. The bold half is the thing the picture is most often misread as.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(timeline.rows) { row in
                            timelineRow(row)
                        }
                        if model.timelineBeyondLimit > 0 {
                            Text(localised: "\(model.timelineBeyondLimit) older pieces are not drawn — so this picture is not the whole history",
                                 "Says what the timeline left out. Placeholder is how many.")
                                .font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(localised: "Faded marks are work that failed or was cancelled — it really took time, so it stays on the axis",
                             "Legend under the timeline.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func timelineRow(_ row: ScheduleTimeline.Row) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.callout).lineLimit(1)
                if row.hasStarted {
                    Text(localised: "worked \(formatDuration(row.workedSeconds))",
                         "How much real time a timeline row cost. Placeholder is a duration.")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(localised: "not started", "Timeline row for work nothing has been recorded against.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.08)).frame(height: 12)
                    ForEach(row.segments) { segment in
                        // The clamp that keeps a forty-second job visible lives
                        // here and not in `ScheduleTimeline`: it is a fact about
                        // pixels, and in the model every number computed
                        // downstream would inherit it.
                        let width = max(3, (segment.to - segment.from) * geometry.size.width)
                        RoundedRectangle(cornerRadius: Radius.control)
                            .fill(segment.succeeded
                                  ? Color.accentColor
                                  : Color.secondary.opacity(0.45))
                            .frame(width: width, height: 12)
                            .offset(x: segment.from * geometry.size.width)
                    }
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            .accessibilityElement()
            .accessibilityLabel(rowSpokenLabel(row))
        }
        .padding(.vertical, 1)
        .overlay(alignment: .bottomLeading) {
            if let note = row.gapNote {
                Text(note).font(.caption2).foregroundStyle(.orange)
                    .offset(y: 10)
            }
        }
        .padding(.bottom, row.gapNote == nil ? 0 : 12)
    }

    /// A chart is not readable by a screen reader, so the row says in words what
    /// the marks say in pixels — including the gap, which is the whole point.
    private func rowSpokenLabel(_ row: ScheduleTimeline.Row) -> String {
        guard row.hasStarted else {
            return t("\(row.title) — not started",
                     "Screen-reader label for a timeline row with no recorded work. Placeholder is the title.")
        }
        let base = t("\(row.title) — \(row.segments.count) stretches of work, \(formatDuration(row.workedSeconds)) of real time in total",
                     "Screen-reader label for a timeline row. Placeholders: the title, how many stretches, and the total duration.")
        guard let note = row.gapNote else { return base }
        return base + " · " + note
    }

    private func axisLabel(_ timeline: ScheduleTimeline) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return "\(formatter.string(from: timeline.start)) – \(formatter.string(from: timeline.end))"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        seconds < 90
            ? t("\(Int(seconds)) s", "A short duration in seconds. Placeholder is a whole number.")
            : t("\(Int(seconds / 60)) min", "A duration in minutes. Placeholder is a whole number.")
    }

    private func dependencyPicker(_ package: WorkPackage) -> some View {
        Menu {
            ForEach(model.wbs.leaves.filter { $0.id != package.id }) { other in
                Button {
                    var next = package
                    if let index = next.dependsOn.firstIndex(of: other.id) {
                        next.dependsOn.remove(at: index)
                    } else {
                        next.dependsOn.append(other.id)
                    }
                    Task { await model.update(next) }
                } label: {
                    Label(other.title,
                          systemImage: package.dependsOn.contains(other.id) ? "checkmark" : "")
                }
            }
        } label: {
            Text(package.dependsOn.isEmpty
                 ? t("waits on: —", "Dependency picker label when a package waits on nothing.")
                 : t("waits on \(package.dependsOn.count)",
                     "Dependency picker label. Placeholder is how many packages it waits on."))
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(t("Choose the packages \(package.title) must wait for",
                              "Screen-reader label for the dependency picker. Placeholder is the package title."))
    }

    /// §19.8 — the columns are the ledger's statuses, and the WIP limit is the
    /// fan-out cap that already exists in config rather than a second number.
    @ViewBuilder
    private func kanbanBox() -> some View {
        GroupBox(t("Board", "Box heading over work packages arranged as a kanban board.")) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(WorkPackageStatus.allCases, id: \.self) { status in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(status.label).font(.caption).bold()
                                Spacer()
                                Text("\(model.wbs.leaves.count { $0.status == status })")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            ForEach(model.wbs.leaves.filter { $0.status == status }) { package in
                                cardView(package)
                                    // The id travels, not the card: a drop has
                                    // to go through `move`, which is where the
                                    // evidence rule lives (§19.15 invariant 4).
                                    .draggable(package.id)
                            }
                            // The whole column is the target, including the
                            // empty space under the last card — a column you
                            // can only drop *onto a card* is a column you
                            // cannot move the first card into.
                            Color.clear.frame(height: 24)
                        }
                        .frame(width: 190, alignment: .leading)
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first,
                                  let package = model.wbs.leaves.first(where: { $0.id == id })
                            else { return false }
                            // Same call the menu makes. A drop that took a
                            // shortcut past it would be a way to mark work done
                            // without the evidence, which is the one thing this
                            // board must not become.
                            move(package, to: status)
                            return true
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func cardView(_ package: WorkPackage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(package.title).font(.caption)
            HStack(spacing: 4) {
                if let role = package.role {
                    Text(role.rawValue).font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if !package.evidence.isEmpty {
                    Text(localised: "evidence \(package.evidence.count)",
                         "Count of evidence items on a board card. Placeholder is how many.")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Menu(t("Move", "Menu on a board card for moving it to another column.")) {
                ForEach(WorkPackageStatus.allCases, id: \.self) { target in
                    Button(target.label) { move(package, to: target) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.caption2)
            .accessibilityLabel(t("Move work package \(package.title)",
                                  "Screen-reader label for the move menu. Placeholder is the package title."))
        }
        .padding(Space.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Radius.box))
        .overlay(RoundedRectangle(cornerRadius: Radius.box).stroke(.quaternary))
    }

    /// Moving a card is not a way around the evidence rule (§19.15 invariant
    /// 4): "done" goes through the same refusal an agent gets.
    private func move(_ package: WorkPackage, to status: WorkPackageStatus) {
        guard status == .done else {
            var next = package
            next.status = status
            Task { await model.update(next) }
            return
        }
        Task { await model.complete(package.id, evidence: package.evidence) }
    }

    /// The RACI as a table (§19.9, P10.9).
    ///
    /// The editor above is per package, and the questions this table exists
    /// for are questions across rows: who is responsible for everything, who is
    /// on the project and carries nothing, which package is accountable to
    /// somebody and assigned to nobody. None of them can be seen one package
    /// at a time.
    @ViewBuilder
    private func raciTableBox() -> some View {
        let matrix = RACIMatrix.build(model.wbs)
        if !matrix.rows.isEmpty && !matrix.actors.isEmpty {
            GroupBox(t("RACI across the whole project",
                       "Box heading over the responsibility matrix. RACI is the standard's term and stays as is.")) {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: Space.box,
                         verticalSpacing: Space.tight) {
                        GridRow {
                            Text(localised: "Work package", "Column heading in the RACI matrix.")
                                .font(.caption.weight(.semibold))
                            ForEach(Array(matrix.actors.enumerated()), id: \.offset) { _, actor in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(actor.label).font(.caption.weight(.semibold))
                                    // The bottleneck, counted rather than
                                    // squinted at down a column.
                                    Text("R×\(matrix.responsibleCount(for: actor))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Divider()
                        ForEach(matrix.rows) { row in
                            GridRow {
                                HStack(spacing: Space.tight) {
                                    Text(row.title).font(.callout).lineLimit(1)
                                    if row.isUnassigned {
                                        Text(localised: "nobody", "RACI cell with no role assigned.")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                ForEach(Array(row.cells.enumerated()), id: \.offset) { _, letters in
                                    // Every letter that applies, not the
                                    // strongest one: somebody who is both A
                                    // and C on a package is what a reader of
                                    // this table is looking for.
                                    Text(letters.map(\.rawValue).joined(separator: ""))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(letters.contains(.accountable)
                                                         ? Color.primary : .secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(spokenRow(row, actors: matrix.actors))
                        }
                    }
                    .padding(.vertical, Space.tight)
                }
                if !matrix.uninvolved.isEmpty {
                    Text(localised: "In the project but holding no letter at all: \(matrix.uninvolved.map(\.label).joined(separator: ", "))",
                         "Names roles that appear in the project with no RACI letter. Placeholder is the list of them.")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A grid read left to right by a screen reader is a list of letters, so
    /// the row is spoken as sentences instead.
    private func spokenRow(_ row: RACIMatrix.Row, actors: [RACIActor]) -> String {
        let parts = zip(actors, row.cells).compactMap { actor, letters -> String? in
            letters.isEmpty ? nil : "\(actor.label) \(letters.map(\.rawValue).joined(separator: " "))"
        }
        return "\(row.title): " + (parts.isEmpty
                                  ? t("nobody assigned yet", "Screen-reader text for a RACI row with no assignments.")
                                  : parts.joined(separator: " · "))
    }

    /// §19.9 — one accountable per package, and the screen cannot express two.
    @ViewBuilder
    private func raciBox(_ project: Project) -> some View {
        GroupBox(t("Team & RACI", "Box heading over per-package accountability.")) {
            VStack(alignment: .leading, spacing: 8) {
                proficiencyPanel
                if model.wbs.leaves.isEmpty {
                    Text(localised: "No work packages to assign yet", "Shown when the plan has nothing to give anyone.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.wbs.leaves) { package in
                    HStack(spacing: 8) {
                        Text(package.title).font(.callout).frame(width: 220, alignment: .leading)
                        Picker("A", selection: accountableBinding(package, project: project)) {
                            Text(localised: "— none yet —", "Picker option: nobody is accountable yet.")
                                .tag(Accountable?.none)
                            Text(localised: "Team lead", "Picker option: the team lead is accountable.")
                                .tag(Accountable?.some(.teamLead))
                            if let person = project.executive?.person, !person.isEmpty {
                                Text(person).tag(Accountable?.some(.human(person)))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityLabel(t("Accountable for the outcome of \(package.title)",
                                              "Screen-reader label for the accountable picker. Placeholder is the package title."))
                        if package.riskClass >= .high, package.raci?.accountable.isHuman != true {
                            Text(localised: "High-risk work needs a person accountable",
                                 "Shown beside a high-risk package with no accountable person.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                }
                Divider()
                // R/C/I, which P10.5 left for later. Toggles rather than text:
                // the set of people and agents a project has is known, and a
                // free-text field here is how "analist" and "analyst" end up
                // being two different people in the same table.
                ForEach(model.wbs.leaves) { package in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(package.title).font(.caption).foregroundStyle(.secondary)
                        ForEach(RACILetter.allCases, id: \.self) { letter in
                            HStack(spacing: 4) {
                                Text(letter.label)
                                    .font(.caption2).frame(width: 96, alignment: .leading)
                                ForEach(raciCandidates(project), id: \.self) { actor in
                                    Toggle(actor.label, isOn: raciBinding(package, letter: letter,
                                                                         actor: actor))
                                        .toggleStyle(.button)
                                        .controlSize(.mini)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }

                Text(localised: "There is exactly one A per work package — so this is a single choice, not a set of checkboxes · R/C/I may be lists",
                     "Explains why the accountable control differs from the others. A, R, C and I are the RACI letters.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func accountableBinding(_ package: WorkPackage,
                                    project: Project) -> Binding<Accountable?> {
        Binding(get: { package.raci?.accountable },
                set: { chosen in
                    var next = package
                    if let chosen {
                        var raci = next.raci ?? RACI(accountable: chosen)
                        raci.accountable = chosen
                        if let role = next.role, raci.responsible.isEmpty {
                            raci.responsible = [.agent(role)]
                        }
                        next.raci = raci
                    } else {
                        next.raci = nil
                    }
                    Task { await model.update(next) }
                })
    }

    /// The three letters that are lists. `A` is not here on purpose — it is a
    /// single value in the type system (§19.9), and offering it as a toggle row
    /// would be offering a state that cannot be saved.
    enum RACILetter: String, CaseIterable {
        case responsible, consulted, informed
        var label: String {
            switch self {
            case .responsible: t("R does the work", "RACI letter R, with what it means.")
            case .consulted: t("C is consulted", "RACI letter C, with what it means.")
            case .informed: t("I is kept informed", "RACI letter I, with what it means.")
            }
        }
    }

    /// Who can appear in an R/C/I cell: every role the team has, plus the people
    /// who already hold a seat. Not a text field — see the comment at the call site.
    private func raciCandidates(_ project: Project) -> [RACIActor] {
        Role.allCases.map { RACIActor.agent($0) }
            + project.board.map(\.person)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { RACIActor.human($0) }
    }

    private func raciBinding(_ package: WorkPackage, letter: RACILetter,
                             actor: RACIActor) -> Binding<Bool> {
        func list(_ raci: RACI?) -> [RACIActor] {
            switch letter {
            case .responsible: raci?.responsible ?? []
            case .consulted: raci?.consulted ?? []
            case .informed: raci?.informed ?? []
            }
        }
        return Binding(
            get: { list(package.raci).contains(actor) },
            set: { on in
                // A leaf with no A yet cannot carry an R either, because `RACI`
                // has no state without an accountable — so the row says what is
                // missing instead of dropping the tap.
                guard var raci = package.raci else { return }
                var current = list(raci)
                if on {
                    guard !current.contains(actor) else { return }
                    current.append(actor)
                } else {
                    current.removeAll { $0 == actor }
                }
                switch letter {
                case .responsible: raci.responsible = current
                case .consulted: raci.consulted = current
                case .informed: raci.informed = current
                }
                var next = package
                next.raci = raci
                Task { await model.update(next) }
            })
    }

    // MARK: - registers and baselines (§19.11)

    @ViewBuilder
    private func registerBox() -> some View {
        GroupBox(t("Register", "Box heading over risks, issues, decisions and change requests.")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.registers) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.kind.label)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(entry.title).font(.callout)
                            Spacer()
                            Text(entry.status.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(localised: "raised by \(entry.origin.label)\(entry.decidedBy.map { t(" · decided by \($0)", "Appended to a register row once somebody has decided it. Placeholder is their name.") } ?? "")",
                             "A register row's provenance. Placeholders: who raised it, and optionally who decided it.")
                            .font(.caption2).foregroundStyle(.secondary)

                        // Only a change is decided, and only by a person.
                        if entry.kind == .change, entry.status == .proposed {
                            HStack {
                                TextField(t("Name of the decider", "Text field beside approve/reject on a register entry."),
                                          text: $decider)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)
                                Button(t("Approve", "Button that approves a register entry.")) {
                                    decide(entry, approve: true)
                                }
                                Button(t("Reject", "Button that rejects a register entry.")) {
                                    decide(entry, approve: false)
                                }
                            }
                            .controlSize(.small)
                            .disabled(decider.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                if model.registers.isEmpty {
                    Text(localised: "Nothing recorded yet", "Shown when the register is empty.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    TextField(t("Record a new entry", "Text field for adding to the register."), text: $registerTitle)
                        .textFieldStyle(.roundedBorder)
                    Picker(t("Kind", "Picker: which kind of register entry this is."), selection: $registerKind) {
                        ForEach(RegisterKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(t("Kind of entry being recorded", "Screen-reader label for the register kind picker."))
                    Button(t("Record", "Button that adds the entry to the register.")) { addRegister() }
                        .disabled(registerTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func baselineBox() -> some View {
        if !model.baselines.isEmpty {
            GroupBox(t("The agreed plan (baseline)",
                       "Box heading over frozen versions of the plan. 'baseline' is the standard's term.")) {
                VStack(alignment: .leading, spacing: 5) {
                    if let drift = model.drift {
                        Text(localised: "Against v\(model.baselines.first?.version ?? 1) today: \(drift.summary)",
                             "Current drift from the latest baseline. Placeholders: the version number and a summary.")
                            .font(.callout)
                            .foregroundStyle(drift.isEmpty ? Color.secondary : Color.orange)
                    }
                    ForEach(model.baselines) { baseline in
                        Text(localised: "v\(baseline.version) · \(baseline.reason) · \(baseline.packages.count) work packages",
                             "A baseline row. Placeholders: its version, why it was frozen, and how many packages it holds.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(localised: "Older versions stay readable — the number of them answers “how many times did the plan change”",
                         "Note under the baseline list.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func addRegister() {
        let title = registerTitle
        registerTitle = ""
        let detail: RegisterDetail = switch registerKind {
        case .risk: .risk(probability: 3, impact: 3, response: .reduce)
        case .issue: .issue(severity: 3, kind: .problem)
        case .change: .change(scopeImpact: "—", timeImpact: "—", costImpact: "—")
        case .decision: .decision(options: [], reversible: true)
        case .lesson: .lesson(cause: "", doDifferently: "", appliesTo: "")
        }
        Task { await model.record(detail, title: title) }
    }

    private func decide(_ entry: RegisterEntry, approve: Bool) {
        let person = decider
        Task { await model.decide(entry, approve: approve, by: person) }
    }

    // MARK: - tolerance (§19.10)

    @ViewBuilder
    private func toleranceBox() -> some View {
        GroupBox(t("How far the team may go on its own",
                   "Box heading over the tolerances that decide when work stops for a person.")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.tolerances) { status in
                    let measured = model.measured.contains(status.dimension)
                    let noTarget = status.dimension == .benefit && status.limit == 0
                    HStack(spacing: 8) {
                        Text(status.dimension.label)
                            .font(.callout)
                            .frame(width: 84, alignment: .leading)
                        // The frame as numbers, which is the whole point: a
                        // slider labelled "balanced" says nothing a person can
                        // check against what is happening. But a number the
                        // app is not actually reading is worse than no number,
                        // so an unwired dimension says that instead.
                        // The limit is typed; the current value is not (§19.2.4).
                        // One text field and one read-only number, side by side,
                        // is the clearest statement of that line this screen can
                        // make.
                        TextField(t("Limit", "Text field holding one tolerance's limit."), text: Binding(
                            get: { limitDrafts[status.dimension.rawValue] ?? format(status.limit) },
                            set: { limitDrafts[status.dimension.rawValue] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 70)
                            .accessibilityLabel(t("Limit for \(status.dimension.label), editable",
                                                  "Screen-reader label for a tolerance field. Placeholder is which tolerance."))
                            .onSubmit { commitLimit(status.dimension) }

                        if noTarget {
                            Text(localised: "no target set yet", "Tolerance row for benefits before a target exists.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if measured {
                            Text("\(format(status.current)) / \(format(status.limit))")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(status.breached ? Color.red : Color.primary)
                            ProgressView(value: min(status.fraction, 1))
                                .frame(maxWidth: 120)
                        } else {
                            Text(localised: "limit \(format(status.limit)) · not measured yet",
                                 "A tolerance that is enforced but has no source of data yet. Placeholder is the limit.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Text(status.dimension.unit)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel({
                        if noTarget {
                            t("Benefit tolerance, no target set yet", "Screen-reader label for the benefit tolerance row.")
                        } else if measured {
                            t("\(status.dimension.label) tolerance is at \(format(status.current)) of \(format(status.limit))\(status.breached ? " — breached" : "")",
                              "Screen-reader label for a measured tolerance. Placeholders: which tolerance, the current value, the limit, and whether it has been breached.")
                        } else {
                            t("\(status.dimension.label) tolerance is set to \(format(status.limit)) but nothing measures it yet",
                              "Screen-reader label for an enforced tolerance with no data. Placeholders: which tolerance and its limit.")
                        }
                    }())
                }

                Text(localised: "A row saying “not measured yet” still has a limit and still enforces it — it just has no source of data. Benefits become measurable once somebody records a result in the “Benefits & closing” tab.",
                     "Note under the tolerances, so an unmeasured row is not read as an inactive one.")
                    .font(.caption2).foregroundStyle(.secondary)

                HStack {
                    Text(localised: "Set them all at once", "Label before the tolerance presets.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(t("Ask me every step", "Tolerance preset: stop for a person at every step.")) {
                        Task { await model.setTolerances(.approvalRequired) }
                    }
                    Button(t("Balanced", "Tolerance preset: the middle setting.")) {
                        Task { await model.setTolerances(.balanced) }
                    }
                    Button(t("Fully autonomous", "Tolerance preset: let the team run without stopping.")) {
                        Task { await model.setTolerances(.fullAutonomous) }
                    }
                    Spacer()
                    Button(t("Check tolerances now", "Button that measures the tolerances immediately.")) {
                        checkTolerances()
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        ForEach(model.openExceptions) { report in
            GroupBox(t("\(report.dimension.label) tolerance breached — the project is waiting on you",
                       "Box heading over an open exception. Placeholder is which tolerance was breached.")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        TextField(t("Your decision", "Text field where a person settles a blocked exception."),
                                  text: $decision)
                            .textFieldStyle(.roundedBorder)
                        Button(t("Close the exception", "Button that records the decision and lets work resume.")) {
                            let text = decision
                            decision = ""
                            Task { await model.resolve(report, decision: text) }
                        }
                        .disabled(decision.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func commitLimit(_ dimension: ToleranceDimension) {
        guard let text = limitDrafts[dimension.rawValue] else { return }
        limitDrafts[dimension.rawValue] = nil
        // A field that will not parse leaves the frame alone. Silently reading it
        // as zero would set the strictest possible limit on the axis somebody was
        // trying to loosen.
        guard let limit = Double(text.trimmingCharacters(in: .whitespaces)) else {
            return
        }
        Task { await model.setTolerance(dimension, to: limit) }
    }

    private func checkTolerances() {
        Task {
            let messages = await model.checkTolerances()
            // Every channel, because an exception's whole purpose is to reach
            // the person wherever they are (§19.10).
            for message in messages { await announce(message) }
        }
    }

    // MARK: - work breakdown

    @ViewBuilder
    private func wbsBox(_ project: Project) -> some View {
        GroupBox(t("Work breakdown (WBS) — a leaf is something deliverable",
                   "Box heading over the work breakdown structure. WBS is the standard's term.")) {
            VStack(alignment: .leading, spacing: 8) {
                if model.wbs.isEmpty {
                    Text(localised: "No work packages yet — G2 needs at least one",
                         "Shown when the breakdown is empty. G2 is the name of the second gate.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.wbs.ordered) { package in
                        packageRow(package, project: project)
                            // P10.11 — order is the order somebody reads the
                            // plan in, and it could only be changed by
                            // deleting a package and adding it again at the
                            // end. Dropping onto a package with a different
                            // parent is refused in the model, not here: a drop
                            // that re-parented by accident would change what
                            // the plan says rather than the order it says it.
                            .draggable(package.id)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let moved = ids.first else { return false }
                                Task { await model.reorder(moved, toPositionOf: package.id) }
                                return true
                            }
                    }
                }

                HStack {
                    TextField(t("Add something deliverable", "Text field for adding a work package."),
                              text: $newPackageTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addPackage(under: selectedParent) }
                    Picker(t("Under", "Picker: which package the new one sits beneath."), selection: $selectedParent) {
                        Text(localised: "Top level", "Picker option: the new package has no parent.")
                            .tag(String?.none)
                        ForEach(model.wbs.ordered) { package in
                            Text(package.title).tag(String?.some(package.id))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(t("Choose the parent of the new work package", "Screen-reader label."))
                    Button(t("Add", "Button that creates the work package.")) { addPackage(under: selectedParent) }
                        .disabled(newPackageTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !model.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.problems) { problem in
                            Text("• " + problem.text)
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func packageRow(_ package: WorkPackage, project: Project) -> some View {
        let leaf = model.wbs.isLeaf(package)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(String(repeating: "   ", count: model.wbs.depth(of: package)))
                // The title is edited where it is read (§19.2.4). Buffered like
                // every other field on this screen, because a write per keystroke
                // is what ate Thai characters here before.
                TextField(t("Name of the deliverable", "Text field holding a work package's title."), text: Binding(
                    get: { titleDrafts[package.id] ?? package.title },
                    set: { titleDrafts[package.id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(leaf ? .callout : .callout.bold())
                    .accessibilityLabel(t("Title of work package \(package.title)",
                                          "Screen-reader label. Placeholder is the current title."))
                    .onSubmit { commitTitle(for: package) }
                Spacer()
                if leaf {
                    Text(package.status.label)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if leaf, let startWork {
                    // P10.4's missing half: the leaf could describe itself as
                    // an assignment and nothing could start one, so the plan
                    // and the team were joined by a field nobody could act on.
                    Button(t("Start this one", "Button that hands the package to the team as work.")) {
                        _ = startWork(package)
                    }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(package.acceptanceCriteria.isEmpty)
                        .help(package.acceptanceCriteria.isEmpty
                              ? t("A package with no acceptance criteria cannot be given to anyone — there is nothing to check it against",
                                  "Tooltip on a disabled start button.")
                              : t("Give this to the team, checking the criteria before it starts",
                                  "Tooltip on the start button."))
                        .accessibilityLabel(t("Start \(package.title) with the team",
                                              "Screen-reader label for the start button. Placeholder is the package title."))
                }
                Button {
                    Task { await model.removePackage(package.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(t("Delete work package \(package.title) and everything inside it",
                                      "Screen-reader label for the delete button. Placeholder is the package title."))
            }

            if leaf {
                HStack(spacing: 8) {
                    // What is handed over, and how much is at stake — both are
                    // things a person sets, and `riskClass` decides whether a
                    // human has to be accountable (§19.9), so it cannot stay a
                    // field only the tests can reach.
                    TextField(t("Delivered as what", "Text field: the kind of thing the package produces."),
                              text: Binding(
                        get: { package.deliverableType },
                        set: { value in
                            var next = package; next.deliverableType = value
                            Task { await model.update(next) }
                        }))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: 160)
                        .accessibilityLabel(t("Kind of deliverable for \(package.title)",
                                              "Screen-reader label. Placeholder is the package title."))

                    Picker(t("Risk", "Picker: how risky this package's work is."), selection: Binding(
                        get: { package.riskClass },
                        set: { level in
                            var next = package; next.riskClass = level
                            Task { await model.update(next) }
                        })) {
                        ForEach(RiskLevel.allCases, id: \.self) { level in
                            Text(riskLabel(level)).tag(level)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 110)
                    .accessibilityLabel(t("Risk level of \(package.title)",
                                          "Screen-reader label. Placeholder is the package title."))

                    Picker(t("Tied to scope", "Picker: which scope line this package delivers."),
                           selection: Binding(
                        get: { package.scopeRef },
                        set: { ref in
                            var next = package; next.scopeRef = ref
                            Task { await model.update(next) }
                        })) {
                        Text(localised: "— not tied —", "Picker option: this package is not tied to a scope line.")
                            .tag(String?.none)
                        ForEach(project.statement.inScope, id: \.self) { line in
                            Text(line).tag(String?.some(line))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(t("Tie work package \(package.title) to a scope line",
                                          "Screen-reader label. Placeholder is the package title."))

                    Picker(t("Role", "Picker: which role does this package."), selection: Binding(
                        get: { package.role },
                        set: { role in
                            var next = package; next.role = role
                            Task { await model.update(next) }
                        })) {
                        Text(localised: "— unassigned —", "Picker option: no role does this package yet.")
                            .tag(Role?.none)
                        ForEach(Role.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(Role?.some(role))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(t("Assign work package \(package.title)",
                                          "Screen-reader label. Placeholder is the package title."))
                }

                // Same buffer-and-commit as the project fields: writing on
                // every keystroke is what ate characters here too.
                TextField(t("What done means — separated by ·",
                            "Text field for the acceptance criteria of one package."),
                          text: Binding(
                            get: {
                                criteriaDrafts[package.id]
                                    ?? package.acceptanceCriteria.map(\.text).joined(separator: " · ")
                            },
                            set: { criteriaDrafts[package.id] = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .accessibilityLabel(t("Acceptance criteria of \(package.title)",
                                          "Screen-reader label. Placeholder is the package title."))
                    .onSubmit { commitCriteria(for: package) }

                // Dependencies, edited as "which of these must finish first"
                // rather than by dragging a line: §19.7 keeps only
                // finish-to-start, so there is nothing a line could express that
                // a toggle cannot — and the critical path below is computed from
                // exactly this list.
                let candidates = model.wbs.leaves.filter { $0.id != package.id }
                if !candidates.isEmpty {
                    HStack(spacing: 4) {
                        Text(localised: "Must finish first", "Heading over the packages this one waits for.")
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(candidates) { other in
                            Toggle(other.title, isOn: Binding(
                                get: { package.dependsOn.contains(other.id) },
                                set: { on in
                                    var next = package
                                    if on {
                                        guard !next.dependsOn.contains(other.id) else { return }
                                        next.dependsOn.append(other.id)
                                    } else {
                                        next.dependsOn.removeAll { $0 == other.id }
                                    }
                                    Task { await model.update(next) }
                                }))
                                .toggleStyle(.button)
                                .controlSize(.mini)
                                .accessibilityLabel(t("\(other.title) must finish before \(package.title)",
                                                      "Screen-reader label for a dependency toggle. Placeholders: the two package titles."))
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func addPackage(under parent: String?) {
        let title = newPackageTitle
        newPackageTitle = ""
        Task { await model.addPackage(title: title, parent: parent) }
    }

    /// Thai for the three levels. `RiskLevel.description` is the English the
    /// hook chain logs; this screen is read by a person.
    private func riskLabel(_ level: RiskLevel) -> String {
        switch level {
        case .low: t("low risk", "Risk level of a work package.")
        case .medium: t("medium risk", "Risk level of a work package.")
        case .high: t("high risk", "Risk level of a work package.")
        }
    }

    private func commitTitle(for package: WorkPackage) {
        guard let draft = titleDrafts[package.id] else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        titleDrafts[package.id] = nil
        // An empty title is not a rename, it is a deleted name — and a leaf with
        // no title cannot be reviewed against anything.
        guard !trimmed.isEmpty, trimmed != package.title else { return }
        var next = package
        next.title = trimmed
        Task { await model.update(next) }
    }

    private func stageStrip(_ current: ProjectStage) -> some View {
        HStack(spacing: 4) {
            ForEach(ProjectStage.allCases, id: \.self) { stage in
                Text(stage.label)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(stage == current ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: Radius.control))
                    .foregroundStyle(stage <= current ? Color.primary : Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t("Project stage, currently \(current.label)",
                              "Screen-reader label for the stage strip. Placeholder is the current stage."))
    }

    private func gateBox(_ gate: GateEvaluation) -> some View {
        GroupBox(t("\(gate.gate) → stage \(gate.to.label)",
                   "Box heading over the next gate. Placeholders: the gate's name and the stage it leads to.")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(gate.conditions.enumerated()), id: \.offset) { _, condition in
                    Label {
                        HStack(spacing: 6) {
                            Text(condition.text)
                            if condition.vacuous {
                                Text(localised: "nothing to check",
                                     "A gate condition that is satisfied because there was nothing to test — not because a test passed.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        // A tick that means "nothing was checked" must not look
                        // like one that means "checked and fine".
                        Image(systemName: condition.vacuous ? "minus.circle"
                              : (condition.satisfied ? "checkmark.circle" : "circle"))
                            .foregroundStyle(condition.vacuous ? Color.secondary
                                             : (condition.satisfied ? Color.green : Color.secondary))
                    }
                    .font(.callout)
                }

                HStack {
                    Button(t("Pass this gate", "Button that advances the project to the next stage.")) {
                        Task { await model.advance() }
                    }
                        .disabled(!gate.passed)
                        .keyboardShortcut(.return, modifiers: [.command])
                    Button(t("Terminate the project", "Button that stops the project for good.")) {
                        Task {
                            await model.terminate(reason: t("terminated by the user",
                                                            "Recorded as the reason when a person ends a project from this button."))
                        }
                    }
                    Spacer()
                }
                if !gate.passed {
                    Text(localised: "In this stage, tools may \(allowedText(gate.from))",
                         "Says what the current stage permits. Placeholder completes the sentence.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func allowedText(_ stage: ProjectStage) -> String {
        switch stage {
        case .initiation: t("only read", "What tools may do in the initiation stage. Completes “In this stage, tools may …”.")
        case .planning: t("read and draft documents, but not change data",
                          "What tools may do in the planning stage. Completes “In this stage, tools may …”.")
        case .execution: t("do anything their risk level allows",
                           "What tools may do in the execution stage. Completes “In this stage, tools may …”.")
        case .closing: t("write reports, but the numbers must stop moving",
                         "What tools may do in the closing stage. Completes “In this stage, tools may …”.")
        case .closed: t("only read", "What tools may do once the project is closed. Completes “In this stage, tools may …”.")
        }
    }

    // MARK: - editing helpers

    // MARK: - editing without fighting the database
    //
    // Driving this screen by hand found the bug this replaces. Every keystroke
    // used to write to SurrealDB and reload the project, and the reload landed
    // with text older than what had been typed since — so typing a Thai
    // sentence dropped characters, one per round-trip. Nothing in the unit
    // tests could see it: the view model saved correctly, the store stored
    // correctly, and only the two together ate the input.
    //
    // Now the fields edit a local copy and commit after a pause. The database
    // is the source of truth, not the keyboard's opponent.

    struct Draft: Equatable {
        var projectID: String = ""
        var brief: String = ""
        var inScope: String = ""
        var outOfScope: String = ""
        var acceptance: String = ""
        var executive: String = ""
        var seniorUser: String = ""

        init() {}

        init(_ project: Project) {
            projectID = project.id.rawValue
            brief = project.brief
            inScope = project.statement.inScope.joined(separator: "\n")
            outOfScope = project.statement.outOfScope.joined(separator: "\n")
            acceptance = project.statement.acceptanceCriteria.joined(separator: "\n")
            executive = project.board.first { $0.seat == .executive }?.person ?? ""
            seniorUser = project.board.first { $0.seat == .seniorUser }?.person ?? ""
        }

        func applied(to project: Project) -> Project {
            var next = project
            next.brief = brief
            next.statement.inScope = Draft.lines(inScope)
            next.statement.outOfScope = Draft.lines(outOfScope)
            next.statement.acceptanceCriteria = Draft.lines(acceptance)
            // Rebuilt rather than patched: a seat cleared in the field is a
            // seat nobody holds, and leaving the old name behind would make
            // G1 pass on a person who is no longer there.
            var board: [BoardRole] = []
            let exec = executive.trimmingCharacters(in: .whitespacesAndNewlines)
            if !exec.isEmpty { board.append(BoardRole(seat: .executive, person: exec)) }
            let senior = seniorUser.trimmingCharacters(in: .whitespacesAndNewlines)
            if !senior.isEmpty { board.append(BoardRole(seat: .seniorUser, person: senior)) }
            next.board = board
            return next
        }

        /// Splitting happens at commit time, never while typing: trimming and
        /// dropping empty lines on every keystroke is what made it impossible
        /// to press Return and start a second bullet.
        static func lines(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    @ViewBuilder
    private var savedHint: some View {
        Text(saving
             ? t("saving…", "Shown while an edit is being written.")
             : t("saves on its own once you stop typing", "Shown beside an editor that autosaves."))
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func lineEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .frame(minHeight: 52)
                .accessibilityLabel(t("\(title) list, one item per line",
                                      "Screen-reader label for a line editor. Placeholder is the editor's title."))
        }
    }

    /// Seeds the buffer when the selected project changes, and only then —
    /// reseeding while somebody is typing is the same bug in a different shape.
    private func seedDraftIfNeeded(_ project: Project?) {
        guard let project else { draft = Draft(); return }
        guard draft.projectID != project.id.rawValue else { return }
        draft = Draft(project)
    }

    /// Turns the buffer into criteria and saves, once. `·` is the separator
    /// because a leaf's criteria are a short list and a multi-line editor per
    /// leaf would bury the tree it belongs to.
    private func commitCriteria(for package: WorkPackage) {
        guard let text = criteriaDrafts[package.id] else { return }
        let criteria = text.split(separator: "·", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Criterion(text: $0, evidenceRequired: t("checkable evidence",
                                                            "Default evidence requirement on a criterion typed as free text.")) }
        guard criteria != package.acceptanceCriteria else {
            criteriaDrafts.removeValue(forKey: package.id)
            return
        }
        var next = package
        next.acceptanceCriteria = criteria
        criteriaDrafts.removeValue(forKey: package.id)
        Task { await model.update(next) }
    }

    private func commitDraft() async {
        guard let project = model.selected, draft.projectID == project.id.rawValue else { return }
        let edited = draft.applied(to: project)
        guard edited != project else { return }
        saving = true
        // Two writes, because the baseline holds one of these and not the other
        // (§19.11): the scope statement is part of the agreement and goes through
        // change control, while the brief and the board seats are not — asking
        // for a change request to fix a typo in the brief would teach people to
        // click through the bar that asks (§19.2.4).
        if edited.statement != project.statement {
            await model.updateScope(edited.statement)
        }
        var withoutScope = edited
        withoutScope.statement = project.statement
        if withoutScope != project { await model.update(withoutScope) }
        saving = false
    }
}
