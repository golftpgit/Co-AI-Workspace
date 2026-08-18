import SwiftUI
import AgentKit
import Instruments

// ─────────────────────────────────────────────────────────────
// Coding transcripts, and what the coding says about itself
// (ARCHITECTURE §20.3, P11.8).
//
// The quantitative tab is about designing an instrument before anybody answers
// it. This one is the other order: the text exists, and the categories are built
// out of it. So the screen reads downwards in the order the work happens —
// codebook, passages, coding, and then the two things a methods section has to
// report about them.
//
// κ and the saturation curve are computed as you look at them rather than behind
// a button. They are cheap here (counting, not a hundred eigen-decompositions),
// and a reliability figure that only appears when asked for is one people ask
// for at the end, which is the one moment it is too late to act on.
// ─────────────────────────────────────────────────────────────

struct CodingView: View {
    @Bindable var model: CodingViewModel
    /// Sending a transcript to the knowledge base (§20.9, P11.8). A closure
    /// rather than a second view model on this screen: the knowledge base is
    /// owned by its own screen, and two models over one index would be two
    /// answers to "what is in the library".
    var ingest: ((Transcript) async -> Void)?
    @State private var ingesting: String?

    @State private var newBook = ""
    @State private var newCode = ""
    @State private var newCodeDefinition = ""
    @State private var newCodeParent: String?
    @State private var newTranscriptTitle = ""
    @State private var newTranscriptCode = ""
    @State private var newTranscriptBy = ""
    @State private var newTranscriptText = ""

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let book = model.selected {
                        detail(book)
                    } else {
                        Text(localised: "No codebook in this project yet — name one on the left to start · a codebook is the set of categories transcripts are read with, and it is what κ measures the agreement of",
                             "Empty state on the coding screen.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Space.box)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await model.reload() }
    }

    // MARK: - list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localised: "Codebook", "Heading over the list of codebooks.").font(.subheadline).bold()
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()

            List {
                ForEach(model.codebooks) { book in
                    Button {
                        Task { await model.select(book.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(book.title.thai).font(.callout)
                            Text(localised: "\(book.codes.count) codes · \(book.documentOrder.count) documents",
                                 "A codebook row. Placeholders: how many codes and how many documents.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fontWeight(model.selectedID == book.id ? .semibold : .regular)
                    .accessibilityLabel(t("Open the codebook \(book.title.thai)",
                                          "Screen-reader label. Placeholder is the codebook title."))
                }
                if model.codebooks.isEmpty {
                    Text(localised: "No codebook yet", "Shown when the codebook list is empty.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                TextField(t("New codebook name", "Text field for creating a codebook."), text: $newBook)
                    .textFieldStyle(.roundedBorder)
                Button(t("Create", "Button that creates the project.")) {
                    let title = newBook
                    newBook = ""
                    Task { await model.createCodebook(title: title) }
                }
                .disabled(newBook.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(Space.box)
        }
    }

    // MARK: - detail

    @ViewBuilder
    private func detail(_ book: Codebook) -> some View {
        HStack(spacing: 8) {
            Text(book.title.thai).font(.title3).bold()
            Spacer()
            if let status = model.status {
                Button { model.clearStatus() } label: {
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(status.isError ? .red : .secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 420, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityHint(t("dismiss this message", "Screen-reader hint on a dismiss button."))
            }
        }

        coderBox()
        codesBox(book)
        unitsBox(book)
        if model.reliability != nil || model.saturation != nil { reportBox() }
    }

    /// Who is coding. First, and unmissable, because every row written below it
    /// carries this name into a κ.
    @ViewBuilder
    private func coderBox() -> some View {
        GroupBox(t("Who is coding right now", "Box heading over the current coder's name.")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(t("Coder's name", "Text field naming who is coding."), text: $model.coder)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .accessibilityLabel(t("Name of the coder working now", "Screen-reader label."))
                    if !model.progress.isEmpty {
                        Text(model.progress
                            .map { "\($0.coder) \($0.done)/\(model.units.count)" }
                            .joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .controlSize(.small)
                Text(localised: "Deliberately not remembered between sessions and given no default — κ is a claim about people, and the commonest way an agreement study breaks is the second coder sitting down at a machine still holding the first one's name",
                     "Explains why the coder field is empty every time.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - the codes

    @ViewBuilder
    private func codesBox(_ book: Codebook) -> some View {
        GroupBox(t("Codes (\(book.codes.count))",
                   "Box heading over the codebook's codes. Placeholder is how many.")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(book.codes) { code in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            if let parent = code.parentID, let name = book.code(parent)?.name.thai {
                                Text("\(name) ›").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(code.name.thai).font(.callout)
                            Spacer()
                        }
                        Text(code.definition.isEmpty
                             ? t("no definition yet", "Shown for a code nobody has defined.")
                             : code.definition)
                            .font(.caption2)
                            .foregroundStyle(code.definition.isEmpty ? Color.orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if book.codes.isEmpty {
                    Text(localised: "No codes yet — the first one usually comes from reading the first transcript all the way through",
                         "Shown when the codebook is empty.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    TextField(t("Code name", "Text field naming a code."), text: $newCode)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    TextField(t("Definition — what counts and what does not",
                                "Text field: the code's definition."),
                              text: $newCodeDefinition)
                        .textFieldStyle(.roundedBorder)
                    Picker(t("Under", "Picker: which package the new one sits beneath."), selection: $newCodeParent) {
                        Text(localised: "— open code —", "Picker option: this code has no parent.")
                            .tag(String?.none)
                        ForEach(book.codes) { code in
                            Text(code.name.thai).tag(String?.some(code.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 150)
                    .accessibilityLabel(t("Parent of this code", "Screen-reader label."))
                    Button(t("Add code", "Button that adds a code to the codebook.")) {
                        let name = newCode
                        let definition = newCodeDefinition
                        let parent = newCodeParent
                        newCode = ""
                        newCodeDefinition = ""
                        Task { await model.addCode(name: name, definition: definition,
                                                   parentID: parent) }
                    }
                    .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)

                ForEach(book.problems, id: \.text) { problem in
                    Label(problem.text, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - the passages, and coding them

    @ViewBuilder
    private func unitsBox(_ book: Codebook) -> some View {
        GroupBox(t("Passages (\(model.units.count))",
                   "Box heading over the passages being coded. Placeholder is how many.")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localised: "Passages are fixed once and everybody codes the same set — two coders who each choose where a passage begins are not agreeing or disagreeing about anything comparable",
                     "Explains why passages are defined before coding starts.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(model.units) { unit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(model.transcript(unit.documentID)?.title ?? unit.documentID)
                                .font(.caption2).foregroundStyle(.secondary)
                            // Taken from the transcript, not read off the unit's
                            // own copy: the two can drift, and only one of them
                            // is what the participant said.
                            Text(model.quotation(for: unit)?.text ?? unit.text)
                                .font(.caption).lineLimit(2)
                            Spacer()
                            if let quotation = model.quotation(for: unit) {
                                Text(localised: "characters \(quotation.span.start)–\(quotation.span.end)",
                                     "Where a passage sits in the transcript. Placeholders: the start and end offsets.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .accessibilityLabel(t("Position in the transcript, \(quotation.span.start) to \(quotation.span.end)",
                                                          "Screen-reader label. Placeholders: the start and end offsets."))
                            } else {
                                Text(localised: "cannot be cited back", "Marker on a passage whose offsets no longer match the transcript.")
                                    .font(.caption2).foregroundStyle(.orange)
                                    .help(t("These offsets no longer match the transcript — it may have been edited after coding · it cannot be quoted until the passages are cut again",
                                            "Tooltip explaining a passage that lost its anchor."))
                            }
                        }
                        HStack(spacing: 4) {
                            ForEach(book.codes) { code in
                                codeButton(unit: unit, code: code.id, label: code.name.thai)
                            }
                            codeButton(unit: unit, code: nil,
                                       label: t("fits no code", "Button that records that a passage matches none of the codes."))
                            Spacer()
                        }
                        .controlSize(.mini)
                    }
                    Divider()
                }
                if model.units.isEmpty {
                    Text(localised: "No passages yet", "Shown when nothing has been cut into passages.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                // The transcripts themselves, and the one thing P11.8 could not
                // do until now: put one in the knowledge base. `TranscriptIngest`
                // and its tests have been ready since P11.8 and nothing called
                // them, which made the chunks-with-spans a capability the app
                // did not have.
                if !model.transcripts.isEmpty {
                    Divider()
                    Text(localised: "Transcripts in this project", "Heading over the transcript list.")
                        .font(.callout).fontWeight(.medium)
                    ForEach(model.transcripts) { transcript in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(transcript.title).font(.callout)
                                // Not `\(transcript.participantCode)` — it is
                                // optional, and interpolating it drew
                                // `Optional("P-7QK2")` on screen. A transcript
                                // with no code is also an ordinary thing (§20.7
                                // asks for a code, not for every study to have
                                // one), so it says that instead of nothing.
                                Text(localised: "\(transcript.paragraphs.count) paragraphs · \(transcript.participantCode.map { t("participant code \($0)", "Names a transcript's participant code. Placeholder is the code.") } ?? t("no participant code yet", "Shown for a transcript with no participant code."))",
                                     "A transcript row. Placeholders: how many paragraphs, and the participant code or a stand-in.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if ingesting == transcript.id {
                                ProgressView().controlSize(.small)
                            } else if let ingest {
                                Button(t("Send it to the knowledge base",
                                         "Button that indexes a transcript into the knowledge base.")) {
                                    ingesting = transcript.id
                                    Task {
                                        await ingest(transcript)
                                        ingesting = nil
                                    }
                                }
                                .controlSize(.small)
                                .accessibilityLabel(t("Send \(transcript.title) to the project's knowledge base",
                                                      "Screen-reader label. Placeholder is the transcript title."))
                            }
                        }
                    }
                    Text(localised: "Each passage that enters the base carries its own offsets — so a search result cites the paragraph rather than a two-hour interview · sending it again replaces what was there rather than keeping both versions",
                         "Explains what happens when a transcript is indexed.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }

                // A transcript goes in whole and is split into passages here,
                // rather than passages being typed in one at a time. The offsets
                // are the reason: a passage typed by hand has a range somebody
                // invented, and P11.8's promise is that a citation points back
                // into the real text.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField(t("Transcript name (for example: INT-01)",
                                    "Text field naming a transcript."),
                                  text: $newTranscriptTitle)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                        TextField(t("Participant code (not a name)",
                                    "Text field for the anonymous participant code."),
                                  text: $newTranscriptCode)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                        TextField(t("Transcribed by", "Text field naming who transcribed it."),
                                  text: $newTranscriptBy)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 150)
                        Spacer()
                    }
                    TextEditor(text: $newTranscriptText)
                        .font(.callout)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(Color.secondary.opacity(0.3)))
                        .accessibilityLabel(t("Transcript text", "Screen-reader label for the transcript editor."))
                    HStack {
                        Button(t("Add the transcript and cut it into passages by paragraph",
                                 "Button that stores a transcript and creates its coding units.")) {
                            let title = newTranscriptTitle
                            let code = newTranscriptCode
                            let by = newTranscriptBy
                            let text = newTranscriptText
                            newTranscriptText = ""
                            newTranscriptTitle = ""
                            Task {
                                await model.addTranscript(title: title, participantCode: code,
                                                          transcribedBy: by, text: text)
                            }
                        }
                        .disabled(newTranscriptTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newTranscriptText.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }
                    .controlSize(.small)
                    Text(localised: "Store the participant code, never the name — a transcript is cut, indexed, searched, exported and quoted, so an identity entering here leaves by all five routes (§20.7)",
                         "States the privacy rule for transcripts.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func codeButton(unit: CodingUnit, code: String?, label: String) -> some View {
        let mine = model.assignment(for: unit)
        let chosen = mine != nil && mine?.codeID == code
        Button(label) {
            Task { await model.code(unit: unit, as: code) }
        }
        .buttonStyle(.bordered)
        .tint(chosen ? .accentColor : .secondary)
        .disabled(model.coder.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityLabel(t("Apply \(label) to the passage \(unit.text.prefix(30))",
                              "Screen-reader label. Placeholders: the code name and the start of the passage."))
    }

    // MARK: - what the coding says about itself

    @ViewBuilder
    private func reportBox() -> some View {
        GroupBox(t("Inter-coder agreement and saturation",
                   "Box heading over κ and the saturation curve.")) {
            VStack(alignment: .leading, spacing: 8) {
                if let reliability = model.reliability {
                    Text(reliability.summary)
                        .font(.callout)
                        .foregroundStyle(reliability.isSubstantial ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(reliability.perCode) { row in
                            HStack(spacing: 8) {
                                Text(row.name).font(.caption)
                                    .frame(width: 200, alignment: .leading)
                                Text(String(format: "κ %.2f", row.kappa))
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(row.applications == 0 ? Color.secondary
                                                     : (row.kappa >= 0.61 ? .green : .orange))
                                Text(row.applications == 0
                                     ? t("never applied", "Shown for a code no coder has used.")
                                     : t("applied \(row.applications) times",
                                         "How often a code was used. Placeholder is a count."))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                Text(localised: "A low κ caused by one category swallowing everything is a different thing from coders who disagree, so the raw percentage agreement is always reported beside it · the .61 (substantial) threshold is a convention people cite, not a gate enforced here — a low κ is a finding to report, not a fault to hide",
                     "Explains how to read κ, and that nothing here blocks on it.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(localised: "κ needs at least \(CodingAnalysis.minimumCoders) coders and at least one passage every one of them has coded",
                         "Says why κ cannot be computed yet. Placeholder is the minimum number of coders.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let saturation = model.saturation {
                    Divider()
                    Text(saturation.summary).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(saturation.points) { point in
                        HStack(spacing: 8) {
                            Text("\(point.position). \(point.documentID)")
                                .font(.caption2).frame(width: 160, alignment: .leading)
                            Text(point.newCodes == 0
                                 ? t("no new codes", "Saturation point where nothing new appeared.")
                                 : t("\(point.newCodes) new codes",
                                     "Saturation point. Placeholder is how many codes were new."))
                                .font(.caption2)
                                .foregroundStyle(point.newCodes == 0 ? Color.secondary : .primary)
                            Text(localised: "\(point.cumulative) in total",
                                 "Running total on the saturation curve. Placeholder is the cumulative count.")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
