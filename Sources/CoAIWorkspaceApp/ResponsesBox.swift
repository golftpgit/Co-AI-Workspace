import SwiftUI
import Instruments
import OLTP

// ─────────────────────────────────────────────────────────────
// What came back (ARCHITECTURE §19.17, P11.6c/P11.7).
//
// §19.17 puts it exactly: this **works like a sheet and is not one**. A cell can
// be changed, and changing it does not write over what arrived — it records a
// correction with a reason and a name against it, and the cell then shows the new
// value with a mark and the old one behind it.
//
// That is the whole design, and it is not pedantry. A spreadsheet of research
// data that can be edited in place is a spreadsheet nobody can prove was not
// edited, and "nobody can prove it was not edited" is indistinguishable, at a
// defence, from "it was edited".
// ─────────────────────────────────────────────────────────────

struct ResponsesBox: View {
    @Bindable var model: InstrumentsViewModel
    let instrument: Instrument

    /// Which cell is open for correction. One at a time: a grid where several
    /// edits are in flight is a grid where somebody loses one.
    @State private var editing: Cell?
    @State private var draft = ""
    @State private var reason = ""
    @State private var person = ""

    struct Cell: Identifiable, Equatable {
        let submissionID: String
        let itemID: String
        var id: String { "\(submissionID)|\(itemID)" }
    }

    private var columns: [Item] { instrument.ordered }

