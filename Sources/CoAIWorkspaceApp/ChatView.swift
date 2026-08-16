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

    var body: some View {
        ChatScreen(model: model, promote: promote)
            // Idempotent, and it has to be: this runs again every time the view
            // is rebuilt, and a second subscribe would be the same delivered-to-
            // nobody bug arriving the other way round.
            .task { await model.prepare() }
    }
}

private struct ChatScreen: View {
    @Bindable var model: ChatViewModel
    let promote: (DraftedBrief, String?) async -> Void
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
            Picker("ใบงาน", selection: $model.workPackage) {
                Text("ไม่ผูกกับใบงาน").tag(String?.none)
                ForEach(model.workPackages) { package in
                    Text(package.title).tag(String?.some(package.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .labelsHidden()
            .accessibilityLabel("เลือกใบงานที่การสนทนานี้ทำอยู่")
            .help("เวลาและค่าใช้จ่ายของเทิร์นนี้จะถูกนับเข้าใบงานที่เลือก")
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
                Label("ยกระดับเป็นโปรเจกต์", systemImage: "square.stack.3d.up")
            }
            .disabled(drafting)
            .accessibilityLabel("ยกระดับบทสนทนานี้เป็นโปรเจกต์")
        }
    }

    // MARK: - sidebar

    private var conversationList: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            conversationRows
        }
        .navigationTitle("บทสนทนา")
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
                Text("บทสนทนา").font(.subheadline).bold()
                Spacer()
                Button { Task { await model.newConversation() } } label: {
                    Label("บทสนทนาใหม่", systemImage: "square.and.pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("สร้างบทสนทนาใหม่")
            }
            HStack(spacing: 6) {
                TextField("ค้นในบทสนทนา", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.search() } }
                    .accessibilityLabel("ค้นข้อความในบทสนทนาเก่า")
                if !model.query.isEmpty {
                    Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("ล้างคำค้น")
                }
            }
            // A different question, not a wider default: inside a project the
            // list belongs to the project.
            Toggle("ค้นข้ามโปรเจกต์", isOn: $model.searchesEverywhere)
                .font(.caption)
                .toggleStyle(.checkbox)
                .onChange(of: model.searchesEverywhere) { _, _ in
                    Task { await model.search() }
                }
        }
        .padding(10)
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
                        Text(match.conversation.title ?? "บทสนทนาใหม่")
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
                                .accessibilityLabel("ปักหมุดไว้")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title ?? "บทสนทนาใหม่").lineLimit(1)
                            Text(conversation.updatedAt, format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(conversation.id)
                    .contextMenu {
                        Button(conversation.pinned ? "เลิกปักหมุด" : "ปักหมุด") {
                            Task { await model.togglePin(conversation) }
                        }
                        Button("ลบบทสนทนา", role: .destructive) {
                            Task { await model.delete(conversation) }
                        }
                    }
                    .accessibilityAction(named: conversation.pinned ? "เลิกปักหมุด" : "ปักหมุดบทสนทนานี้") {
                        Task { await model.togglePin(conversation) }
                    }
                    .accessibilityAction(named: "ลบบทสนทนานี้") {
                        Task { await model.delete(conversation) }
                    }
                }
            }
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 14) {
            Picker("ระดับการทำงานเอง", selection: $model.modes.autonomy) {
                ForEach(OperatingModes.Autonomy.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)

            Toggle("Plan-only", isOn: $model.modes.planOnly)
                .help("คิดและเสนอแผนได้ แต่ไม่รันเครื่องมือใด ๆ ทั้ง session")
            Toggle("Run-until-done", isOn: $model.modes.runUntilDone)
                .help("ทำงานต่อกันหลายขั้นโดยไม่รอให้พิมพ์ใหม่")

            Spacer()

            workPackagePicker

            promotionButton

            Button { choosingFolder = true } label: {
                Label(model.workingDirectory?.lastPathComponent ?? "เลือกโฟลเดอร์งาน",
                      systemImage: "folder")
            }
            .accessibilityLabel("เลือกโฟลเดอร์ที่ให้รันคำสั่ง")

            if let routed = model.routedVia {
                // §24.3 / P20.5 — the tier, and why that tier. The reason is
                // the router's own selection pass, so it is worth showing:
                // a sentence a model wrote about its own choice would not be.
                Text(routed).font(.caption).foregroundStyle(.secondary)
                    .help(model.routedWhy.joined(separator: "\n"))
                    .accessibilityLabel("ตอบโดย \(routed)")
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
                        Text("ยังไม่มีข้อความในบทสนทนานี้ — พิมพ์ด้านล่างเพื่อเริ่ม "
                             + "หรือกด ✎ ที่หัวรายการทางซ้ายเพื่อเปิดบทสนทนาใหม่")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.bubbles) { bubble in
                        // "กำลังทำงาน…" on a card that is really waiting for a
                        // human tells the user nothing about why nothing is
                        // happening. Say which of the two it is.
                        BubbleView(bubble: bubble,
                                   awaitingApproval: bubble.running
                                       && model.pendingApproval?.toolName == bubble.toolName)
                            .id(bubble.id)
                    }
                }
                .padding(20)
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
                TextField("พิมพ์ข้อความ…", text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { Task { await model.send() } }
                    .accessibilityLabel("ข้อความถึงผู้ช่วย")

                if model.isRunning {
                    Button(role: .destructive) { model.stop() } label: {
                        Label("หยุด", systemImage: "stop.fill")
                    }
                    .accessibilityLabel("หยุดการทำงานรอบนี้")
                } else {
                    Button { Task { await model.send() } } label: {
                        Label("ส่ง", systemImage: "arrow.up.circle.fill")
                    }
                    .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("ส่งข้อความ")
                }
            }
            composerFooter
        }
        .padding(16)
        .task { await model.refreshLocalModels() }
    }

    private var composerFooter: some View {
        HStack(spacing: 10) {
            localModelPicker
            if model.localModelResident {
                // The eject button, in the sense LM Studio means it: the
                // weights are holding gigabytes and the user may want them
                // back without quitting anything.
                Button("ปลดจากหน่วยความจำ") { Task { await model.unloadLocalModel() } }
                    .buttonStyle(.link)
                    .accessibilityLabel("ปลดโมเดลออกจากหน่วยความจำ")
            }
            Spacer()
            if model.contextBudget > 0 {
                Text("บริบท \(compact(model.contextTokens)) / \(compact(model.contextBudget))")
                    .monospacedDigit()
                    .foregroundStyle(model.contextTokens > model.contextBudget * 3 / 4
                                     ? Color.orange : Color.secondary)
                    // Orange from the point compaction starts (§5.6 compacts at
                    // 75%), so the summarising is never a surprise.
                    .help("ระบบจะย่อบทสนทนาเมื่อถึง 75% ของงบ")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var localModelPicker: some View {
        if model.localModels.isEmpty {
            Label("ยังไม่มีโมเดลบนเครื่อง", systemImage: "cpu")
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
                Label(model.localModelName.map(shortModelName) ?? "เลือกโมเดล",
                      systemImage: model.localModelResident ? "cpu.fill" : "cpu")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("โมเดลบนเครื่องสำหรับ Tier 0.5" +
                  (model.localModelResident ? " — โหลดอยู่ในหน่วยความจำ" : ""))
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
                    .padding(10)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
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
    /// "12 วินาที" is the thing somebody watching a spinner wants to know.
    private var reasoningCard: some View {
        DisclosureGroup {
            Text(bubble.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.tight)
        } label: {
            Label(String(format: "คิดอยู่ %.0f วินาที", bubble.seconds),
                  systemImage: "brain")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Space.row)
        .accessibilityLabel(String(format: "ความคิดของโมเดล %.0f วินาที", bubble.seconds))
        .accessibilityHint("กางเพื่ออ่าน — ส่วนนี้ไม่ใช่คำตอบ และไม่ถูกบันทึกไว้ในบทสนทนา")
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
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("เครื่องมือ \(bubble.toolName ?? "") — \(status)")
        .accessibilityHint(bubble.why.joined(separator: " · "))
    }

    private var status: String {
        if awaitingApproval { return "รออนุมัติจากคุณ" }
        if bubble.running { return "กำลังทำงาน…" }
        return bubble.blocked ? "ไม่ได้รัน" : "เสร็จแล้ว"
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
            Text("ยกระดับบทสนทนานี้เป็นโปรเจกต์").font(.headline)
            Text("ร่างจากสิ่งที่คุยกันไว้ — แก้ได้ทุกช่องก่อนสร้าง")
                .font(.callout).foregroundStyle(.secondary)

            TextField("ชื่อโปรเจกต์", text: $name)
                .textFieldStyle(.roundedBorder)

            field("เหตุผลที่ทำ", text: $brief, height: 54)
            field("ขอบเขต — ทำ (บรรทัดละข้อ)", text: $inScope, height: 54)
            field("ขอบเขต — ไม่ทำ (บรรทัดละข้อ)", text: $outOfScope, height: 54)

            if !draft.openQuestions.isEmpty {
                GroupBox("บทสนทนายังไม่ได้ตอบ") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(draft.openQuestions, id: \.self) { question in
                            Text("• " + question).font(.callout)
                        }
                        Text("สร้างได้เลย แล้วเติมทีหลังก็ได้ — แต่ G1 จะยังไม่ผ่านจนกว่าจะครบ")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button("ยกเลิก", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("สร้างโปรเจกต์") { confirm(edited) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
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
