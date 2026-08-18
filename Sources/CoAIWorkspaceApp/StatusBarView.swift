import SwiftUI
import AgentKit
import ProjectKit

// ─────────────────────────────────────────────────────────────
// The status bar (ARCHITECTURE §19.2.3, P10.15 second half).
//
// §19.2.3's claim is that this is a dashboard, not a row of labels: every cell
// opens with where its number came from and a button that does something. The
// reason it is worth building as one strip rather than six widgets is the thing
// driving the screen kept showing — the facts that decide what to do next
// (which gate, which frame, what stopped) were always one screen away from
// whatever was being worked on.
//
// Two rules the cells follow, both learned the hard way:
//
//  • **A number nobody measured is not shown as a number.** An unread tolerance
//    says "not measured yet"; an empty popover says nothing was recorded rather than
//    showing zeros that read as "checked and fine".
//  • **Every button writes to the register.** Not by convention here — the
//    actions are `StatusAction` values and `ProjectService.perform` is what runs
//    them, so a one-click dashboard cannot become a place decisions vanish.
// ─────────────────────────────────────────────────────────────

struct StatusBarView: View {
    @Bindable var model: ProjectsViewModel
    /// Jumping to the cause of an unmet gate condition (§19.2.3). Passed in
    /// because this strip does not know what screens exist.
    let openPlan: () -> Void

    @State private var open: Cell?
    @State private var decision = ""
    @State private var limitDraft = ""
    @State private var reason = ""

    enum Cell: String, Identifiable {
        case stage, time, cost, quality, scope, exception
        var id: String { rawValue }
    }