    var body: some View {
        GroupBox(t("Responses collected (version \(instrument.version))",
                   "Box heading over the response table. Placeholder is the instrument version.")) {
            VStack(alignment: .leading, spacing: 8) {
                rounds
                if model.responseRows.isEmpty {
                    Text(localised: "No responses for this version yet — open the form on the local network and send the link to respondents",
                         "Empty state in the response table.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    table
                    HStack {
                        Button(t("Write it to the analysis database",
                                 "Button that materialises responses into DuckDB.")) {
                            Task { await model.materialize() }
                        }
                        if let done = model.materialized {
                            Text(localised: "table \(done.table) · \(done.rows) rows\(done.corrections > 0 ? t(" · \(done.corrections) corrected values", "Appended when corrected values are present. Placeholder is how many.") : "")",
                                 "Result of materialising. Placeholders: the table name and how many rows.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                    Text(localised: "Raw responses live in the project's SQLite · this button copies them into DuckDB so the notebook can open them — the app pulls, and the server never touches DuckDB at all (§19.17) · corrected values go across in their corrected form, with a `was_corrected` column saying so",
                         "Explains what materialising does and which way the data moves.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(localised: "This table behaves like a spreadsheet but is not one — editing a cell is stored as a “correction record” (old value · new value · reason · who · when) rather than an overwrite (§19.17)",
                         "Explains that edits are recorded, never destructive.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - rounds

    @ViewBuilder
    private var rounds: some View {
        if model.rounds.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.rounds) { round in
                    HStack(spacing: 6) {
                        Image(systemName: round.isOpen ? "dot.radiowaves.left.and.right" : "checkmark.seal")
                            .foregroundStyle(round.isOpen ? Color.green : Color.secondary)
                        // The dates are the claim a methods section makes, so they
                        // are shown rather than summarised.
                        // The date format puts a comma before the time, so the
                        // count needs its own separator or the line reads
                        // "…at 10:58, 0 responses" as though the count were part of
                        // the timestamp.
                        Text(round.isOpen
                             ? t("open wave · started \(round.openedAt.formatted(date: .abbreviated, time: .shortened))",
                                 "A wave that is still accepting responses. Placeholder is when it opened.")
                             : t("closed · \(round.openedAt.formatted(date: .abbreviated, time: .omitted)) – \(round.closedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")",
                                 "A finished wave. Placeholders: when it opened and when it closed."))
                            .font(.caption)
                        Text(localised: "· \(round.submissions) responses",
                             "How many responses a wave received. Placeholder is a count.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - the grid

    /// Both axes, and driving the screen with forty answers in it is what showed
    /// why. A horizontal-only `ScrollView` under a `maxHeight` does not clip what
    /// overflows downwards: the rows carried on past the box and were drawn over
    /// the captions beneath it. With one test submission — which is what every
    /// round before this had — the content fit, so nothing ever looked wrong.
    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    header(t("When", "Column heading over response timestamps."), width: 130)
                    ForEach(columns) { item in
                        header(item.prompt.thai, width: 150)
                    }
                }
                Divider()
                ForEach(model.responseRows) { row in
                    HStack(spacing: 0) {
                        Text(row.submission.receivedAt.formatted(date: .abbreviated,
                                                                 time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                            .padding(.vertical, 3)
                        ForEach(columns) { item in
                            cell(row: row, item: item)
                        }
                    }
                    Divider()
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 260)
    }

    private func header(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption).bold()
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 3)
    }

    @ViewBuilder
    private func cell(row: InstrumentsViewModel.ResponseRow, item: Item) -> some View {
        let answer = row.answers[item.id]
        let cell = Cell(submissionID: row.submission.id, itemID: item.id)
        Button {
            draft = answer?.text ?? ""
            reason = ""
            editing = cell
        } label: {
            HStack(spacing: 3) {
                Text(answer?.text ?? "—")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(answer == nil ? Color.secondary : Color.primary)
                if answer?.wasCorrected == true {
                    // The mark §19.17 asks for. Not a colour alone: a mark that is
                    // only a colour is invisible to a screen reader and to the
                    // people this project keeps writing accessibility rules for.
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 150, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(answer == nil)
        .accessibilityLabel(label(for: answer, item: item))
        .accessibilityHint(t("opens the sheet for correcting this answer", "Screen-reader hint on a response cell."))
        .popover(isPresented: Binding(get: { editing == cell },
                                      set: { if !$0 { editing = nil } })) {
            correctionForm(row: row, item: item, answer: answer)
        }
    }

    private func label(for answer: ResolvedAnswer?, item: Item) -> String {
        guard let answer else {
            return t("\(item.prompt.thai): no answer",
                     "Screen-reader label for an unanswered item. Placeholder is the question text.")
        }
        guard let correction = answer.corrected else {
            return "\(item.prompt.thai): \(answer.text)"
        }
        return t("\(item.prompt.thai): \(answer.text) — corrected from \(correction.previousText) by \(correction.correctedBy) because \(correction.reason)",
                 "Screen-reader label for a corrected answer. Placeholders: the question, the current value, the old value, who corrected it and why.")
    }

    @ViewBuilder
    private func correctionForm(row: InstrumentsViewModel.ResponseRow, item: Item,
                                answer: ResolvedAnswer?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.prompt.thai).font(.headline)
            if let correction = answer?.corrected {
                // The original, still readable — which is the point of keeping it.
                VStack(alignment: .leading, spacing: 2) {
                    Text(localised: "What the respondent sent: \(correction.previousText)",
                         "The original answer, kept beside the correction. Placeholder is the old value.")
                    Text(localised: "changed to \(correction.newText) by \(correction.correctedBy) · \(correction.correctedAt.formatted(date: .abbreviated, time: .shortened))",
                         "The correction itself. Placeholders: the new value, who made it and when.")
                    Text(localised: "Reason: \(correction.reason)",
                         "The reason for a correction. Placeholder is the reason given.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            TextField(t("New value", "Text field for the corrected answer."), text: $draft)
                .textFieldStyle(.roundedBorder)
            TextField(t("Reason for the correction", "Text field: why the answer is being changed."),
                      text: $reason)
                .textFieldStyle(.roundedBorder)
            TextField(t("Name of who is correcting it", "Text field: who is making the correction."),
                      text: $person)
                .textFieldStyle(.roundedBorder)
            Text(localised: "Both the reason and the name are required — a correction with neither is indistinguishable from one hoping nobody notices",
                 "Explains why both fields are mandatory.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(t("Cancel", "Button that closes the correction sheet without saving.")) { editing = nil }
                Button(t("Record the correction", "Button that saves the correction.")) {
                    let previous = answer?.text ?? ""
                    let newText = draft, why = reason, who = person
                    editing = nil
                    Task {
                        await model.correct(submission: row.submission.id, item: item.id,
                                            previous: previous, to: newText,
                                            reason: why, by: who)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                          || reason.trimmingCharacters(in: .whitespaces).isEmpty
                          || person.trimmingCharacters(in: .whitespaces).isEmpty
                          || draft == answer?.text)
            }
        }
        .padding(Space.box)
        .frame(width: 340)
    }
}
