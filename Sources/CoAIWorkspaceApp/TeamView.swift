import SwiftUI
import AgentKit
import CoreEngine

// ─────────────────────────────────────────────────────────────
// The Team screen (ARCHITECTURE §2.2, P4.7).
//
// The Done-when is that work running in parallel is visible from one place, so
// the list is the screen and everything else is around it. Three things are on
// every row because leaving any of them out sends the user somewhere else to
// find it:
//
//   which role holds it · how many attempts it has taken ·
//   and, when QA sent it back, the reasons it gave.
//
// "Escalated" without reasons is the state that made v1's loops unreadable, so
// the reasons are on the row rather than behind a disclosure.
// ─────────────────────────────────────────────────────────────

struct TeamView: View {
    @Bindable var model: TeamViewModel

    private var hasNoGoal: Bool {
        model.goal.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !model.draft.isEmpty {
                PlanEditor(model: model)
            } else if model.rows.isEmpty {
                ContentUnavailableView(
                    "ยังไม่มีงานของทีม",
                    systemImage: "person.3",
                    description: Text("พิมพ์เป้าหมายด้านบน แล้วให้หัวหน้าทีมวางแผนให้ "
                                      + "หรือข้ามหัวหน้าทีมแล้วสั่งผู้เชี่ยวชาญเอง — "
                                      + "ไม่ว่าทางไหน แผนจะมาให้แก้ก่อนเริ่มเสมอ"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let plan = model.plan { PlanSummary(plan: plan) }
                        ForEach(model.rows) { AssignmentRow(row: $0) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ทีม").font(.headline)
                if model.unfinishedCount > 0 {
                    Text("\(model.unfinishedCount) ยังไม่จบ")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("เป้าหมายของงานนี้ เช่น สรุปแนวทางการให้ยาปฏิชีวนะก่อนผ่าตัด",
                          text: $model.goal)
                    .textFieldStyle(.roundedBorder)
                    // Enter asks for a plan; it never starts work, because
                    // nothing starts before the user has seen the plan (§2.6).
                    .onSubmit { Task { await model.propose() } }
                    .disabled(model.isRunning)
                    .accessibilityLabel("เป้าหมายที่จะให้ทีมทำ")

                if model.isRunning {
                    ProgressView().controlSize(.small)
                    // Stopping is not the same as finishing, and the screen
                    // says so afterwards rather than clearing the rows.
                    Button("หยุด") { model.cancel() }
                        .accessibilityLabel("หยุดการทำงานของทีม")
                } else if model.draft.isEmpty {
                    if model.isPlanning { ProgressView().controlSize(.small) }
                    Button("ให้หัวหน้าทีมวางแผน") { Task { await model.propose() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(hasNoGoal || model.isPlanning)
                        .accessibilityLabel("ให้หัวหน้าทีมเสนอแผนสำหรับเป้าหมายนี้")

                    // §2.6's first row: the dropdown that skips the lead is
                    // still here, and is not a fallback for when planning fails.
                    Menu("ข้ามหัวหน้าทีม") {
                        ForEach(Role.assignable, id: \.self) { role in
                            Button(role.label) { model.draftDirect(role: role) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(hasNoGoal || model.isPlanning)
                    .accessibilityLabel("สั่งผู้เชี่ยวชาญคนเดียวโดยตรง")
                }
            }

            if let status = model.status {
                Label(status.message, systemImage: status.isError
                      ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(status.isError ? .orange : .secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }
}

// MARK: - editing the plan before it runs (§2.6)

/// The plan while it is still the user's. Nothing has been assigned yet, so
/// every field is a text field and the refusal §2.4 would raise is shown here,
/// where it can still be fixed, instead of arriving as an error after starting.
private struct PlanEditor: View {
    @Bindable var model: TeamViewModel
    @State private var refusal: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("แผนนี้ยังไม่ได้เริ่ม — แก้ได้ทุกช่องก่อนกดอนุมัติ",
                      systemImage: "square.and.pencil")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let refusal {
                    Label(refusal, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                ForEach($model.draft) { $item in
                    DraftCard(item: $item) { model.removeDraft(item.id) }
                }

                HStack {
                    Button("เพิ่มงาน", systemImage: "plus") { model.addDraftAssignment() }
                    Spacer()
                    Button("ทิ้งแผนนี้", role: .destructive) { model.discardDraft() }
                    Button("อนุมัติและเริ่ม") { Task { await model.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.draftIsRunnable || refusal != nil)
                        .accessibilityLabel("อนุมัติแผนนี้แล้วให้ทีมเริ่มทำงาน")
                }
            }
            .padding(16)
        }
        .task(id: model.draft) { refusal = await model.refusal() }
    }
}

private struct DraftCard: View {
    @Binding var item: TeamViewModel.Draft
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("ผู้รับผิดชอบ", selection: $item.role) {
                    ForEach(Role.assignable, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("เลือกผู้เชี่ยวชาญที่รับงานนี้")

                TextField("ให้ทำอะไร", text: $item.goal)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("รายละเอียดงาน")

                Button("ลบ", systemImage: "trash", action: remove)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("ลบงานนี้ออกจากแผน")
            }

            TextField("ผลงานที่ต้องส่ง เช่น เอกสารสรุป", text: $item.deliverableType)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("ชนิดของผลงานที่ต้องส่ง")

            VStack(alignment: .leading, spacing: 3) {
                Text("เกณฑ์ตรวจรับ — บรรทัดละข้อ เขียนว่า  เกณฑ์ | หลักฐานที่ต้องเห็น")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Required, not optional: an assignment with no criteria cannot
                // be reviewed, and §2.5 reviews evidence rather than opinions.
                TextEditor(text: $item.criteria)
                    .font(.callout)
                    .frame(minHeight: 54)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    .accessibilityLabel("เกณฑ์ตรวจรับของงานนี้ บรรทัดละหนึ่งข้อ")
                if item.assignment == nil {
                    Text("ยังเริ่มไม่ได้ — ต้องมีทั้งรายละเอียดงานและเกณฑ์ตรวจรับอย่างน้อยหนึ่งข้อ")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PlanSummary: View {
    let plan: TeamPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("แผนของหัวหน้าทีม — \(plan.assignments.count) งาน",
                  systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(plan.goal)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AssignmentRow: View {
    let row: TeamViewModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoleChip(role: row.role)
                Text(row.goal)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Spacer()
                ProgressChip(progress: row.progress, attempts: row.attempts)
            }

            if let summary = row.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !row.findings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.progress == .passed ? "หมายเหตุจากการตรวจ" : "เหตุผลที่ถูกตีกลับ")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(row.findings.enumerated()), id: \.offset) { _, finding in
                        Text("• \(finding)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RoleChip: View {
    let role: Role

    var body: some View {
        Text(role.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.secondary.opacity(0.18), in: Capsule())
            .accessibilityLabel("บทบาท \(role.label)")
    }
}

extension Role {
    /// The roles a person can hand work to. The lead plans and QA reviews;
    /// neither takes an assignment, so neither belongs in a picker of who
    /// could do this piece of work.
    static var assignable: [Role] { [.researcher, .analyst, .engineer, .writer] }

    var label: String {
        switch self {
        case .teamLead: "หัวหน้าทีม"
        case .researcher: "Researcher"
        case .analyst: "Analyst"
        case .engineer: "Engineer"
        case .writer: "Writer"
        case .reviewer: "QA"
        }
    }
}

private struct ProgressChip: View {
    let progress: TeamViewModel.Progress
    let attempts: Int

    var body: some View {
        HStack(spacing: 4) {
            if progress == .running { ProgressView().controlSize(.mini) }
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .accessibilityLabel("\(text) ผ่านไป \(attempts) รอบ")
    }

    // Attempts are on the chip rather than hidden: a task that passed on the
    // third try and one that passed immediately are not the same result.
    private var text: String {
        switch progress {
        case .running: "กำลังทำ (รอบ \(attempts))"
        case .passed: attempts > 1 ? "ผ่าน (รอบที่ \(attempts))" : "ผ่าน"
        case .failed: "ถูกตีกลับ (รอบ \(attempts))"
        case .escalated: "ต้องให้คนตัดสิน (\(attempts) รอบ)"
        }
    }

    private var icon: String {
        switch progress {
        case .running: "clock"
        case .passed: "checkmark.circle"
        case .failed: "arrow.uturn.backward"
        case .escalated: "hand.raised"
        }
    }

    private var tint: Color {
        switch progress {
        case .running: .secondary
        case .passed: .green
        case .failed: .orange
        case .escalated: .red
        }
    }
}
