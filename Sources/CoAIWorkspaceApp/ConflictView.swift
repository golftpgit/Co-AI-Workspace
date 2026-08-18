import SwiftUI
import AgentKit
import Knowledge
import Persistence

// ─────────────────────────────────────────────────────────────
// The Conflict Card (ARCHITECTURE §11.6, P3.7).
//
// §11.6 is specific about what has to be on it, and each row of that table is
// there because leaving it out pushes the user back to the documents:
//
//   both passages verbatim · where each came from, with its tier and year ·
//   the weights as reasons · the system's suggestion, marked as a suggestion ·
//   four choices including "both, in different contexts" and "not yet" ·
//   and whether the decision binds one project or everything.
// ─────────────────────────────────────────────────────────────

struct ConflictView: View {
    @Bindable var model: ConflictViewModel
    @State private var deciding: StoredConflict?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.visible.isEmpty {
                ContentUnavailableView(
                    model.showsDecided
                        ? t("No conflicts recorded yet", "Empty state when showing decided conflicts too.")
                        : t("No conflicts waiting to be decided", "Empty state when showing only open conflicts."),
                    systemImage: "checkmark.seal",
                    description: Text(localised: "One is raised on its own whenever two sources answer the same question differently",
                                      "Empty-state explanation on the conflicts screen."))
                    // Takes the space under the header so it centres there,
                    // rather than leaving the stack short enough to be centred
                    // as a whole.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.visible) { conflict in
                            ConflictCard(conflict: conflict,
                                         decide: { deciding = conflict },
                                         model: model)
                        }
                    }
                    .padding(Space.section)
                }
            }
        }
        // Pinned to the top. `ContentUnavailableView` sizes to its content, so
        // with an empty list the stack was shorter than the window and got
        // centred — carrying the header and its divider down into the middle of
        // the screen, which only looked right once a card was there to fill it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
        .sheet(item: $deciding) { conflict in
            DecisionSheet(conflict: conflict) { resolution, asPrecedent in
                Task { await model.decide(conflict, resolution, asPrecedent: asPrecedent) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localised: "Knowledge that contradicts itself", "Heading of the conflicts screen.")
                    .font(.headline)
                if model.openCount > 0 {
                    Text(localised: "\(model.openCount) waiting",
                         "Count of undecided conflicts. Placeholder is how many.")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Toggle(t("Show decided ones", "Checkbox that includes settled conflicts in the list."),
                       isOn: $model.showsDecided)
                    .toggleStyle(.switch)
                    .accessibilityLabel(t("Also show conflicts that have been decided", "Screen-reader label."))
            }

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
}

// MARK: - card

private struct ConflictCard: View {
    let conflict: StoredConflict
    let decide: () -> Void
    /// For the history (§11.6, P3.7) — read and reversed from the card, since
    /// the card is where somebody is standing when they realise the decision
    /// was wrong.
    @Bindable var model: ConflictViewModel
    @State private var reopening = false
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(conflict.headline).font(.title3.weight(.semibold))
                Spacer()
                if let decision = conflict.decision {
                    Label(decision.decidedByHuman
                          ? t("you decided this", "Marker on a conflict a person settled.")
                          : t("the system decided this", "Marker on a conflict the system settled."),
                          systemImage: decision.decidedByHuman ? "person.fill.checkmark" : "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                SideColumn(label: t("Side A", "Column heading for the first claim in a conflict."),
                           side: conflict.a,
                           reasons: conflict.weightAReasons, score: conflict.scoreA)
                SideColumn(label: t("Side B", "Column heading for the second claim in a conflict."),
                           side: conflict.b,
                           reasons: conflict.weightBReasons, score: conflict.scoreB)
            }

            if let decision = conflict.decision {
                DecisionSummary(decision: decision)
                decisionHistory
            } else {
                // Marked as a suggestion, in words, because §11.6 says the
                // system proposes and the human decides — and it names the side
                // and the reason, because "the heavier side" makes the user
                // rebuild the proposal from two numbers.
                Label(proposalText, systemImage: "lightbulb")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(t("Decide this conflict", "Button that opens the decision sheet."), action: decide)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(t("Open the decision sheet for \(conflict.headline)",
                                          "Screen-reader label. Placeholder summarises the conflict."))
            }
        }
        .padding(Space.section)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.sheet))
    }

    /// The history, and the way back out of a decision (P3.7).
    ///
    /// Reversing needs a reason and the button says so, because a reversal
    /// with no reason is indistinguishable from a mis-click to whoever meets
    /// it later. Nothing here deletes anything: reopening adds an entry.
    @ViewBuilder
    private var decisionHistory: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { model.historyFor == conflict.id },
            set: { expanded in
                Task {
                    if expanded { await model.loadHistory(of: conflict) }
                    else { model.closeHistory() }
                }
            })) {
            VStack(alignment: .leading, spacing: Space.row) {
                ForEach(Array(model.history.enumerated()), id: \.offset) { _, record in
                    HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                        Image(systemName: record.isReopening
                              ? "arrow.uturn.backward" : "checkmark.seal")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.isReopening
                                 ? t("reversed — \(record.note)",
                                     "History row for a reversed decision. Placeholder is the reason given.")
                                 : (record.note.isEmpty
                                    ? t("decided", "History row for a decision recorded without a note.")
                                    : record.note))
                                .font(.callout)
                            Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if reopening {
                    HStack(spacing: Space.row) {
                        TextField(t("Why reverse it", "Text field: the required reason for reversing a decision."),
                                  text: $reason)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(t("Reason for reversing the decision", "Screen-reader label."))
                        Button(t("Confirm", "Button that records the reversal.")) {
                            Task {
                                await model.reopen(conflict, reason: reason)
                                reason = ""
                                reopening = false
                            }
                        }
                        .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button(t("Cancel", "Button that abandons reversing a decision.")) {
                            reopening = false; reason = ""
                        }
                    }
                } else {
                    Button(t("Reverse this decision", "Button that reopens a settled conflict.")) {
                        reopening = true
                    }
                        .accessibilityHint(t("The original decision stays in the history, and a reason is required",
                                             "Screen-reader hint on the reverse button."))
                }
            }
            .padding(.top, Space.row)
        } label: {
            Text(localised: "Decision history", "Heading over the record of how a conflict was settled.")
                .font(.caption)
        }
    }

    /// Always ends by saying it is a proposal. A conflict filed before the
    /// proposal was stored has none to show, and says that rather than
    /// inventing one.
    private var proposalText: String {
        let suggestion: String? = switch conflict.proposal {
        case .preferA(let reason):
            t("The system suggests side A — \(reason)",
              "A suggested resolution. Placeholder is the reason given.")
        case .preferB(let reason):
            t("The system suggests side B — \(reason)",
              "A suggested resolution. Placeholder is the reason given.")
        case .bothInContext(let condition):
            t("The system suggests both are right in different contexts — \(condition)",
              "A suggested resolution. Placeholder states the condition that separates them.")
        case .unresolved:
            t("The system suggests neither — the two sides weigh too closely",
              "A suggested resolution that declines to pick a side.")
        case nil: nil
        }
        guard let suggestion else {
            return t("The system has no suggestion for this conflict yet",
                     "Shown when nothing has been suggested.")
        }
        return suggestion + t(" (a suggestion, not a conclusion)",
                              "Appended to every suggestion so it is never read as a decision.")
    }
}

