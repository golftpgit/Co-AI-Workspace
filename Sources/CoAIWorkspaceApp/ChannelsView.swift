import SwiftUI
import AgentKit
import Channels

// ─────────────────────────────────────────────────────────────
// Setting up a chat channel (ARCHITECTURE §8.2, §15).
//
// P7.3/P7.4 built Telegram, Discord and LINE, and `Engine` has held a
// `ChannelAccountStore` since then that **no view ever read**. Configuring a
// bot meant writing JSON by hand next to the database, and after P9.3 moved
// secrets into the Keychain there was still nowhere to type the token. Found
// during the secrets audit; recorded there and built here, because it is a gap
// in P7 rather than in the security work.
//
// Two things the screen is arranged around:
//
//  • **The allow-list is the security model.** A bot's username is public and
//    the token is the only secret, so who may talk to it is a list — and an
//    empty list means nobody. The field says so where somebody is about to
//    leave it empty, not in a document.
//  • **Changes take effect at the next launch.** The channels are started once,
//    in `Engine.build`. Pretending otherwise — a screen that looks live while
//    the running bot still has yesterday's allow-list — would be worse than
//    saying it plainly, so it is said plainly.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class ChannelsViewModel {
    private(set) var accounts: [ChannelAccount] = []
    /// The draft is a value and the sheet has its own flag — see
    /// `MCPServersViewModel` for what the optional-plus-force-unwrap version
    /// does when you press Save (it traps, and it did, on screen).
    var draft = ChannelAccountDraft()
    var isEditing = false
    /// The account being edited, or nil when the draft is a new one.
    private(set) var editingID: String?
    private(set) var problem: String?

    private var store: ChannelAccountStore?

    func attach(store: ChannelAccountStore) {
        self.store = store
        reload()
    }

    func reload() {
        accounts = store?.load() ?? []
    }

    func startNew() {
        editingID = nil
        draft = ChannelAccountDraft()
        isEditing = true
    }

    func edit(_ account: ChannelAccount) {
        editingID = account.id
        draft = ChannelAccountDraft(account)
        isEditing = true
    }

    func save() {
        guard let store, draft.canSave else { return }
        do {
            try store.add(draft.account(id: editingID))
            isEditing = false
            editingID = nil
            problem = nil
            reload()
        } catch {
            problem = ReadableFailure.message(for: error, doing: t("saving the bot list", "Names the action that failed."))
        }
    }

    func remove(_ account: ChannelAccount) {
        guard let store else { return }
        do {
            try store.remove(account.id)
            problem = nil
            reload()
        } catch {
            problem = ReadableFailure.message(for: error, doing: t("removing the bot from the list", "Names the action that failed."))
        }
    }
}

struct ChannelsView: View {
    @Bindable var model: ChannelsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.accounts.isEmpty {
                    Text(localised: "No bot on the list yet — add one with the button above",
                         "Empty state on the channels screen.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.accounts) { account in
                    row(account)
                }
                if let problem = model.problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                footnote
            }
            .padding(Space.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $model.isEditing) { ChannelEditor(model: model) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localised: "Channels", "Sub-tab: ways the app reaches out, such as mail or chat.")
                    .font(.title2.bold())
                Text(localised: "Bots that can talk to this workspace — every channel goes through the same core and the same hook chain (§8.2)",
                     "Explains what the channels screen configures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(t("Add a bot", "Button that defines a new channel account.")) { model.startNew() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func row(_ account: ChannelAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(account.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(account.name).fontWeight(.medium)
                Text(account.platform.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(t("Edit", "Button that opens an endpoint for editing.")) { model.edit(account) }
                    .buttonStyle(.borderless).font(.caption)
                Button(t("Delete", "Context-menu item that removes a file."),
                       role: .destructive) { model.remove(account) }
                    .buttonStyle(.borderless).font(.caption)
            }
            Text(localised: "accepts \(account.allowedChats.count) chat ids\(account.scope == .central ? t(" · the whole workspace", "Appended to a channel that is not scoped to one project.") : t(" · this project only", "Appended to a channel scoped to one project."))",
                 "A channel row. Placeholder is how many chat ids it accepts.")
                .font(.caption2).foregroundStyle(.secondary)
            // `blockers` distinguishes "not set" from "the Keychain would not
            // open" since P9.3 — sending somebody to re-enter a token they
            // already entered is how an hour goes missing.
            ForEach(account.blockers, id: \.self) { blocker in
                Text("• \(blocker)").font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.box)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.box))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.name) · \(account.platform.label) · "
                            + (account.isReady
                               ? t("ready", "Channel status: it can run.")
                               : t("not ready", "Channel status: something is missing.")))
    }

    private var footnote: some View {
        Text(localised: "Changes here take effect at the next launch — channels start once at boot, and a screen that pretends otherwise while the running bot still holds yesterday's list is worse than saying so",
             "Explains why channel changes are not live.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// ─────────────────────────────────────────────────────────────

private struct ChannelEditor: View {
    @Bindable var model: ChannelsViewModel

    var body: some View {
        @Bindable var model = model
        let draft = $model.draft
        return VStack(alignment: .leading, spacing: 12) {
                Text(draft.wrappedValue.name.isEmpty
                     ? t("Add a bot", "Sheet title when defining a channel account.")
                     : t("Edit \(draft.wrappedValue.name)",
                         "Sheet title when editing a channel account. Placeholder is its name."))
                    .font(.headline)

                Picker(t("Platform", "Picker: which chat platform this bot is on."), selection: draft.platform) {
                    ForEach(ChannelPlatform.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent(t("Name", "Field label: what to call this endpoint.")) {
                    TextField(t("research group bot", "Example name for a channel account."),
                              text: draft.name)
                }

                if !draft.wrappedValue.platform.isLocal {
                    SecretField(name: draft.tokenVariable,
                                title: t("Name of the bot token",
                                         "Label on the field naming the stored bot token."),
                                placeholder: "TELEGRAM_BOT_TOKEN")
                    if draft.wrappedValue.platform == .line {
                        SecretField(name: draft.signingSecretVariable,
                                    title: t("Name of the channel secret (checks the webhook signature)",
                                             "Label on the field naming the stored channel secret."),
                                    placeholder: "LINE_CHANNEL_SECRET")
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(t("Allowed chat ids", "Field label: which chats this bot answers.")) {
                            TextField("123456789, 987654321", text: draft.allowedChatsText)
                        }
                        Text(localised: "Separate them with commas, spaces or new lines · \(draft.wrappedValue.allowedChats.count) read so far",
                             "Help under the chat id field. Placeholder is how many were parsed.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                LabeledContent(t("Model for this channel only (empty = follow the router)",
                                 "Field label: an optional per-channel model override.")) {
                    TextField("qwen3.6-27b", text: draft.modelOverride)
                }
                Toggle(t("Enabled", "Checkbox that turns a channel or server on."), isOn: draft.isEnabled)

                ForEach(draft.wrappedValue.problems, id: \.self) { problem in
                    Text("• \(problem)").font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(draft.wrappedValue.warnings, id: \.self) { warning in
                    Text(.init("• \(warning)")).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button(t("Close", "Button that dismisses the endpoint sheet without saving.")) {
                        model.isEditing = false
                    }
                    Button(t("Save", "Button that stores the edited entities.")) { model.save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.wrappedValue.canSave)
                }
            }
            .padding(Space.section)
            .frame(width: 540)
    }
}