    var body: some View {
        if let project = model.selected {
            HStack(spacing: 0) {
                cell(.stage, label: t("Stage", "Status bar cell: which stage of the project this is."),
                     value: project.stage.label,
                     alert: model.gate?.passed == true ? nil : "•")
                divider
                cell(.time, label: t("Time", "Status bar cell: time spent on this project."),
                     value: elapsedText,
                     alert: breached(.time) ? "!" : nil)
                divider
                cell(.cost, label: t("Spend this month", "Status bar cell: money spent so far this month."),
                     value: money(model.spendTotal),
                     alert: breached(.cost) ? "!" : nil)
                divider
                cell(.quality, label: "rework", value: model.rework.isEmpty
                     ? t("none", "Status bar value: no work has been sent back for rework.")
                     : t("\(model.rework.count) tasks", "Status bar value. Placeholder is a count of tasks sent back."),
                     alert: breached(.quality) ? "!" : nil)
                divider
                cell(.scope, label: t("Scope", "Status bar cell: how far today's plan has drifted from the agreed one."),
                     value: model.drift?.summary
                     ?? t("no baseline yet", "Status bar value: the plan was never frozen, so there is nothing to compare against."),
                     alert: model.drift?.isEmpty == false ? "•" : nil)
                if !model.openExceptions.isEmpty {
                    divider
                    cell(.exception, label: t("Waiting on you", "Status bar cell: work stopped until a person decides."),
                         value: t("\(model.openExceptions.count) items", "Status bar value. Placeholder is a count of open exceptions."),
                         alert: "!")
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, Space.box)
            .padding(.vertical, Space.tight)
            // **Solid, not `.bar`** (§24.2, P20.3). This strip carries money,
            // elapsed time and a rework count, and it sits at the bottom of a
            // scrolling screen — on a translucent background the content
            // passing underneath runs straight through the digits. A figure
            // misread here is not a cosmetic problem: it is what somebody
            // decides with.
            .surface(.solid, radius: 0)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var divider: some View {
        Divider().frame(height: 18)
    }

    @ViewBuilder
    private func cell(_ which: Cell, label: String, value: String, alert: String?) -> some View {
        Button {
            open = which
            seedDrafts(for: which)
        } label: {
            HStack(spacing: 5) {
                Text(label).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium)
                if let alert {
                    Text(alert)
                        .foregroundStyle(alert == "!" ? Color.red : Color.orange)
                        .fontWeight(.bold)
                }
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("\(label) \(value) — press to see where it comes from and what you can do",
                              "Screen-reader label for a status bar cell. First placeholder is the cell name, second its value."))
        .popover(isPresented: Binding(get: { open == which },
                                      set: { if !$0 { open = nil } })) {
            popover(which)
                .padding(Space.box)
                .frame(width: 380)
        }
    }

    // MARK: - what each cell opens with

    @ViewBuilder
    private func popover(_ which: Cell) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch which {
            case .stage: stagePopover
            case .time: timePopover
            case .cost: costPopover
            case .quality: qualityPopover
            case .scope: scopePopover
            case .exception: exceptionPopover
            }
        }
    }

    @ViewBuilder
    private var stagePopover: some View {
        if let gate = model.gate {
            Text("\(gate.gate): \(gate.from.label) → \(gate.to.label)").font(.headline)
            ForEach(Array(gate.conditions.enumerated()), id: \.offset) { _, condition in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: condition.satisfied
                          ? (condition.vacuous ? "circle.dotted" : "checkmark.circle.fill")
                          : "circle")
                        .foregroundStyle(condition.satisfied
                                         ? (condition.vacuous ? Color.secondary : Color.green)
                                         : Color.orange)
                    Text(condition.text).font(.callout)
                }
            }
            // §19.2.3: an unmet condition is a place to go, not a fact to read.
            if !gate.passed {
                Button(t("Go to the plan to settle what is outstanding",
                         "Button in the gate popover that navigates to the plan area.")) {
                    open = nil
                    openPlan()
                }
                .controlSize(.small)
            }
            Text(localised: "A dotted circle means there was nothing to check — not that a check passed",
                 "Legend under the gate conditions. The distinction is the whole point of the dotted icon.")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            Text(localised: "The project is closed — there is no next gate",
                 "Shown in the gate popover for a finished project.")
                .font(.callout)
        }
    }

    @ViewBuilder
    private var timePopover: some View {
        Text(localised: "Time spent", "Heading of the time popover.").font(.headline)
        Text(localised: "Summed from spans tied to this project's work packages: \(elapsedText)",
             "Says where the elapsed figure comes from. Placeholder is a duration such as 1.5 h.")
            .font(.callout)
        if let forecast = model.forecast {
            // The band names its own population, and the label is read off
            // `basis` rather than written here. It has been wrong twice —
            // "the same kind of work" over a band of tool calls, then over a band
            // of chat turns — both times because the sentence lived at the screen
            // and the data lived three modules away.
            Text(localised: "\(basisHeadline(forecast.basis)): p50 \(minutes(forecast.p50)) · p90 \(minutes(forecast.p90)) (from \(forecast.sampleCount) \(forecast.unit))",
                 "The forecast band. Placeholders: what the band was computed from, two durations, a sample count, and the name of the unit counted.")
                .font(.callout)
            switch forecast.basis {
            case .assignments:
                Text(localised: "Across projects — a p90 computed from this project alone says nothing · counts the whole task, from assignment to passing review, **including rounds of rework**, because a plan that counts only first-time passes is a plan nobody meets",
                     "Caveat under a forecast built from finished assignments.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .turns:
                // One literal: SwiftUI parses markdown only in a string literal,
                // and `"a" + "b"` prints its own asterisks (check.sh's rule,
                // which has now caught me twice).
                Text(localised: "Across projects — a p90 computed from this project alone says nothing · **this is not yet a history of the same kind of work**, because fewer than three deliverables of this kind have finished. A turn is smaller than a task, so this band reads low",
                     "Caveat under a forecast built from chat turns because there are too few finished assignments.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(localised: "Nothing finished yet to compare against — so there is no p50–p90 band",
                 "Shown in the time popover when there is no forecast.")
                .font(.callout).foregroundStyle(.secondary)
        }
        widenControl(.time)
    }

    @ViewBuilder
    private var costPopover: some View {
        Text(localised: "Spend this month \(money(model.spendTotal))",
             "Heading of the cost popover. Placeholder is an amount of money.")
            .font(.headline)
        if model.spendByRole.isEmpty {
            Text(localised: "No spending recorded this month",
                 "Shown in the cost popover when nothing has been charged.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text(localised: "By role", "Section heading in the cost popover.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.spendByRole) { slice in
                barRow(slice.key, amount: money(slice.amount),
                       fraction: model.spendTotal > 0 ? slice.amount / model.spendTotal : 0)
            }
            Text(localised: "By model", "Section heading in the cost popover.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.spendByModel) { slice in
                barRow(slice.key, amount: money(slice.amount),
                       fraction: model.spendTotal > 0 ? slice.amount / model.spendTotal : 0)
            }
        }
        Divider()
        // The honest half of "by tool": money is charged per model call, so
        // splitting a bill by tool would be inventing the split. What each tool
        // *did* is recorded, so that is what this shows.
        Text(localised: "Tools called (number of calls — not cost: money is charged per model call, not per tool)",
             "Heading over the tool activity list, saying plainly that these are not money figures.")
            .font(.caption).foregroundStyle(.secondary)
        if model.toolActivity.isEmpty {
            Text(localised: "No tool calls in this project yet",
                 "Shown when the tool activity list is empty.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(model.toolActivity.prefix(6)) { slice in
                Text(localised: "\(slice.tool) — \(slice.calls) calls · \(minutes(slice.seconds))",
                     "A row of tool activity. Placeholders: tool name, a count of calls, and a duration.")
                    .font(.callout)
            }
        }
        widenControl(.cost)
    }

    @ViewBuilder
    private var qualityPopover: some View {
        Text(localised: "Work that had to be redone", "Heading of the rework popover.").font(.headline)
        if model.rework.isEmpty {
            Text(localised: "Nothing has been sent back yet", "Shown when no work has failed review.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(model.rework) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(localised: "\(row.goal) · \(row.role) · \(row.attempts) rounds",
                         "A rework row. Placeholders: the goal, the role that did it, and how many attempts it took.")
                        .font(.callout)
                    // Every round's reason, not just the last: §19.2.3 asks for
                    // QA's reason from every round, and the pattern across rounds
                    // is what tells a person whether to loosen the DoD or the model.
                    ForEach(Array(row.findings.enumerated()), id: \.offset) { _, finding in
                        Text("• \(finding)").font(.caption).foregroundStyle(.secondary)
                    }
                    if row.needsHuman {
                        Text(localised: "Escalated to a person",
                             "Marker on a rework row that has been handed to a human.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
        widenControl(.quality)
        Text(localised: "Loosening the definition of done happens on the plan screen — that is amending the agreement, not widening a tolerance",
             "Note in the rework popover. 'DoD' is spelled out because the two things are deliberately kept apart.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var scopePopover: some View {
        Text(localised: "Difference from the agreed plan", "Heading of the scope popover.").font(.headline)
        if let drift = model.drift, !drift.isEmpty {
            ForEach(drift.added, id: \.id) { package in
                Text("+ \(package.title)").font(.callout).foregroundStyle(.orange)
            }
            ForEach(drift.removed, id: \.id) { package in
                Text("− \(package.title)").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(drift.changed, id: \.id) { package in
                Text(localised: "changed \(package.title)",
                     "A drift row for an edited work package. Placeholder is its title.")
                    .font(.callout)
            }
            if drift.scopeChanged {
                Text(localised: "The scope statement differs from the baseline",
                     "A drift row for the project's scope text.")
                    .font(.callout)
            }
            Button(t("Open a change request from this difference",
                     "Button that turns the measured drift into a change request.")) {
                let action = StatusAction.requestChange(
                    title: t("Bring the plan in line with what is being done: \(drift.summary)",
                             "Title of the generated change request. Placeholder summarises the drift."),
                    scopeImpact: drift.summary,
                    timeImpact: t("cannot be estimated from the status bar",
                                  "Placeholder impact on a change request the status bar generated."),
                    costImpact: t("cannot be estimated from the status bar",
                                  "Placeholder impact on a change request the status bar generated."))
                open = nil
                Task { await model.perform(action) }
            }
            .controlSize(.small)
        } else if model.drift == nil {
            Text(localised: "No baseline yet — the plan has never been frozen into an agreement",
                 "Shown in the scope popover when there is nothing to compare against.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text(localised: "Today's plan matches the latest baseline",
                 "Shown in the scope popover when there is no drift.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var exceptionPopover: some View {
        ForEach(model.openExceptions) { report in
            VStack(alignment: .leading, spacing: 6) {
                Text(report.message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(t("Your decision", "Text field where a person settles a blocked exception."),
                              text: $decision)
                        .textFieldStyle(.roundedBorder)
                    // The Done-when's first clause: decided here, not on another
                    // screen. The decision text is what the report asked for in
                    // its "what we need from you" field.
                    Button(t("Decide here", "Button that records the decision without leaving the status bar.")) {
                        let text = decision
                        decision = ""
                        open = nil
                        Task { await model.perform(.decideException(report, decision: text)) }
                    }
                    .disabled(decision.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - the one control three popovers share

    @ViewBuilder
    private func widenControl(_ dimension: ToleranceDimension) -> some View {
        let status = model.tolerances.first { $0.dimension == dimension }
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Text(localised: "\(dimension.label) tolerance is currently \(number(status?.limit ?? 0)) \(dimension.unit)",
                 "Says what the tolerance is before offering to widen it. Placeholders: which tolerance, its number, and its unit.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(t("New limit", "Text field for the widened tolerance."), text: $limitDraft)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                TextField(t("Reason", "Text field: why the tolerance is being widened. Required."), text: $reason)
                    .textFieldStyle(.roundedBorder)
                Button(t("Widen", "Button that raises the tolerance to the new limit.")) {
                    guard let limit = Double(limitDraft.trimmingCharacters(in: .whitespaces))
                    else { return }
                    let text = reason
                    open = nil
                    Task {
                        await model.perform(.widenTolerance(dimension, to: limit, reason: text))
                    }
                }
                .disabled(Double(limitDraft.trimmingCharacters(in: .whitespaces)) == nil
                          || reason.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            Text(localised: "Always recorded as a decision with its reason — and once G2 has passed, a change request is opened as well",
                 "Note under the widen control. 'G2' is the name of the second gate and stays as is.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func barRow(_ key: String, amount: String, fraction: Double) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.callout).frame(width: 130, alignment: .leading).lineLimit(1)
            ProgressView(value: min(max(fraction, 0), 1)).frame(width: 90)
            Text(amount).font(.system(.caption, design: .monospaced))
        }
    }

    // MARK: - formatting

    private func seedDrafts(for which: Cell) {
        reason = ""
        decision = ""
        let dimension: ToleranceDimension? = switch which {
        case .time: .time
        case .cost: .cost
        case .quality: .quality
        default: nil
        }
        limitDraft = dimension
            .flatMap { target in model.tolerances.first { $0.dimension == target } }
            .map { number($0.limit) } ?? ""
    }

    private func breached(_ dimension: ToleranceDimension) -> Bool {
        model.tolerances.first { $0.dimension == dimension }?.breached == true
    }

    private var elapsedText: String {
        let total = model.elapsed.values.reduce(0, +)
        return total > 0 ? minutes(total)
            : t("not measured yet", "Status bar value for elapsed time when nothing has been recorded — deliberately not '0'.")
    }

    /// Names the population in the reader's words. Exhaustive with no
    /// `default:` — a basis added later must be given a sentence rather than
    /// quietly inheriting somebody else's.
    private func basisHeadline(_ basis: ScheduleEstimate.Basis) -> String {
        switch basis {
        case .assignments(let kind):
            t("Finished work of kind “\(kind)”",
              "Names the population a forecast was computed from. Placeholder is a deliverable kind.")
        case .turns:
            t("Finished turns of the roles this project uses",
              "Names the population a forecast was computed from when there are too few finished assignments.")
        }
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        seconds >= 3_600
            ? String(format: t("%.1f h", "A duration of an hour or more. Placeholder is a number of hours."),
                            seconds / 3_600)
            : t("\(Int((seconds / 60).rounded())) min",
                "A duration under an hour. Placeholder is a whole number of minutes.")
    }

    /// The currency the endpoint charged in, which is the currency the ledger
    /// stores: `SpendEntry.costUSD`. Not converted to anything (decision,
    /// 2026-08-18) — a converted figure needs a rate, a rate needs a date, and
    /// a number on this bar that silently depends on both is worse than a
    /// number in a currency the reader has to recognise.
    ///
    /// It read `฿` until 2026-08-18 while holding USD. Nobody noticed because
    /// the only endpoints on this machine are free, so every figure was 0 —
    /// which is exactly the kind of wrong number that waits for the day it
    /// matters. `EndpointsView` had `$%.4f` for the same data all along.
    private func money(_ amount: Double) -> String {
        amount == 0 ? "$0" : String(format: "$%.2f", amount)
    }

    private func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
