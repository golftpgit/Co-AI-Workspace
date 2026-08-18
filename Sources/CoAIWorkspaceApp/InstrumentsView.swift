import SwiftUI
import AgentKit
import Instruments

// ─────────────────────────────────────────────────────────────
// The data-collection tab (ARCHITECTURE §20.3, §20.5, P11.2/P11.4).
//
// Laid out in the order the method runs, not the order the types were written:
// research questions → constructs → questions tied to them → consent and ethics →
// expert ratings → the gate. The gate is at the bottom because it is the thing
// that says whether any of the above is finished, and it lists what is missing by
// name rather than refusing silently.
//
// Everything is editable, including things the gate will reject: §20.3's design
// principle is that a person can change any layer, and a builder that refuses to
// save half-finished work is a builder people keep their real draft outside of.
// ─────────────────────────────────────────────────────────────

struct InstrumentsView: View {
    @Bindable var model: InstrumentsViewModel

    @State private var newTitle = ""
    @State private var newQuestion = ""
    @State private var newConstruct = ""
    @State private var newConstructDefinition = ""
    /// Deleting a draft is small and irreversible, which is exactly the shape
    /// that wants one confirmation rather than an undo nobody built.
    @State private var confirmingDiscard = false
    @State private var constructQuestionID: String?
    @State private var newItem = ""
    @State private var newItemKind = ItemKindChoice.likert5
    /// The rows/options and columns for the kinds that need a list typed in
    /// (P11.6). Kept beside the picker rather than in a sheet: somebody adding
    /// a grid knows its rows at the moment they choose "matrix".
    @State private var newItemFirstList = ""
    @State private var newItemSecondList = ""
    @State private var newItemConstruct: String?
    @State private var newItemDemographic = false
    @State private var expert = ""
    @State private var approver = ""
    @State private var consentDraft = ConsentDraft()
    @State private var ethicsDraft = EthicsDraft()
    /// Consent and ethics collapse to one line once saved, which is right until
    /// somebody needs to fix a typo in the contact address or the approval number.
    /// A page that can only be written once is a page people keep the real version
    /// of somewhere else (§20.3, design principle 2).
    @State private var editingConsent = false
    @State private var editingEthics = false

    /// The kinds offered in the picker.
    ///
    /// `matrix` and `ranking` joined it once the web form could draw them
    /// (P11.6): a picker that offers a type the *form* cannot render is the
    /// same dead end as one this screen cannot configure — the instrument
    /// would publish and nobody could answer it.
    ///
    /// `fileUpload` is still absent, and for the reason the renderer gives: an
    /// upload is a multipart body, a file with somebody's data on a disk, and
    /// a retention rule of its own (§20.5).
    enum ItemKindChoice: String, CaseIterable, Identifiable {
        case likert5, likert7, single, multiple, openText, number, date, matrix, ranking
        var id: String { rawValue }

        var label: String {
            switch self {
            case .likert5: t("Likert, 5 points", "Question kind in a survey instrument.")
            case .likert7: t("Likert, 7 points", "Question kind in a survey instrument.")
            case .single: t("Single choice", "Question kind: one answer only.")
            case .multiple: t("Multiple choice", "Question kind: several answers allowed.")
            case .openText: t("Open text", "Question kind: free writing.")
            case .number: t("Number", "Question kind: a numeric answer.")
            case .date: t("Date", "Question kind: a date answer.")
            case .matrix: t("Matrix (rows × columns)", "Question kind: a grid of sub-questions.")
            case .ranking: t("Ranking", "Question kind: put options in order.")
            }
        }

        /// Whether this kind needs a list typed in beside it, and what to call
        /// the two boxes. Nil for the kinds that carry their own labels.
        var listLabels: (first: String, second: String?)? {
            switch self {
            case .matrix: (t("Rows (one per line)", "Editor label for a matrix question's rows."),
                           t("Columns (one per line)", "Editor label for a matrix question's columns."))
            case .ranking: (t("Options to rank (one per line)", "Editor label for a ranking question."), nil)
            default: nil
            }
        }

