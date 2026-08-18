import SwiftUI
import Linkage

// ─────────────────────────────────────────────────────────────
// Who was asked, and who came back (ARCHITECTURE §20.7, P11.7b).
//
// This screen is where the anonymous code stops being an idea. Somebody is
// enrolled, gets a code, and is sent a link that ends in `?code=P-…`; their
// answers arrive against that code; and in wave 3 the same code is still theirs,
// which is what lets "did the people who were burning out in March improve by
// June" be asked without a name ever sitting beside an answer.
//
// The one thing this screen can do that no other part of the app can — turn a
// code back into a person — is deliberately awkward: it needs a reason and a
// name, it shows one identity at a time, and it forgets it as soon as the sheet
// closes. Every attempt is written to the audit trail, successful or not. That is
// §20.7 invariant 3 made into a shape a person experiences rather than a rule
// they are told about.
// ─────────────────────────────────────────────────────────────

struct ParticipantsBox: View {
    @Bindable var model: InstrumentsViewModel

    @State private var identity = ""
    @State private var revealing: String?
    @State private var reason = ""
    @State private var who = ""

    var body: some View {
        GroupBox(t("Participants (anonymous codes, for multi-wave studies)",
                   "Box heading over the participant register.")) {
            VStack(alignment: .leading, spacing: 8) {
                enrolRow
                if !model.attrition.isEmpty { attritionRows }
                if model.participants.isEmpty {
                    Text(localised: "No participant registered — an anonymous one-shot study does not need this section",
                         "Empty state in the participant register.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    codes
                }
                Text(markdown: t("Participant identities are encrypted in **a different file from the answers**, with a key in this project's Keychain — so a copy of the response data carries no identity at all · looking up who a code belongs to **is recorded every time**, with the reason and the name of whoever looked (§20.7)",
                                 "Explains where identities live and that lookups are audited."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var enrolRow: some View {
        HStack {
            TextField(t("Email or name of the participant (stored encrypted)",
                        "Text field for the identity that will be encrypted."),
                      text: $identity)
                .textFieldStyle(.roundedBorder)
            Button(t("Register and issue a code", "Button that registers a participant.")) {
                let value = identity
                identity = ""
                Task { await model.enrol(identity: value) }
            }
            .disabled(identity.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(t("Invite everybody into this wave", "Button that adds every participant to the open wave.")) {
                Task { await model.inviteAllToCurrentWave() }
            }
                .disabled(model.participants.isEmpty || !model.waveIsOpen)
        }
        .controlSize(.small)
    }

    private var attritionRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.attrition, id: \.waveID) { row in
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .foregroundStyle(.secondary)
                    // The number a longitudinal study has to report, and the one
                    // that decides whether its later waves mean anything.
                    Text(localised: "This wave: \(row.invited) invited · \(row.responded) responded \(String(format: "(%.0f%%)", row.rate * 100))",
                         "Attrition row. Placeholders: how many were invited, how many answered, and the rate in brackets.")
                        .font(.caption)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var codes: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.participants) { participant in
                HStack(spacing: 8) {
                    Text(participant.code)
                        .font(.system(.caption, design: .monospaced))
                    Text(participant.enrolledAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Copy the link", "Button that copies a participant's survey link.")) {
                        let base = model.serving?.urls.first ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(base)?code=\(participant.code)",
                                                       forType: .string)
                    }
                    .disabled(model.serving == nil)
                    .accessibilityLabel(t("Copy the survey link for code \(participant.code)",
                                          "Screen-reader label. Placeholder is the participant code."))
                    Button(t("See who this is", "Button that reveals a participant's identity, which is audited.")) {
                        reason = ""
                        revealing = participant.code
                    }
                    .accessibilityLabel(t("Reveal the identity behind code \(participant.code) — this is recorded",
                                          "Screen-reader label. Placeholder is the participant code."))
                }
                .controlSize(.small)
            }
        }
        .sheet(isPresented: Binding(get: { revealing != nil },
                                    set: { if !$0 { revealing = nil; model.hideRevealed() } })) {
            revealSheet
        }
    }

    @ViewBuilder
    private var revealSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localised: "Reveal the identity behind code \(revealing ?? "")",
                 "Title of the reveal sheet. Placeholder is the participant code.")
                .font(.headline)
            Text(localised: "This lookup is recorded with your reason and your name whether or not the code is found — the question the record answers is “who looked”, not “who looked successfully”",
                 "Explains that the audit records attempts, not just successes.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(t("Reason for looking", "Text field: why the identity is being revealed."), text: $reason)
                .textFieldStyle(.roundedBorder)
            TextField(t("Your name", "Text field: who is looking."), text: $who)
                .textFieldStyle(.roundedBorder)

            if let revealed = model.revealed, revealed.code == revealing {
                GroupBox {
                    Text(revealed.identity)
                        .font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button(t("Close", "Button that dismisses the endpoint sheet without saving.")) {
                    revealing = nil; model.hideRevealed()
                }
                Button(t("Reveal it", "Button that performs the audited identity lookup.")) {
                    guard let code = revealing else { return }
                    Task { await model.reveal(code: code, reason: reason, by: who) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty
                          || who.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.section)
        .frame(width: 420)
    }
}
