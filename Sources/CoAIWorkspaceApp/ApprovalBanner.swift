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
                Text(localised: "Approval requested: \(request.toolName)",
                     "Heading of the approval banner. Placeholder is the tool name.")
                    .fontWeight(.semibold)
                RiskBadge(risk: request.risk)
                Spacer()
                Text(request.requestedAt, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
            }

            // The verbatim action. A summary here is how a human approves
            // something they did not actually read.
            //
            // Bounded, never fixed: a bare ScrollView takes every point it is
            // offered (the banner once filled half the window), and pinning it
            // to its ideal height pushed the buttons off the bottom of the
            // window entirely. A cap does both jobs without either failure.
            if isEditing {
                TextEditor(text: $edit)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 120)
                    .accessibilityLabel(t("Edit the arguments before approving", "Screen-reader label."))
            } else {
                ScrollView {
                    Text(request.detail)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }

            if let conflict = request.policyConflict {
                Label(conflict, systemImage: "exclamationmark.octagon")
                    .font(.callout).foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button(t("Approve", "Button that approves a register entry.")) {
                    respond(isEditing ? .approvedWithEdit(argumentsJSON: edit) : .approved)
                }
                .keyboardShortcut(.defaultAction)

                Button(t("Do not approve", "Button that refuses a tool call."),
                       role: .destructive) {
                    respond(.rejected(reason: t("the user refused",
                                                "Recorded reason when a person declines a tool call.")))
                }

                Toggle(t("Edit before approving", "Checkbox that opens the arguments for editing."),
                       isOn: $isEditing)
                    .toggleStyle(.button)
                    .accessibilityHint(t("turn on to change the arguments before approving",
                                         "Screen-reader hint on the edit switch."))

                Spacer()
                Text(localised: "It can be answered from any channel — whoever answers first is the one that counts",
                     "Says that approval is not tied to this screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Space.section)
        .background(.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("Approval request for the tool \(request.toolName)",
                              "Screen-reader label. Placeholder is the tool name."))
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
            .accessibilityLabel(t("Risk \(label)", "Screen-reader label. Placeholder is the risk level."))
    }

    private var label: String {
        switch risk {
        case .low: t("low risk", "Risk level of a work package.")
        case .medium: t("medium risk", "Risk level of a work package.")
        case .high: t("high risk", "Risk level of a work package.")
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