        /// - Parameters:
        ///   - first: rows, or the options of a ranking.
        ///   - second: columns.
        func kind(first: String = "", second: String = "") -> ItemKind {
            func lines(_ text: String) -> [Bilingual] {
                text.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { Bilingual($0) }
            }
            switch self {
            case .matrix:
                // Empty lists are allowed through to the gate rather than
                // filled in with placeholders: a grid with no rows is a
                // mistake somebody should be told about, and "row 1" would
                // publish as though it were a question.
                return .matrix(rows: lines(first), columns: lines(second))
            case .ranking:
                return .ranking(options: lines(first))
            default:
                return legacyKind
            }
        }

        /// **Not left in Thai by oversight — left in Thai pending a decision.**
        ///
        /// These are the words a *respondent* reads on a questionnaire, and
        /// they are `Bilingual`, a type whose `thai` is required and whose
        /// `english` is optional. That shape is a claim about who fills these
        /// forms in, and it is stored in every instrument already saved and
        /// served to respondents by `FieldServer`.
        ///
        /// Translating the seeds without changing `Bilingual` would give an
        /// English-speaking researcher a Thai default they cannot read and
        /// cannot see is a default; changing `Bilingual` is a data-model change
        /// with migration behind it. Neither is a call to make while renaming
        /// buttons, so it is written down instead (2026-08-18).
        private var legacyKind: ItemKind {
            switch self {
            case .likert5:
                .likert(levels: ["ไม่เห็นด้วยอย่างยิ่ง", "ไม่เห็นด้วย", "เฉย ๆ",
                                 "เห็นด้วย", "เห็นด้วยอย่างยิ่ง"].map { Bilingual($0) })
            case .likert7:
                .likert(levels: (1...7).map { Bilingual("ระดับ \($0)") })
            case .single: .single(options: [Bilingual("ตัวเลือก 1"), Bilingual("ตัวเลือก 2")])
            case .multiple: .multiple(options: [Bilingual("ตัวเลือก 1"),
                                               Bilingual("ตัวเลือก 2")], maximum: nil)
            case .openText: .openText(maximumLength: 1_000)
            case .number: .number(minimum: nil, maximum: nil)
            case .date: .date
            // Handled above; the compiler wants them named.
            case .matrix: .matrix(rows: [], columns: [])
            case .ranking: .ranking(options: [])
            }
        }
    }

