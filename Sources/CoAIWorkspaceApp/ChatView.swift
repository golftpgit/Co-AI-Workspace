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

/// Owns the one view model this window uses.
///
/// It is built in `task`, not in `init`: `init` runs on every body pass, and a
/// view model built there subscribed a fresh approval channel each time under
/// the same id. The broker kept the newest — an instance SwiftUI had already
/// thrown away — so approvals were delivered to nothing and turns hung with no
/// banner on screen. One instance, created once, attached once.
struct ChatView: View {
    let engine: Engine
    @State private var model: ChatViewModel?

    var body: some View {
        Group {
            if let model {
                ChatScreen(model: model)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            guard model == nil else { return }
            let created = ChatViewModel(engine: engine)
            model = created
            await created.attach()
            await created.load()
        }
    }
}

private struct ChatScreen: View {
    @Bindable var model: ChatViewModel
    @State private var choosingFolder = false

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
    }

    // MARK: - sidebar

    private var conversationList: some View {
        List(selection: Binding(get: { model.selected?.id },
                                set: { id in
                                    guard let conversation = model.conversations.first(where: { $0.id == id })
                                    else { return }
                                    Task { await model.select(conversation) }
                                })) {
            ForEach(model.conversations) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title ?? "บทสนทนาใหม่").lineLimit(1)
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(conversation.id)
                .contextMenu {
                    Button("ลบบทสนทนา", role: .destructive) {
                        Task { await model.delete(conversation) }
                    }
                }
                .accessibilityAction(named: "ลบบทสนทนานี้") {
                    Task { await model.delete(conversation) }
                }
            }
        }
        .navigationTitle("บทสนทนา")
        .toolbar {
            Button { Task { await model.newConversation() } } label: {
                Label("บทสนทนาใหม่", systemImage: "square.and.pencil")
            }
            .accessibilityLabel("สร้างบทสนทนาใหม่")
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

            Button { choosingFolder = true } label: {
                Label(model.workingDirectory?.lastPathComponent ?? "เลือกโฟลเดอร์งาน",
                      systemImage: "folder")
            }
            .accessibilityLabel("เลือกโฟลเดอร์ที่ให้รันคำสั่ง")

            if let routed = model.routedVia {
                Text(routed).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("ตอบโดย \(routed)")
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
        case .note:
            Label(bubble.text, systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .failure:
            Label(bubble.text, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    /// Collapsed by default with the raw output one click away — §14.2 asks for
    /// exactly this, because unsummarised tool output is long by design.
    private var toolCard: some View {
        DisclosureGroup {
            Text(bubble.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    private var status: String {
        if awaitingApproval { return "รออนุมัติจากคุณ" }
        if bubble.running { return "กำลังทำงาน…" }
        return bubble.blocked ? "ไม่ได้รัน" : "เสร็จแล้ว"
    }
}