private struct SideColumn: View {
    let label: String
    let side: ConflictSide
    let reasons: String
    let score: Double

    /// Every string on this screen is Thai, so its dates are too. Left to the
    /// default the two halves disagree: a Thai system locale supplies the
    /// Buddhist era while the app's English localisation supplies the month
    /// name and the separator, and the card reads "11 Aug 2569 BE at 17:00".
    private static let accessed = Date.FormatStyle(date: .abbreviated, time: .shortened)
        .locale(Locale(identifier: "th_TH"))

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            // Verbatim. A summary here would be the agent deciding what the
            // sources said, which is the thing this screen exists to prevent.
            Text(side.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.box)
                .background(.background, in: RoundedRectangle(cornerRadius: Radius.box))

            HStack(spacing: 6) {
                TierChip(tier: side.provenance.tier)
                Text(side.provenance.title).lineLimit(1)
                if let year = side.provenance.year { Text("· \(String(year))") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(localised: "accessed \(side.provenance.accessedAt.formatted(Self.accessed))",
                 "When a source was read. Placeholder is a date.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(reasons)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: t("total weight %.2f",
                                  "The combined weight of one side of a conflict. Placeholder is a number."),
                        score))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TierChip: View {
    let tier: SourceTier?
    var body: some View {
        Text(tier?.rawValue.uppercased() ?? "—")
            .font(.caption2.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.secondary.opacity(0.18), in: Capsule())
            .accessibilityLabel(tier.map {
                t("trust tier \($0.rawValue.uppercased())",
                  "Screen-reader label for a source's trust tier. Placeholder is the tier code.")
            } ?? t("no external trust tier", "Screen-reader label when a source has no tier."))
    }
}

private struct DecisionSummary: View {
    let decision: ConflictDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: "checkmark.seal")
                .font(.callout)
            Text(scopeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Space.box)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.box))
    }

    private var text: String {
        switch decision.resolution {
        case .preferA(let reason): t("Use side A — \(reason)",
                                     "A recorded decision. Placeholder is the reason.")
        case .preferB(let reason): t("Use side B — \(reason)",
                                     "A recorded decision. Placeholder is the reason.")
        case .bothInContext(let condition): t("Both are right in different contexts — \(condition)",
                                              "A recorded decision. Placeholder states the condition.")
        case .unresolved: t("Not decided — documents must say this is unsettled",
                            "A recorded decision to leave the conflict open.")
        }
    }

    private var scopeText: String {
        switch decision.scope {
        case .central: t("binding on every project", "How widely a decision applies.")
        case .project(let id): t("only in project \(id.rawValue)",
                                 "How widely a decision applies. Placeholder is the project id.")
        case .board(let runID): t("only in this run (\(runID))",
                                  "How widely a decision applies. Placeholder is the run id.")
        case .policy: t("policy scope", "How widely a decision applies.")
        }
    }
}

