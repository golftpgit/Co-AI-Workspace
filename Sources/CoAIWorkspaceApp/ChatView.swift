import SwiftUI
import UniformTypeIdentifiers
import AgentKit
import CoreEngine

// ─────────────────────────────────────────────────────────────
// The Chat screen (ARCHITECTURE §14.2): conversation sidebar, streaming
// transcript, the three mode switches in the header where they are always
// visible, and the approval banner inline — the same component the Approvals
// page and the workflow step card will reuse (§5.4).
//
// Accessibility is written in from the start, not retrofitted: every icon-only
// control carries a label, because v1 shipped without any and had to be fixed
// across 16 buttons afterwards.
// ─────────────────────────────────────────────────────────────

/// Draws the conversation of one workspace.
///
/// **The model is not built here** (§19.1.1, P21.2). It used to be — in `task`
/// rather than `init`, because `init` runs on every body pass and a model built
/// there subscribed a fresh approval channel each time, so approvals were
/// delivered to an instance SwiftUI had already thrown away and turns hung with
/// no banner on screen.
///
/// Building it once per view was not enough, because the view's identity is the
/// workspace: switching tabs threw the model away, and with it the turn that was
/// streaming into it. The model now belongs to the workspace (`WorkspaceModels`)
/// and outlives every rebuild of this view, which is what makes a turn started
/// in one project survive a look at another.
struct ChatView: View {
    @Bindable var model: ChatViewModel
    /// Called when the user promotes this conversation (§19.1, P10.3). Owned
    /// by the root view because creating a project changes which workspace the
    /// whole app is in, which is not chat's decision to make.
    let promote: (DraftedBrief, String?) async -> Void
    /// Bumped whenever the model chain changes, so the switch in the composer
    /// can refresh without the view being rebuilt (AUDIT F-1).
    var modelChainGeneration: Int = 0

    var body: some View {
        ChatScreen(model: model, promote: promote,
                   modelChainGeneration: modelChainGeneration)
            // Idempotent, and it has to be: this runs again every time the view
            // is rebuilt, and a second subscribe would be the same delivered-to-
            // nobody bug arriving the other way round.
            .task { await model.prepare() }
    }
}

private struct ChatScreen: View {
    @Bindable var model: ChatViewModel
    let promote: (DraftedBrief, String?) async -> Void
    var modelChainGeneration: Int = 0
    @State private var choosingFolder = false
    @State private var draft: DraftedBrief?
    @State private var drafting = false

    var body: some View {
        NavigationSplitView {
            conversationList
        } detail: {
            // Layout priority, not `fixedSize`. Header, banner and composer
            // must always be on screen; the transcript is the one thing that
            // can give up space, because it scrolls. `fixedSize` here did the
            // opposite — it pinned the banner to its ideal height, the
            // transcript kept its full content height too, and the stack asked
            // for 1214pt inside a 772pt window. SwiftUI centred the overflow,
            // so the header slid above the title bar and the banner and
            // composer slid below the bottom edge: the approval was rendered
            // and un-clickable, and the turn looked hung.
            VStack(spacing: 0) {
                header.layoutPriority(1)
                Divider()
                transcript.frame(maxHeight: .infinity).layoutPriority(0)
                if let request = model.pendingApproval {
                    Divider()
                    ApprovalBanner(request: request,
                                   edit: $model.approvalEdit,
                                   isEditing: $model.editingApproval,
                                   respond: model.respond)
                        .layoutPriority(1)
                }
                Divider()
                composer.layoutPriority(1)
            }
        }
        .fileImporter(isPresented: $choosingFolder,
                      allowedContentTypes: [.folder]) { result in
            // Picking the folder is what grants the sandbox access to it, so
            // this is also how `run_shell` gets somewhere it may write.
            if case .success(let url) = result { model.workingDirectory = url }
        }
        .sheet(item: $draft) { drafted in
            PromotionSheet(draft: drafted) { edited in
                let conversationID = model.promotableConversationID
                draft = nil
                Task { await promote(edited, conversationID) }
            } cancel: {
                draft = nil
            }
        }
    }

