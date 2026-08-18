import SwiftUI
import AgentKit

// ─────────────────────────────────────────────────────────────
// Where a person types a secret (P9.3).
//
// Until this existed there was nowhere. Every secret-bearing feature stored the
// *name* of an environment variable and read the value from the environment —
// and a `.app` launched from Finder inherits no shell environment at all
// (measured; see `SecretStore`). So a paid endpoint, a bot and a connector
// with a password were configurable right up to the part that makes them work.
//
// The field is deliberately one-way. It writes to the Keychain and never reads
// back: there is no "show" toggle and no masked preview of the stored value,
// because the only thing a person needs to know is *whether* it is set, and the
// only thing a shoulder, a screenshot or a screen recording can take is what is
// drawn. What is drawn is a sentence, from `SecretPresentation`.
// ─────────────────────────────────────────────────────────────

struct SecretField: View {
    /// The name the secret is filed under. Editable, because it is part of the
    /// endpoint/bot/connector record and is what gets saved to disk.
    @Binding var name: String
    let title: String
    let placeholder: String

    @State private var typed = ""
    @State private var saveError: String?
    /// Bumped after a write so the status line re-reads the vault. Without it
    /// the sentence would keep saying "not set yet" right after a successful
    /// save, which reads as the save having failed.
    @State private var revision = 0

    private var display: SecretPresentation.Display {
        _ = revision
        return SecretPresentation.display(name: name.isEmpty ? nil : name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                TextField(placeholder, text: $name)
                    .accessibilityLabel(t("\(title) — the name it is stored under",
                                          "Screen-reader label for a secret's name field. Placeholder is the field title."))
            }

            HStack(spacing: 8) {
                SecureField(t("The value to store", "Secure field for a secret's value."), text: $typed)
                    .accessibilityLabel(t("\(title) — the value",
                                          "Screen-reader label for a secret's value field. Placeholder is the field title."))
                    .disabled(name.isEmpty)
                Button(t("Save to the Keychain", "Button that stores a secret.")) {
                    save(typed.isEmpty ? nil : typed)
                }
                    .disabled(name.isEmpty || typed.isEmpty)
                if display.canRemove {
                    Button(t("Delete", "Context-menu item that removes a file."),
                           role: .destructive) { save(nil) }
                }
            }

            Text(.init(display.text))
                .font(.caption)
                .foregroundStyle(colour(display.tone))
                .accessibilityLabel(display.text)

            if let saveError {
                Text(localised: "Could not save: \(saveError)",
                     "Shown when storing a secret failed. Placeholder is the reason.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func save(_ value: String?) {
        do {
            try SecretStore.set(value, for: name)
            saveError = nil
            // The app never keeps the typed string around after handing it over.
            typed = ""
            revision += 1
        } catch {
            saveError = ReadableFailure.message(for: error,
                                               doing: t("storing the secret in the Keychain",
                                                        "Names the action that failed."))
        }
    }

    private func colour(_ tone: SecretPresentation.Display.Tone) -> Color {
        switch tone {
        case .ok: .green
        case .caution: .orange
        case .missing: .secondary
        case .problem: .red
        }
    }
}