// MARK: - deciding

private struct DecisionSheet: View {
    let conflict: StoredConflict
    let save: (ConflictResolution, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice: Choice
    @State private var condition = ""
    @State private var reason = ""
    @State private var asPrecedent = false

    init(conflict: StoredConflict, save: @escaping (ConflictResolution, Bool) -> Void) {
        self.conflict = conflict
        self.save = save
        // Opens on what the system proposed. It used to open on A whatever the
        // card recommended, so the one-click answer was sometimes the opposite
        // of the evidence the user had just read.
        _choice = State(initialValue: Choice(proposal: conflict.proposal))

        // Its wording comes along with it, so the user edits the reasoning
        // rather than retyping it — and a proposed "both, in different
        // contexts" arrives with the condition it depends on.
        switch conflict.proposal {
        case .preferA(let reason), .preferB(let reason): _reason = State(initialValue: reason)
        case .bothInContext(let condition): _condition = State(initialValue: condition)
        case .unresolved, nil: break
        }
    }

    private enum Choice: String, CaseIterable, Identifiable {
        case a, b, both, unresolved
        var id: String { rawValue }

        init(proposal: ConflictResolution?) {
            switch proposal {
            case .preferA: self = .a
            case .preferB: self = .b
            case .bothInContext: self = .both
            // No proposal is not a recommendation to pick A — it is the system
            // having nothing to say, and the sheet says that too.
            case .unresolved, nil: self = .unresolved
            }
        }

        var label: String {
            switch self {
            case .a: t("Use side A", "Choice in the decision sheet.")
            case .b: t("Use side B", "Choice in the decision sheet.")
            case .both: t("Both, in different contexts", "Choice in the decision sheet.")
            case .unresolved: t("Leave it unsettled", "Choice in the decision sheet.")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(conflict.question).font(.headline)

            Picker(t("Decision", "Picker over the four ways to settle a conflict."), selection: $choice) {
                ForEach(Choice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .accessibilityLabel(t("Choose the decision", "Screen-reader label for the decision picker."))

            switch choice {
            case .both:
                // Required: "it depends" with nothing after it settles nothing.
                TextField(t("State the condition, for example: one value for adults, another for children",
                            "Text field for the condition that separates two contexts."),
                          text: $condition)
                    .textFieldStyle(.roundedBorder)
            case .unresolved:
                Text(localised: "Documents citing this will be written to say it is unsettled",
                     "Consequence of leaving a conflict undecided.")
                    .font(.caption).foregroundStyle(.secondary)
            case .a, .b:
                TextField(t("Reason (optional)", "Text field for an optional note on a decision."),
                          text: $reason)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(t("Make this binding on every project",
                     "Checkbox that widens a decision beyond the current scope."),
                   isOn: $asPrecedent)
                .accessibilityHint(t("If off, the decision applies only to the scope you are looking at",
                                     "Screen-reader hint for the precedent switch."))

            HStack {
                Spacer()
                Button(t("Cancel", "Button that closes the decision sheet without recording anything.")) {
                    dismiss()
                }
                Button(t("Record", "Button that records the conflict decision.")) {
                    save(resolution, asPrecedent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == .both && condition.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.section)
        .frame(width: 520)
    }

    private var resolution: ConflictResolution {
        switch choice {
        case .a: .preferA(reason: reason.isEmpty
                          ? t("chosen by the user", "Recorded as the reason when a person picks a side without typing one.")
                          : reason)
        case .b: .preferB(reason: reason.isEmpty
                          ? t("chosen by the user", "Recorded as the reason when a person picks a side without typing one.")
                          : reason)
        case .both: .bothInContext(condition: condition)
        case .unresolved: .unresolved
        }
    }
}
