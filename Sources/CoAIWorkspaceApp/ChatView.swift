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

struct ChatView: View {
    @State private var model: ChatViewModel
    @State private var choosingFolder = false

    init(engine: Engine) {
        _model = State(initialValue: ChatViewModel(engine: engine))
    }

    var body: some View {
        NavigationSplitView {
            conversationList
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                if let request = model.pendingApproval {
                    Divider()
                    ApprovalBanner(request: request,
                                   edit: $model.approvalEdit,
                                   isEditing: $model.editingApproval,
                                   respond: model.respond)
                }
                Divider()
                composer
            }
        }
        .task { await model.load() }
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
                        BubbleView(bubble: bubble).id(bubble.id)
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

    private var composer: some View {
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
        .padding(16)
    }
}

// MARK: - one message

private struct BubbleView: View {
    let bubble: ChatViewModel.Bubble

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
                Image(systemName: bubble.blocked ? "hand.raised.fill" : "wrench.and.screwdriver")
                Text(bubble.toolName ?? "tool").fontWeight(.medium)
                if bubble.blocked {
                    Text("ไม่ได้รัน").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("ผลจากเครื่องมือ \(bubble.toolName ?? "")")
    }
}
