import SwiftUI
import AgentKit

// ─────────────────────────────────────────────────────────────
// One approval component (ARCHITECTURE §5.4). It renders inline in Chat here,
// and the Approvals page and workflow step cards reuse it in P8 — v1 grew a
// separate approval UI per surface and they drifted.
//
// It shows the actual command, not a paraphrase, and it offers the third
// option the architecture insists on: edit before approving.
// ─────────────────────────────────────────────────────────────

struct ApprovalBanner: View {
    let request: ApprovalRequest
    @Binding var edit: String
    @Binding var isEditing: Bool
    let respond: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("ขออนุมัติ: \(request.toolName)").fontWeight(.semibold)
                RiskBadge(risk: request.risk)
                Spacer()
                Text(request.requestedAt, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
            }

            // The verbatim action. A summary here is how a human approves
            // something they did not actually read.
            //
            // `fixedSize` matters: a bare ScrollView takes every point it is
            // offered, so a three-line command left the banner filling half
            // the window with blank space. The banner hugs its text and only
            // scrolls once there is genuinely too much of it.
            if isEditing {
                TextEditor(text: $edit)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 120)
                    .accessibilityLabel("แก้อาร์กิวเมนต์ก่อนอนุมัติ")
            } else {
                ScrollView {
                    Text(request.detail)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let conflict = request.policyConflict {
                Label(conflict, systemImage: "exclamationmark.octagon")
                    .font(.callout).foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button("อนุมัติ") {
                    respond(isEditing ? .approvedWithEdit(argumentsJSON: edit) : .approved)
                }
                .keyboardShortcut(.defaultAction)

                Button("ไม่อนุมัติ", role: .destructive) {
                    respond(.rejected(reason: "ผู้ใช้ปฏิเสธ"))
                }

                Toggle("แก้ก่อนอนุมัติ", isOn: $isEditing)
                    .toggleStyle(.button)
                    .accessibilityHint("เปิดเพื่อแก้อาร์กิวเมนต์ก่อนกดอนุมัติ")

                Spacer()
                Text("ตอบจากช่องทางไหนก็ได้ — ใครตอบก่อนนับคนนั้น")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("คำขออนุมัติสำหรับเครื่องมือ \(request.toolName)")
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("ความเสี่ยง \(label)")
    }

    private var label: String {
        switch risk {
        case .low: "เสี่ยงต่ำ"
        case .medium: "เสี่ยงปานกลาง"
        case .high: "เสี่ยงสูง"
        }
    }

    private var color: Color {
        switch risk {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}