    /// Only inside a project, and only when the plan has open work. Choosing
    /// nothing is a legitimate state: a question is not work against a promise
    /// (§19.6).
    @ViewBuilder
    private var workPackagePicker: some View {
        if !model.workPackages.isEmpty {
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
            .frame(maxWidth: 220)
            .labelsHidden()
            .accessibilityLabel(t("Choose the work package this conversation is working on",
                                  "Screen-reader label for the work package picker."))
            .help(t("Time and cost of this turn are counted against the work package you pick",
                    "Tooltip explaining the consequence of choosing a work package."))
        }
    }

    /// Only in General, and only with something to promote. A project cannot
    /// be promoted again, and an empty conversation has nothing to draft from.
    @ViewBuilder
    private var promotionButton: some View {
        if model.promotableConversationID != nil, !model.transcriptTurns.isEmpty {
            Button {
                drafting = true
                Task {
                    draft = await model.draftBrief()
                    drafting = false
                }
            } label: {
                Label(t("Promote to project", "Button: turn this chat into a tracked project."),
                      systemImage: "square.stack.3d.up")
            }
            .disabled(drafting)
            .accessibilityLabel(t("Promote this conversation to a project",
                                  "Screen-reader label for the promote button."))
        }
    }

    // MARK: - sidebar

