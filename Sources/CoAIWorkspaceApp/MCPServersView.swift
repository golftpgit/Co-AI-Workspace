import SwiftUI
import AgentKit
import MCPBridge

// ─────────────────────────────────────────────────────────────
// Adding an MCP server by naming what it runs (ARCHITECTURE §6.2, §15).
//
// `MCPServerStore` has been on the engine since P8.3 and no screen read it —
// found by the `check.sh` rule written for the channels, on the day it was
// written. A packaged plugin could be installed (P8.4); a server pointed at by
// command still meant editing JSON beside the database.
//
// The screen shows two things a person cannot see in the JSON: **the prefix
// every tool from this server will actually carry**, which is derived from the
// name and drops everything non-ASCII, and **why a server will not launch** —
// which since P9.3 distinguishes a token nobody entered from a Keychain that
// would not open.
//
// Like the channels: what is saved here takes effect at the next launch,
// because servers are connected once during boot. Said out loud rather than
// implied.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class MCPServersViewModel {
    private(set) var servers: [MCPServerConfig] = []
    /// The draft is always a value and the sheet is opened by a separate flag.
    ///
    /// The obvious shape — an optional draft, `.sheet(isPresented:)` derived
    /// from it, and `Binding($model.editing)` inside — **crashes**, and it
    /// crashed on this screen and on the channels screen in front of me:
    /// saving sets the optional to nil, SwiftUI re-evaluates the sheet's body
    /// once more before it finishes dismissing, and the force-unwrapping
    /// binding traps in `BindingOperations.ForceUnwrapping.get`. Found by
    /// pressing the button, not by any test (U33-1).
    var draft = MCPServerDraft()
    var isEditing = false
    private(set) var editingID: String?
    private(set) var problem: String?

    private var store: MCPServerStore?

    func attach(store: MCPServerStore) {
        self.store = store
        reload()
    }

    func reload() {
        servers = store?.load() ?? []
    }

    func startNew() {
        editingID = nil
        draft = MCPServerDraft()
        isEditing = true
    }

    func edit(_ server: MCPServerConfig) {
        editingID = server.id
        draft = MCPServerDraft(server)
        isEditing = true
    }

    func save() {
        guard let store, draft.canSave else { return }
        var all = servers
        let config = draft.config(id: editingID)
        if let index = all.firstIndex(where: { $0.id == config.id }) {
            all[index] = config
        } else {
            all.append(config)
        }
        write(all) { self.isEditing = false; self.editingID = nil }
    }

    func remove(_ server: MCPServerConfig) {
        write(servers.filter { $0.id != server.id })
    }

    private func write(_ all: [MCPServerConfig], then finish: () -> Void = {}) {
        guard let store else { return }
        do {
            try store.save(all)
            problem = nil
            finish()
            reload()
        } catch {
            problem = ReadableFailure.message(for: error, doing: t("saving the MCP server list", "Names the action that failed."))
        }
    }
}

struct MCPServersView: View {
    @Bindable var model: MCPServersViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP server").font(.headline)
                    Text(localised: "Other people's tools, running on this machine — every tool they bring goes through the same hook chain as the built-in ones (§6.2)",
                         "Explains what an MCP server is on this screen.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(t("Add a server", "Button that defines a new MCP server.")) { model.startNew() }
            }

            if model.servers.isEmpty {
                Text(localised: "No server of your own yet — the installed plug-ins below are a separate list",
                     "Empty state on the MCP servers screen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.servers) { server in
                row(server)
            }
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(localised: "Adding or editing here takes effect at the next launch — servers are connected once at boot",
                 "Explains why MCP server changes are not live.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $model.isEditing) { MCPServerEditor(model: model) }
    }

    private func row(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(server.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(server.name).fontWeight(.medium)
                // The thing the JSON never shows: what the tools are called.
                Text("mcp__\(server.namespace)__…")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button(t("Edit", "Button that opens an endpoint for editing.")) { model.edit(server) }
                    .buttonStyle(.borderless).font(.caption)
                Button(t("Delete", "Context-menu item that removes a file."),
                       role: .destructive) { model.remove(server) }
                    .buttonStyle(.borderless).font(.caption)
            }
            Text(([server.command] + server.arguments).joined(separator: " "))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(server.blockers, id: \.self) { blocker in
                Text("• \(blocker)").font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.box)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.box))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("\(server.name) · its tools are prefixed mcp \(server.namespace) · \(server.isReady ? t("ready to connect", "MCP server status: it can be reached.") : t("not ready", "Channel status: something is missing."))",
                              "Screen-reader label for an MCP server row. Placeholders: its name and its namespace."))
    }
}

// ─────────────────────────────────────────────────────────────

private struct MCPServerEditor: View {
    @Bindable var model: MCPServersViewModel

    var body: some View {
        @Bindable var model = model
        let draft = $model.draft
        return VStack(alignment: .leading, spacing: 12) {
                Text(draft.wrappedValue.name.isEmpty
                     ? t("Add an MCP server", "Sheet title when defining a server.")
                     : t("Edit \(draft.wrappedValue.name)",
                         "Sheet title when editing a channel account. Placeholder is its name."))
                    .font(.headline)

                LabeledContent(t("Name", "Field label: what to call this endpoint.")) {
                    TextField("weather", text: draft.name)
                }
                Text(localised: "Tools from this server are named `mcp__\(draft.wrappedValue.namespace)__…`",
                     "Says how this server's tools will be named. Placeholder is the namespace.")
                    .font(.caption2).foregroundStyle(.secondary)

                LabeledContent(t("Command", "Field label: the executable that starts the server.")) {
                    TextField("npx", text: draft.command)
                }
                LabeledContent(t("Arguments", "Field label: what to pass the command.")) {
                    TextField("-y weather-mcp", text: draft.argumentsText)
                }
                Text(localised: "Separated by spaces · quote a value that contains a space · \(draft.wrappedValue.arguments.count) read so far",
                     "Help under the arguments field. Placeholder is how many were parsed.")
                    .font(.caption2).foregroundStyle(.secondary)

                LabeledContent(t("Working folder (may be empty)",
                                 "Field label: where the server process runs.")) {
                    TextField("/Users/…/project", text: draft.workingDirectory)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(localised: "Variables the server needs", "Heading over the environment editor.")
                        .font(.callout)
                    TextEditor(text: draft.environmentText)
                        .font(.caption.monospaced())
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(Color.secondary.opacity(0.3)))
                        .accessibilityLabel(t("Variables the server needs", "Screen-reader label."))
                    Text(localised: "One pair per line, `WEATHER_API_KEY = the stored name` — the file holds only the name, the value lives in the Keychain (set it on the endpoints screen) · \(draft.wrappedValue.environmentVariables.count) pairs read",
                         "Help under the environment editor. Placeholder is how many pairs were parsed.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            .frame(width: 560)
    }
}