    struct ConsentDraft: Equatable {
        var purpose = ""
        var collected = ""
        var voluntary = ""
        var contact = ""
        var isReady: Bool {
            ![purpose, collected, voluntary, contact]
                .contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    struct EthicsDraft: Equatable {
        var isApproved = true
        var committee = ""
        var number = ""
        var reason = ""
        var declaredBy = ""

        init() {}

        /// Reopens a saved record for correction, with what it already says.
        init(_ record: EthicsRecord) {
            switch record {
            case .approved(let committee, let number, _, let by):
                isApproved = true
                self.committee = committee
                self.number = number
                declaredBy = by
            case .notHumanSubjects(let reason, let by):
                isApproved = false
                self.reason = reason
                declaredBy = by
            }
        }

        var isReady: Bool {
            guard !declaredBy.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return isApproved
                ? ![committee, number].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                : !reason.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let instrument = model.selected {
                        detail(instrument)
                    } else {
                        Text(localised: "No instrument in this project yet — name one on the left to start a draft",
                             "Empty state on the instruments screen.")
                            .font(.callout).foregroundStyle(.secondary)
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
                Text(localised: "Data-collection instruments", "Heading over the list of survey instruments.")
                    .font(.subheadline).bold()
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()

            List {
                ForEach(model.instruments) { instrument in
                    Button {
                        Task { await model.select(instrument.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(instrument.title.thai).font(.callout)
                            Text(localised: "version \(instrument.version) · \(instrument.items.count) questions",
                                 "An instrument row. Placeholders: its version and how many questions it holds.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fontWeight(model.selectedID == instrument.id ? .semibold : .regular)
                    .accessibilityLabel(t("Open instrument \(instrument.title.thai), version \(instrument.version)",
                                          "Screen-reader label. Placeholders: the instrument's title and version."))
                }
                if model.instruments.isEmpty {
                    Text(localised: "No instrument yet", "Shown when the instrument list is empty.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                TextField(t("New instrument name", "Text field for creating a survey instrument."),
                          text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                Button(t("Create", "Button that creates the project.")) {
                    let title = newTitle
                    newTitle = ""
                    Task { await model.create(title: title) }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(Space.box)
        }
    }

    // MARK: - detail

    @ViewBuilder
    private func detail(_ instrument: Instrument) -> some View {
        HStack(spacing: 8) {
            Text(instrument.title.thai).font(.title3).bold()
            Text(localised: "version \(instrument.version)",
                 "An instrument's version. Placeholder is the number.")
                .font(.caption).foregroundStyle(.secondary)
            discardControl(instrument)
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

        if let approval = model.approval {
            // Said once at the top rather than only next to each disabled control:
            // the first question somebody has on opening an approved version is
            // why nothing can be typed into it.
            Label(t("\(approval.summary) — this version can no longer be edited; press “New version” to change it",
                    "Banner on an approved instrument. Placeholder summarises the approval."),
                  systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Everything that changes the form is closed once the gate has been
        // passed (§20.6 invariant 1); scoring and the gate itself stay open,
        // because a late expert rating is evidence about the version, not a
        // change to it.
        chainBox(instrument).disabled(model.isApproved)
        itemsBox(instrument).disabled(model.isApproved)
        ethicsBox(instrument).disabled(model.isApproved)
        validityBox(instrument)
        gateBox()
        if model.isApproved {
            fieldBox()
            // Beside the server rather than in a screen of its own: enrolling a
            // participant and sending them their link is one job (§20.7).
            ParticipantsBox(model: model)
        }
        // Shown whenever there is anything to show, including after the server
        // has been stopped: the moment somebody most wants to look at what came
        // in is after they have closed the round.
        if !model.responseRows.isEmpty || !model.rounds.isEmpty {
            ResponsesBox(model: model, instrument: instrument)
        }
        // After the answers rather than beside the expert ratings: content
        // validity is asked before fieldwork and this is asked after it, and
        // putting them in one box is how the two get confused for each other in
        // a write-up (§20.4).
        if !model.responseRows.isEmpty {
            ScaleValidityBox(model: model, instrument: instrument)
        }
    }

    /// Throwing away a draft — and saying, rather than hiding, why most
    /// instruments cannot be.
    ///
    /// The button stays visible and disabled with the reasons beside it, which is
    /// the opposite of the "open the form" controls below: those are *absent* until
    /// the gate has passed because there is nothing to serve. Here there is
    /// something to delete and a rule that says not to, and a rule nobody can see
    /// reads as a screen that is broken.
    @ViewBuilder
    private func discardControl(_ instrument: Instrument) -> some View {
        let refusals = model.disposalRefusals
        Button(role: .destructive) {
            confirmingDiscard = true
        } label: {
            Label(t("Delete this draft", "Button that removes an unapproved instrument."), systemImage: "trash")
        }
        .controlSize(.small)
        .disabled(!refusals.isEmpty)
        .accessibilityLabel(t("Delete the draft instrument \(instrument.title.thai)",
                              "Screen-reader label. Placeholder is the instrument's title."))
        .accessibilityHint(refusals.first.map(\.description)
                           ?? t("can be deleted, because nothing is tied to this draft",
                                "Screen-reader hint when deletion is allowed."))
        .help(refusals.first.map(\.description)
              ?? t("Deletes a draft nothing is tied to", "Tooltip when deletion is allowed."))
        .confirmationDialog(t("Delete the draft “\(instrument.title.thai)”?",
                              "Confirmation title. Placeholder is the instrument's title."),
                            isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button(t("Delete this draft", "Confirming button that removes the draft."),
                   role: .destructive) {
                Task { await model.discardSelected() }
            }
            Button(t("Keep it", "Button that dismisses the delete confirmation."), role: .cancel) {}
        } message: {
            Text(localised: "This draft has passed no gate, has never opened a collection wave, and has no responses tied to it · expert ratings given to it go too, because they rate questions that are about to stop existing",
                 "Explains exactly what deleting an instrument draft takes with it.")
        }

        if let first = refusals.first {
            Text(first.description)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
        }
    }

    /// M16, and only once the gate has been passed (§20.7). There is no control
    /// here that could serve an unapproved instrument, because there is no value
    /// to serve — the button is absent rather than disabled, which is the same
    /// reason the server has no admin endpoints.
    @ViewBuilder
    private func fieldBox() -> some View {
        GroupBox(t("Open the form for others to fill in (this local network only)",
                   "Box heading over the LAN-only response server.")) {
            VStack(alignment: .leading, spacing: 8) {
                if let serving = model.serving {
                    HStack {
                        Label(model.waveIsOpen
                              ? t("accepting responses", "Wave status: the form is open.")
                              : t("closed to responses", "Wave status: the form is shut."),
                              systemImage: model.waveIsOpen ? "dot.radiowaves.left.and.right" : "hand.raised.fill")
                            .foregroundStyle(model.waveIsOpen ? Color.green : Color.orange)
                        Text(localised: "\(model.responses) received",
                             "How many responses have arrived. Placeholder is a count.")
                            .font(.callout).foregroundStyle(.secondary)
                            // Counted again every few seconds while the round is
                            // open. Driving this with a refresh button found the
                            // obvious thing: the one moment somebody watches this
                            // screen is while answers are arriving, and a number
                            // that only moves when you press something reads as a
                            // number that is not moving.
                            .task(id: model.waveIsOpen) {
                                while model.waveIsOpen, !Task.isCancelled {
                                    await model.refreshResponses()
                                    try? await Task.sleep(for: .seconds(3))
                                }
                            }
                        Spacer()
                        if model.waveIsOpen {
                            Button(t("Close the collection wave", "Button that stops accepting responses.")) {
                                Task { await model.closeWave() }
                            }
                        }
                        Button(t("Stop the server", "Button that takes the form offline.")) {
                            Task { await model.stopServing() }
                        }
                    }
                    .controlSize(.small)

                    if serving.urls.isEmpty {
                        Text(localised: "This machine is not on a network anybody else can reach — join the same wifi as the respondents first",
                             "Shown when the form cannot be served because there is no reachable network.")
                            .font(.callout).foregroundStyle(.orange)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localised: "Have respondents open this link in a browser:",
                                 "Instruction above the form's LAN address.")
                                .font(.caption).foregroundStyle(.secondary)
                            // Several, because a laptop on wifi and ethernet has
                            // more than one address and only the person in the
                            // room knows which network the respondents are on.
                            ForEach(serving.urls, id: \.self) { url in
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                } label: {
                                    Label(url, systemImage: "doc.on.doc")
                                        .font(.system(.callout, design: .monospaced))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(t("Copy the link \(url)",
                                                      "Screen-reader label. Placeholder is the address."))
                                .accessibilityHint(t("copies it to the clipboard", "Screen-reader hint."))
                            }
                        }
                    }
                } else {
                    HStack {
                        Button(t("Open the form on the local network",
                                 "Button that starts serving the form.")) {
                            Task { await model.startServing() }
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                    // Said here rather than in the header. Driving this found the
                    // same shape as the publish refusal: the button is at the
                    // bottom of a page that scrolls and the header is a long way
                    // above it, so "the round is still open, starting again
                    // continues it" was announced where nobody could read it.
                    if let open = model.rounds.first(where: \.isOpen) {
                        Label(t("A collection wave is still open (started \(open.openedAt.formatted(date: .abbreviated, time: .shortened)) · \(open.submissions) responses) — starting the server again continues that wave rather than beginning a new one",
                                "Shown when a wave was left open. Placeholders: when it started and how many responses it has."),
                              systemImage: "pause.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(localised: "LAN-only by default, with no built-in tunnel — putting it on the internet has to be your own router configuration · this server exposes no admin page to the web and responses cannot be read back out through it · high-stakes work should still use a service that has been security-reviewed (R11)",
                     "States the security posture of the response server plainly.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Research question → construct. The chain §20.3 asks for, built from the top
    /// so that by the time somebody writes a question there is something to tie it
    /// to.
    @ViewBuilder
    private func chainBox(_ instrument: Instrument) -> some View {
        GroupBox(t("Research questions and what will be measured",
                   "Box heading over research questions and constructs.")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(instrument.researchQuestions) { question in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RQ: \(question.text.thai)").font(.callout)
                        ForEach(instrument.constructs.filter { $0.researchQuestionID == question.id }) { construct in
                            Text(localised: "   ↳ \(construct.name.thai) — measured by \(instrument.items(measuring: construct.id).count) questions",
                                 "A construct under a research question. Placeholders: its name and how many questions measure it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if instrument.researchQuestions.isEmpty {
                    Text(localised: "No research question yet — a construct must be tied to one",
                         "Shown when there are no research questions to attach constructs to.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    TextField(t("New research question", "Text field for adding a research question."),
                              text: $newQuestion)
                        .textFieldStyle(.roundedBorder)
                    Button(t("Add RQ", "Button that adds a research question. RQ is the standard abbreviation.")) {
                        let text = newQuestion
                        newQuestion = ""
                        Task { await model.addResearchQuestion(text) }
                    }
                    .disabled(newQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)

                if !instrument.researchQuestions.isEmpty {
                    HStack {
                        TextField(t("Construct to measure",
                                    "Text field naming a construct. 'Construct' is the research term."),
                                  text: $newConstruct)
                            .textFieldStyle(.roundedBorder)
                        TextField(t("Definition", "Text field: what the construct means."),
                                  text: $newConstructDefinition)
                            .textFieldStyle(.roundedBorder)
                        Picker(t("Answers RQ", "Picker: which research question this construct answers."),
                               selection: $constructQuestionID) {
                            Text(localised: "— choose an RQ —", "Picker option before a research question is chosen.")
                                .tag(String?.none)
                            ForEach(instrument.researchQuestions) { question in
                                Text(question.text.thai).tag(String?.some(question.id))
                            }
                        }
                        .labelsHidden().frame(maxWidth: 200)
                        .accessibilityLabel(t("Research question this construct answers", "Screen-reader label."))
                        Button(t("Add construct", "Button that adds a construct.")) {
                            guard let questionID = constructQuestionID else { return }
                            let name = newConstruct
                            let definition = newConstructDefinition
                            newConstruct = ""
                            newConstructDefinition = ""
                            Task {
                                await model.addConstruct(name: name, definition: definition,
                                                         questionID: questionID)
                            }
                        }
                        .disabled(constructQuestionID == nil
                                  || newConstruct.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func itemsBox(_ instrument: Instrument) -> some View {
        GroupBox(t("Questions", "Box heading over the instrument's items.")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(instrument.ordered) { item in
                    HStack(spacing: 6) {
                        Text("\(item.order).").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.prompt.thai).font(.callout)
                            Text(label(for: item, in: instrument))
                                .font(.caption2)
                                .foregroundStyle(item.constructID == nil && !item.isDemographic
                                                 ? Color.orange : Color.secondary)
                        }
                        Spacer()
                        Button { Task { await model.removeItem(item.id) } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(t("Delete question \(item.prompt.thai)",
                                              "Screen-reader label. Placeholder is the question text."))
                    }
                }
                if instrument.items.isEmpty {
                    Text(localised: "No questions yet", "Shown when the instrument has no items.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    TextField(t("New question", "Text field for adding an item to the instrument."),
                              text: $newItem)
                        .textFieldStyle(.roundedBorder)
                    Picker(t("Kind", "Picker: what kind of question this is."), selection: $newItemKind) {
                        ForEach(ItemKindChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 150)
                    .accessibilityLabel(t("Kind of question", "Screen-reader label for the question kind picker."))
                    Picker(t("Measures construct", "Picker: which construct this question measures."),
                           selection: $newItemConstruct) {
                        Text(localised: "— not tied —", "Picker option: this question measures no construct.")
                            .tag(String?.none)
                        ForEach(instrument.constructs) { construct in
                            Text(construct.name.thai).tag(String?.some(construct.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 170)
                    .accessibilityLabel(t("Construct this question measures", "Screen-reader label."))
                    Toggle(t("Demographic", "Checkbox marking a question as background information rather than a measure."),
                           isOn: $newItemDemographic)
                        .toggleStyle(.checkbox)
                    Button(t("Add question", "Button that adds the item to the instrument.")) {
                        let prompt = newItem
                        let kind = newItemKind.kind(first: newItemFirstList,
                                                     second: newItemSecondList)
                        let construct = newItemConstruct
                        let demographic = newItemDemographic
                        newItem = ""
                        newItemFirstList = ""
                        newItemSecondList = ""
                        Task {
                            await model.addItem(prompt: prompt, kind: kind,
                                                constructID: construct,
                                                demographic: demographic)
                        }
                    }
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)

                // Only for the kinds that need it, and labelled with what the
                // list is for: two unexplained text boxes under a picker are
                // two boxes somebody leaves empty.
                if let labels = newItemKind.listLabels {
                    HStack(alignment: .top, spacing: Space.row) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(labels.first).font(.caption2).foregroundStyle(.secondary)
                            TextEditor(text: $newItemFirstList)
                                .font(.callout).frame(height: 60)
                                .accessibilityLabel(labels.first)
                        }
                        if let second = labels.second {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(second).font(.caption2).foregroundStyle(.secondary)
                                TextEditor(text: $newItemSecondList)
                                    .font(.callout).frame(height: 60)
                                    .accessibilityLabel(second)
                            }
                        }
                    }
                    .controlSize(.small)
                }

                Text(localised: "A question tied to no construct must be marked “Demographic” — one that measures nothing is a column no analysis can use (§20.3) · it can be saved, but it will not pass publication",
                     "Explains why every question needs either a construct or the demographic flag.")
                    .font(.caption2).foregroundStyle(.secondary)

                if !model.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.problems) { problem in
                            Text("• " + problem.text)
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func ethicsBox(_ instrument: Instrument) -> some View {
        GroupBox(t("Consent and ethics", "Box heading over consent text and ethics approval.")) {
            VStack(alignment: .leading, spacing: 8) {
                if let consent = instrument.consent, consent.isComplete, !editingConsent {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localised: "The consent page is complete · contact \(consent.contact)",
                                 "Shown when consent text exists. Placeholder is the researcher's contact.")
                                .font(.callout)
                            Text(consent.purpose.thai).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(t("Edit the text", "Button that opens the consent editor.")) {
                            consentDraft = ConsentDraft(purpose: consent.purpose.thai,
                                                        collected: consent.whatIsCollected.thai,
                                                        voluntary: consent.voluntary.thai,
                                                        contact: consent.contact)
                            editingConsent = true
                        }
                        .controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(t("Purpose of the collection", "Consent field: why data is being collected."),
                                  text: $consentDraft.purpose)
                            .textFieldStyle(.roundedBorder)
                        TextField(t("What is collected", "Consent field: which data is gathered."),
                                  text: $consentDraft.collected)
                            .textFieldStyle(.roundedBorder)
                        TextField(t("Statement on voluntariness and withdrawal",
                                    "Consent field: that taking part is voluntary and can be withdrawn."),
                                  text: $consentDraft.voluntary)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            TextField(t("How to contact the researcher", "Consent field: contact details."),
                                      text: $consentDraft.contact)
                                .textFieldStyle(.roundedBorder)
                            Button(t("Save the consent text", "Button that stores the consent page.")) {
                                let draft = consentDraft
                                editingConsent = false
                                Task {
                                    await model.setConsent(ConsentText(
                                        purpose: Bilingual(draft.purpose),
                                        whatIsCollected: Bilingual(draft.collected),
                                        voluntary: Bilingual(draft.voluntary),
                                        contact: draft.contact))
                                }
                            }
                            .disabled(!consentDraft.isReady)
                        }
                    }
                    .controlSize(.small)
                }

                Divider()
                if let ethics = instrument.ethics, ethics.isComplete, !editingEthics {
                    HStack {
                        Text(ethics.summary).font(.callout)
                        Spacer()
                        Button(t("Edit the record", "Button that opens the ethics record editor.")) {
                            ethicsDraft = EthicsDraft(ethics)
                            editingEthics = true
                        }
                        .controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(t("Which kind", "Picker: whether there is an approval number or an exemption."),
                               selection: $ethicsDraft.isApproved) {
                            Text(localised: "There is an ethics approval number",
                                 "Ethics option: the study was approved by a committee.")
                                .tag(true)
                            Text(localised: "Declared not to be human-subjects research",
                                 "Ethics option: the study is exempt.")
                                .tag(false)
                        }
                        .pickerStyle(.radioGroup)
                        .accessibilityLabel(t("Kind of ethics record", "Screen-reader label."))
                        if ethicsDraft.isApproved {
                            HStack {
                                TextField(t("Committee", "Ethics field: which body approved it."),
                                          text: $ethicsDraft.committee)
                                    .textFieldStyle(.roundedBorder)
                                TextField(t("Approval number", "Ethics field: the approval's reference."),
                                          text: $ethicsDraft.number)
                                    .textFieldStyle(.roundedBorder)
                            }
                        } else {
                            TextField(t("Why it is exempt", "Ethics field: the reason for exemption."),
                                      text: $ethicsDraft.reason)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            TextField(t("Name of who declared it", "Ethics field: who made the declaration."),
                                      text: $ethicsDraft.declaredBy)
                                .textFieldStyle(.roundedBorder)
                            Button(t("Save the ethics record", "Button that stores the ethics record.")) {
                                let draft = ethicsDraft
                                editingEthics = false
                                Task {
                                    await model.setEthics(draft.isApproved
                                        ? .approved(committee: draft.committee,
                                                    number: draft.number,
                                                    date: Date(),
                                                    declaredBy: draft.declaredBy)
                                        : .notHumanSubjects(reason: draft.reason,
                                                            declaredBy: draft.declaredBy))
                                }
                            }
                            .disabled(!ethicsDraft.isReady)
                        }
                    }
                    .controlSize(.small)
                }
                Text(localised: "Both are checked at the gate, not on this screen — a screen that checks for itself is a screen another way in can bypass (§20.5)",
                     "Explains where consent and ethics are really enforced.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Expert ratings, one row per item. §20.4's IOC in the form a panel actually
    /// fills in: +1 congruent, 0 unsure, −1 not congruent.
    @ViewBuilder
    private func validityBox(_ instrument: Instrument) -> some View {
        GroupBox(t("Content validity (rated by experts)",
                   "Box heading over expert ratings of each question.")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(t("Name of the expert rating now", "Text field naming who is giving the ratings."),
                              text: $expert)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Text(model.validity?.summary
                         ?? t("no assessment yet", "Shown before any expert has rated the instrument."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .controlSize(.small)

                // Demographic items are not on this list on purpose: IOC scores an
                // item against what it claims to measure, and those claim nothing
                // (§20.4). Asking a panel to score them would have made the gate
                // unpassable until somebody invented a number.
                ForEach(instrument.itemsUnderContentReview) { item in
                    HStack(spacing: 6) {
                        Text(item.prompt.thai).font(.caption)
                            .frame(width: 240, alignment: .leading).lineLimit(1)
                        ForEach([1, 0, -1], id: \.self) { score in
                            Button(score == 1 ? "+1" : (score == 0 ? "0" : "−1")) {
                                let name = expert
                                Task {
                                    await model.rate(item: item.id, expert: name,
                                                     congruence: score,
                                                     relevance: score == 1 ? 4 : (score == 0 ? 3 : 1))
                                }
                            }
                            .controlSize(.mini)
                            .disabled(expert.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel(t("Give \(score) to the question \(item.prompt.thai)",
                                                  "Screen-reader label. Placeholders: the score and the question text."))
                        }
                        if let verdict = model.validity?.items.first(where: { $0.itemID == item.id }) {
                            Text(verdict.ioc.map { String(format: "IOC %.2f", $0) }
                                 ?? t("no rating yet", "Shown for a question nobody has rated."))
                                .font(.caption2)
                                .foregroundStyle(verdict.passes ? Color.green : Color.orange)
                            Text(localised: "\(verdict.raters) raters",
                                 "How many experts rated a question. Placeholder is a count.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                if instrument.itemsUnderContentReview.isEmpty && !instrument.items.isEmpty {
                    Text(localised: "Every question here is demographic, so there is nothing for an expert to rate for validity",
                         "Shown when no question makes a measurement claim.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(localised: "IOC ≥ 0.50 per question · I-CVI ≥ 0.78 · S-CVI/Ave ≥ 0.90 · at least \(ContentValidity.minimumPanel) experts — thresholds from the literature, deliberately not adjustable from this screen · questions marked “Demographic” need no rating, because they claim to measure nothing",
                     "The content-validity thresholds. The statistic names are standard and stay as they are. Placeholder is the minimum panel size.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func gateBox() -> some View {
        GroupBox(t("The gate before collection starts",
                   "Box heading over what must be true before an instrument may be used.")) {
            VStack(alignment: .leading, spacing: 6) {
                if let gate = model.gate {
                    ForEach(Array(gate.conditions.enumerated()), id: \.offset) { _, condition in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: condition.satisfied
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(condition.satisfied ? Color.green : Color.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(condition.text).font(.callout)
                                if let detail = condition.detail {
                                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                HStack {
                    TextField(t("Name of the approver", "Text field naming who signs off the instrument."),
                              text: $approver)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    Button(t("Publish the instrument", "Button that approves the instrument for use.")) {
                        let person = approver
                        Task { await model.publish(by: person) }
                    }
                    .disabled(approver.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isApproved)
                    Button(t("New version", "Button that opens an editable copy of an approved instrument.")) {
                        Task { await model.newVersion() }
                    }
                    Spacer()
                }
                .controlSize(.small)

                if let approval = model.approval {
                    Text("\(approval.summary) · \(approval.validity)")
                        .font(.callout).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Beside the button, not only in the header: this box is at the
                // bottom of a page that scrolls, and an answer the presser has to
                // scroll up to find reads as "nothing happened".
                if let refusal = model.refusal {
                    Text(refusal)
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(localised: "An instrument that has not passed this gate **has no form the server will accept** — not a rule to remember, but something that does not compile (§20.6)",
                     "Says that the gate is enforced by the type system, not by discipline.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(for item: Item, in instrument: Instrument) -> String {
        var parts = [item.kind.label]
        if let constructID = item.constructID,
           let construct = instrument.constructs.first(where: { $0.id == constructID }) {
            parts.append(t("measures \(construct.name.thai)",
                           "Screen-reader detail on a question. Placeholder is the construct's name."))
        } else if item.isDemographic {
            parts.append(t("Demographic",
                           "Checkbox marking a question as background information rather than a measure."))
        } else {
            parts.append(t("tied to nothing — will not pass publication",
                           "Screen-reader detail on a question that measures nothing and is not marked demographic."))
        }
        return parts.joined(separator: " · ")
    }
}