    private var conversationList: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            conversationRows
        }
        .navigationTitle(t("Conversations", "Window title over the list of past conversations."))
    }

    // MARK: - history (§19.2.1)

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // §19.2.6 — "+" at the head of the list, not in the window toolbar.
            // Two reasons, and the second is why it moved: creating a
            // conversation happens in the context of this list, and in the
            // toolbar it was pushed into the `»` overflow the moment the area
            // switch arrived (P10.12) — a primary action behind a chevron.
            HStack(spacing: 6) {
                Text(localised: "Conversations", "Heading over the list of past conversations.")
                    .font(.subheadline).bold()
                Spacer()
                Button { Task { await model.newConversation() } } label: {
                    Label(t("New conversation", "Button: start an empty conversation."),
                          systemImage: "square.and.pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                // ⌘N, because Tab does not reach buttons on macOS unless the
                // person has turned Full Keyboard Access on — measured, not
                // assumed: a Tab walk of this screen stops at three places,
                // all of them text fields or the list (E.30). Starting a
                // conversation was mouse-only, which is §14.4's whole point.
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel(t("New conversation (⌘N)",
                                      "Screen-reader label naming the keyboard shortcut too."))
            }
            HStack(spacing: 6) {
                TextField(t("Search conversations", "Placeholder in the conversation search field."),
                          text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.search() } }
                    .accessibilityLabel(t("Search the text of past conversations",
                                          "Screen-reader label for the search field."))
                if !model.query.isEmpty {
                    Button { model.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .accessibilityLabel(t("Clear search",
                                                  "Screen-reader label for the button that empties the search field."))
                    }
                    .buttonStyle(.borderless)
                }
            }
            // A different question, not a wider default: inside a project the
            // list belongs to the project.
            Toggle(t("Search across projects",
                     "Checkbox: widen the search past the project you are inside."),
                   isOn: $model.searchesEverywhere)
                .font(.caption)
                .toggleStyle(.checkbox)
                .onChange(of: model.searchesEverywhere) { _, _ in
                    Task { await model.search() }
                }
        }
        .padding(Space.box)
        // Searches as you type, debounced. Driving it showed why: with Enter as
        // the only trigger there is no button, no spinner and no message — a
        // box that looks broken until you guess the keystroke. (And the first
        // attempt hung this off an `EmptyView`, which has no lifecycle to run
        // a task on, so it never fired at all — caught by driving it again.)
        .task(id: model.query) {
            guard !model.query.trimmingCharacters(in: .whitespaces).isEmpty else {
                model.clearSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.search()
        }
    }

    @ViewBuilder
    private var conversationRows: some View {
        if !model.matches.isEmpty {
            List(model.matches) { match in
                Button {
                    Task { await model.select(match.conversation) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.conversation.title ?? t("New conversation", "Stand-in title for a conversation nobody has named yet."))
                            .lineLimit(1).font(.callout)
                        // The line that matched, because "which conversations
                        // exist" is not the question somebody searching asked.
                        Text(match.snippet).font(.caption)
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        } else {
            List(selection: Binding(get: { model.selected?.id },
                                    set: { id in
                                        guard let conversation = model.conversations.first(where: { $0.id == id })
                                        else { return }
                                        Task { await model.select(conversation) }
                                    })) {
                ForEach(model.conversations) { conversation in
                    HStack(spacing: 6) {
                        if conversation.pinned {
                            Image(systemName: "pin.fill").font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(t("Pinned", "Screen-reader label on the pin marker beside a conversation."))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title ?? t("New conversation", "Stand-in title for a conversation nobody has named yet.")).lineLimit(1)
                            Text(conversation.updatedAt, format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(conversation.id)
                    .contextMenu {
                        Button(conversation.pinned
                               ? t("Unpin", "Context-menu item: stop keeping this conversation at the top.")
                               : t("Pin", "Context-menu item: keep this conversation at the top of the list.")) {
                            Task { await model.togglePin(conversation) }
                        }
                        Button(t("Delete conversation", "Context-menu item: remove this conversation for good."),
                               role: .destructive) {
                            Task { await model.delete(conversation) }
                        }
                    }
                    .accessibilityAction(named: conversation.pinned
                                         ? t("Unpin this conversation", "Screen-reader action name.")
                                         : t("Pin this conversation", "Screen-reader action name.")) {
                        Task { await model.togglePin(conversation) }
                    }
                    .accessibilityAction(named: t("Delete this conversation", "Screen-reader action name.")) {
                        Task { await model.delete(conversation) }
                    }
                }
            }
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 14) {
            Picker(t("Autonomy level", "Picker: how far the assistant may go without asking."),
                   selection: $model.modes.autonomy) {
                ForEach(OperatingModes.Autonomy.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)

            Toggle("Plan-only", isOn: $model.modes.planOnly)
                .help(t("May think and propose a plan, but runs no tools for the whole session",
                        "Tooltip on the Plan-only switch. 'Plan-only' is a mode name and stays untranslated."))
            Toggle("Run-until-done", isOn: $model.modes.runUntilDone)
                .help(t("Keeps working through several steps without waiting for you to type again",
                        "Tooltip on the Run-until-done switch. 'Run-until-done' is a mode name and stays untranslated."))

            Spacer()

            workPackagePicker

            promotionButton

            Button { choosingFolder = true } label: {
                Label(model.workingDirectory?.lastPathComponent
                      ?? t("Choose working folder", "Button when no folder has been granted yet."),
                      systemImage: "folder")
            }
            .accessibilityLabel(t("Choose the folder commands may run in",
                                  "Screen-reader label for the working-folder button."))

            if let routed = model.routedVia {
                // §24.3 / P20.5 — the tier, and why that tier. The reason is
                // the router's own selection pass, so it is worth showing:
                // a sentence a model wrote about its own choice would not be.
                Text(routed).font(.caption).foregroundStyle(.secondary)
                    .help(model.routedWhy.joined(separator: "\n"))
                    .accessibilityLabel(t("Answered by \(routed)",
                                          "Screen-reader label naming the tier that answered. Placeholder is a tier name."))
                    .accessibilityHint(model.routedWhy.joined(separator: " · "))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let error = model.loadError {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                    // An empty transcript used to be indistinguishable from a
                    // screen that failed to load — found by opening a project
                    // that has no conversations yet (U23-7). One line, and it
                    // points at the button that starts one.
                    if model.bubbles.isEmpty, model.loadError == nil {
                        Text(localised: "No messages here yet — type below to begin, or press ✎ at the top of the list on the left to open a new conversation",
                             "Shown in place of an empty transcript, so it cannot be mistaken for a screen that failed to load.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.bubbles) { bubble in
                        // "running…" on a card that is really waiting for a
                        // human tells the user nothing about why nothing is
                        // happening. Say which of the two it is.
                        BubbleView(bubble: bubble,
                                   awaitingApproval: bubble.running
                                       && model.pendingApproval?.toolName == bubble.toolName)
                            .id(bubble.id)
                    }
                }
                .padding(Space.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.bubbles.last?.text) {
                guard let last = model.bubbles.last?.id else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: - composer

    /// The model and the context meter live here, next to the text, rather
    /// than in a settings screen — both are facts about *this* turn, and both
    /// are what a person reaches for mid-conversation ("run this on something
    /// bigger", "how much room is left?"). Local model managers put them in
    /// the same place for the same reason.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(t("Type a message…", "Placeholder in the message composer."),
                          text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(Space.box)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.box))
                    .onSubmit { Task { await model.send() } }
                    .accessibilityLabel(t("Message to the assistant",
                                          "Screen-reader label for the composer text field."))

                // "Run this one on something bigger", which is what the
                // routing chain was correct about and unreachable for: it sends
                // every chat turn to the cheapest tier that can serve it, and
                // until now nothing let a person overrule that for one question
                // (E.36). Beside the text because it is a fact about this turn.
                Picker(t("Model", "Picker: which model answers this one question."),
                       selection: $model.chosenModel) {
                    Text(localised: "Automatic",
                         "Picker option: let the router choose the tier, which is the default.")
                        .tag(String?.none)
                    ForEach(model.offeredModels) { entry in
                        Text(entry.label).tag(String?.some(entry.identifier))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 210)
                .accessibilityLabel(t("Model that answers this question",
                                      "Screen-reader label for the per-turn model picker."))
                .accessibilityHint(t("Applies to this question only — if it cannot be reached, the usual order resumes",
                                     "Screen-reader hint explaining that the override is not sticky and not a guarantee."))

                if model.isRunning {
                    Button(role: .destructive) { model.stop() } label: {
                        Label(t("Stop", "Button that cancels the turn the assistant is running right now."), systemImage: "stop.fill")
                    }
                    .accessibilityLabel(t("Stop this turn",
                                          "Screen-reader label for the button that cancels the running turn."))
                } else {
                    Button { Task { await model.send() } } label: {
                        Label(t("Send", "Button that sends the typed message."),
                              systemImage: "arrow.up.circle.fill")
                    }
                    .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(t("Send message", "Screen-reader label for the send button."))
                }
            }
            composerFooter
        }
        .padding(Space.section)
        // `id:` rather than a bare `.task` plus an `.onChange`, because the two
        // of them together still miss the case this is for. Driving it found the
        // gap: the chain is rebuilt while the person is *on* the settings screen,
        // so chat is not in the view hierarchy and `.onChange` never sees the
        // value move; and coming back does not re-run a plain `.task`, because
        // the view's identity did not change. `task(id:)` runs on appear **and**
        // whenever the id differs from the last run, which covers both.
        .task(id: modelChainGeneration) {
            await model.refreshLocalModels()
            await model.refreshOfferedModels()
        }
    }

    private var composerFooter: some View {
        HStack(spacing: 10) {
            localModelPicker
            if model.localModelResident {
                // The eject button, in the sense LM Studio means it: the
                // weights are holding gigabytes and the user may want them
                // back without quitting anything.
                Button(t("Unload from memory",
                         "Link button: free the gigabytes the local model weights are holding.")) {
                    Task { await model.unloadLocalModel() }
                }
                    .buttonStyle(.link)
                    .accessibilityLabel(t("Unload the model from memory",
                                          "Screen-reader label for the unload button."))
            }
            Spacer()
            if model.contextBudget > 0 {
                Text(localised: "Context \(compact(model.contextTokens)) / \(compact(model.contextBudget))",
                     "Meter of tokens used against the prompt budget. Both placeholders are short token counts such as 1.2K.")
                    .monospacedDigit()
                    .foregroundStyle(model.contextTokens > model.contextBudget * 3 / 4
                                     ? Color.orange : Color.secondary)
                    // Orange from the point compaction starts (§5.6 compacts at
                    // 75%), so the summarising is never a surprise.
                    .help(t("The conversation is summarised once it reaches 75% of the budget",
                            "Tooltip on the context meter, so compaction is never a surprise."))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var localModelPicker: some View {
        if model.localModels.isEmpty {
            Label(t("No model on this machine",
                    "Shown where the local model picker would be when nothing is downloaded."),
                  systemImage: "cpu")
                .foregroundStyle(.orange)
        } else {
            Menu {
                ForEach(model.localModels, id: \.name) { local in
                    Button {
                        Task { await model.useLocalModel(local) }
                    } label: {
                        if local.name == model.localModelName {
                            Label(local.name, systemImage: "checkmark")
                        } else {
                            Text(local.name)
                        }
                    }
                }
            } label: {
                Label(model.localModelName.map(shortModelName)
                      ?? t("Choose model", "Menu label when no local model has been picked yet."),
                      systemImage: model.localModelResident ? "cpu.fill" : "cpu")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(t("On-device model for Tier 0.5",
                    "Tooltip on the local model menu. 'Tier 0.5' is the name of the guarantee floor and stays as is.")
                  + (model.localModelResident
                     ? t(" — loaded in memory", "Appended to the local model tooltip when the weights are resident.")
                     : ""))
        }
    }

    /// `mlx-community/Qwen3-VL-4B-Instruct-4bit` is the identity; the publisher
    /// is not what anyone reads at a glance.
    private func shortModelName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    private func compact(_ tokens: Int) -> String {
        tokens >= 1_000 ? String(format: "%.1fK", Double(tokens) / 1_000) : "\(tokens)"
    }
}

// MARK: - one message

private struct BubbleView: View {
    let bubble: ChatViewModel.Bubble
    var awaitingApproval = false

    var body: some View {
        switch bubble.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(bubble.text)
                    .padding(Space.box)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.sheet))
                    .textSelection(.enabled)
            }
        case .assistant:
            Text(bubble.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            toolCard
        case .reasoning:
            reasoningCard
        case .note:
            Label(bubble.text, systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .failure:
            Label(bubble.text, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    /// The model's thinking, collapsed (§14.2, U18).
    ///
    /// Streamed and shown rather than dropped, and kept out of the answer:
    /// this is a separate bubble because the moment thinking joins the reply it
    /// gets stored as the reply. It says how long rather than how much, since
    /// "12 seconds" is the thing somebody watching a spinner wants to know.
    private var reasoningCard: some View {
        DisclosureGroup {
            Text(bubble.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.tight)
        } label: {
            Label(String(format: t("Thinking for %.0f seconds",
                                   "Label on the collapsed reasoning card. Placeholder is a whole number of seconds."),
                                bubble.seconds),
                  systemImage: "brain")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Space.row)
        .accessibilityLabel(String(format: t("The model's thinking, %.0f seconds",
                                             "Screen-reader label for the reasoning card. Placeholder is a whole number of seconds."),
                                          bubble.seconds))
        .accessibilityHint(t("Expand to read — this is not the answer, and it is not stored in the conversation",
                             "Screen-reader hint telling the reader that reasoning is separate from the reply."))
    }

    /// Collapsed by default with the raw output one click away — §14.2 asks for
    /// exactly this, because unsummarised tool output is long by design.
    private var toolCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                // Why before what: the reason this ran at all is the part a
                // person cannot reconstruct from the output.
                if !bubble.why.isEmpty {
                    Text(bubble.why.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(bubble.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                if bubble.running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: bubble.blocked ? "hand.raised.fill" : "wrench.and.screwdriver")
                }
                Text(bubble.toolName ?? "tool").fontWeight(.medium)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Space.box)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.box))
        .accessibilityLabel(t("Tool \(bubble.toolName ?? "") — \(status)",
                              "Screen-reader label for a tool card. First placeholder is the tool name, second is its status."))
        .accessibilityHint(bubble.why.joined(separator: " · "))
    }

    private var status: String {
        if awaitingApproval {
            return t("waiting for your approval", "Tool card status: stopped until a person says yes.")
        }
        if bubble.running {
            return t("running…", "Tool card status: the tool is executing right now.")
        }
        return bubble.blocked
            ? t("did not run", "Tool card status: the call was refused or blocked.")
            : t("done", "Tool card status: the tool finished.")
    }
}

// ─────────────────────────────────────────────────────────────
// The promotion sheet (§19.1, P10.3).
//
// Everything the model drafted is editable, and the questions it could not
// answer are listed rather than left blank and hoped over — a form that looks
// complete when the conversation was not is how a scope statement ends up
// meaning nothing.
// ─────────────────────────────────────────────────────────────

private struct PromotionSheet: View {
    let draft: DraftedBrief
    let confirm: (DraftedBrief) -> Void
    let cancel: () -> Void

    @State private var name: String
    @State private var brief: String
    @State private var inScope: String
    @State private var outOfScope: String

    init(draft: DraftedBrief,
         confirm: @escaping (DraftedBrief) -> Void,
         cancel: @escaping () -> Void) {
        self.draft = draft
        self.confirm = confirm
        self.cancel = cancel
        _name = State(initialValue: draft.name)
        _brief = State(initialValue: draft.brief)
        _inScope = State(initialValue: draft.statement.inScope.joined(separator: "\n"))
        _outOfScope = State(initialValue: draft.statement.outOfScope.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localised: "Promote this conversation to a project",
                 "Title of the sheet that turns a chat into a tracked project.")
                .font(.headline)
            Text(localised: "Drafted from what you discussed — every field is editable before you create it",
                 "Subtitle of the promote sheet, making clear the draft is a starting point, not a decision.")
                .font(.callout).foregroundStyle(.secondary)

            TextField(t("Project name", "Text field in the promote sheet."), text: $name)
                .textFieldStyle(.roundedBorder)

            field(t("Why this is being done", "Field label in the promote sheet: the project brief."),
                  text: $brief, height: 54)
            field(t("Scope — in (one per line)", "Field label: what the project will do."),
                  text: $inScope, height: 54)
            field(t("Scope — out (one per line)", "Field label: what the project will not do."),
                  text: $outOfScope, height: 54)

            if !draft.openQuestions.isEmpty {
                GroupBox(t("The conversation did not answer these",
                           "Box heading over questions the chat left open.")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(draft.openQuestions, id: \.self) { question in
                            Text("• " + question).font(.callout)
                        }
                        Text(localised: "You can create it now and fill these in later — but G1 will not pass until they are answered",
                             "Note under the open questions. 'G1' is the name of the first gate and stays as is.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button(t("Cancel", "Button that closes the promote sheet without creating anything."),
                       role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(t("Create project", "Button that creates the project from the draft.")) { confirm(edited) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.section)
        .frame(width: 520)
    }

    private func field(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .frame(height: height)
                .font(.body)
                .accessibilityLabel(title)
        }
    }

    private var edited: DraftedBrief {
        DraftedBrief(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                     brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
                     statement: ScopeStatement(inScope: lines(inScope),
                                               outOfScope: lines(outOfScope)),
                     openQuestions: draft.openQuestions)
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
