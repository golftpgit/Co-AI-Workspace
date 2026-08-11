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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.rows.isEmpty {
                ContentUnavailableView(
                    "ยังไม่มีงานของทีม",
                    systemImage: "person.3",
                    description: Text("พิมพ์เป้าหมายด้านบนแล้วกด “เริ่มงาน” "
                                      + "หัวหน้าทีมจะวางแผนและมอบหมายให้เอง"))
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
                    .onSubmit { Task { await model.start() } }
                    .disabled(model.isRunning)
                    .accessibilityLabel("เป้าหมายที่จะให้ทีมทำ")

                if model.isRunning {
                    ProgressView().controlSize(.small)
                    // Stopping is not the same as finishing, and the screen
                    // says so afterwards rather than clearing the rows.
                    Button("หยุด") { model.cancel() }
                        .accessibilityLabel("หยุดการทำงานของทีม")
                } else {
                    Button("เริ่มงาน") { Task { await model.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.goal.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("ให้ทีมเริ่มทำงานตามเป้าหมายนี้")
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
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.secondary.opacity(0.18), in: Capsule())
            .accessibilityLabel("บทบาท \(label)")
    }

    private var label: String {
        switch role {
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
