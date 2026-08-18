import SwiftUI
import Observation
import AgentKit
import Roster
import CoreEngine
import MCPBridge
import Observability

// ─────────────────────────────────────────────────────────────
// Install a plugin, and have it work (ARCHITECTURE §7.1, §7.3, P8.4).
//
// The button is three steps, and the third is the one the task is about:
// install the package, connect its server, **register its tools in the
// gateway that is already running**. A plugin whose tools appear at the next
// launch is a plugin whose install button was not telling the truth, and
// nobody reads an install button as "later".
//
// Uninstall is the same three in reverse, and the order matters: the tools
// come off the list before the folder goes, so no turn in between can be
// offered a tool whose server is being deleted.
//
// This lives beside the MCP section on the status screen rather than in a
// screen of its own — P8.6 owns the full Plugins settings page. What is here
// is the whole capability, not a preview of it.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class PluginsViewModel {
    private(set) var installed: [InstalledPlugin] = []
    /// Tool names per plugin, so the list can say what each one actually
    /// brought. "Installed" and "gave the session something" are different
    /// facts and the screen should not merge them.
    private(set) var toolNames: [String: [String]] = [:]
    private(set) var status: String?
    private(set) var isError = false

    private var registry: PluginRegistry?
    private var mcp: MCPRegistry?
    private var gateway: ToolGateway?
    private let log = AppLog.logger("roster")

    func attach(registry: PluginRegistry, mcp: MCPRegistry, gateway: ToolGateway) async {
        self.registry = registry
        self.mcp = mcp
        self.gateway = gateway
        await refresh()
    }

    func refresh() async {
        guard let registry, let mcp else { return }
        installed = registry.installed()
        var names: [String: [String]] = [:]
        for connected in await mcp.connected {
            names[connected.name] = connected.toolNames
        }
        toolNames = names
    }

    func install(from folder: URL) async {
        guard let registry, let mcp, let gateway else { return }
        // A folder chosen from a panel is outside the sandbox until it is
        // opened this way.
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            let plugin = try registry.install(from: folder)
            do {
                let tools = try await mcp.connect(Engine.server(for: plugin))
                await gateway.register(tools)
                status = t("Installed ‘\(plugin.name)’ — \(tools.count) tools available straight away",
                           "Status message after installing a plug-in. Placeholders: its name and how many tools it brought.")
                isError = false
            } catch {
                // Installed but not running is a real state, and it is not the
                // same as "failed to install": the package is on disk and will
                // be tried again at the next launch. Saying which one happened
                // is the difference between "try again" and "fix the server".
                status = t("Installed ‘\(plugin.name)’ but its server would not start: ",
                           "Status message when a plug-in installs but does not run. Placeholder is its name.")
                    + ((error as? MCPServerError)?.description ?? "\(error)")
                isError = true
            }
        } catch {
            status = (error as? PluginError)?.description ?? "\(error)"
            isError = true
        }
        await refresh()
    }

    func uninstall(_ plugin: InstalledPlugin) async {
        guard let registry, let mcp, let gateway else { return }
        // Tools off the list first: between these two lines a turn must not be
        // offered a tool whose package is being deleted.
        for name in await mcp.disconnect(configID: Engine.server(for: plugin).id) {
            await gateway.unregister(name)
        }
        do {
            try registry.uninstall(plugin.name)
            status = t("Removed ‘\(plugin.name)’",
                       "Status message after removing a plug-in. Placeholder is its name.")
            isError = false
        } catch {
            status = (error as? PluginError)?.description ?? "\(error)"
            isError = true
        }
        await refresh()
    }
}

struct PluginsSection: View {
    @Bindable var model: PluginsViewModel
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localised: "Plug-ins (§7.1)", "Heading of the plug-ins section.").font(.headline)
                Spacer()
                Button { choosing = true } label: {
                    Label(t("Install from a folder…", "Button that installs a plug-in from disk."),
                          systemImage: "shippingbox")
                }
                .controlSize(.small)
            }

            if model.installed.isEmpty {
                Text(localised: "No plug-in yet — a plug-in is a folder holding a plugin.json and its own MCP server",
                     "Empty state in the plug-ins section.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(model.installed) { plugin in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name).fontWeight(.medium)
                        Text(plugin.manifest.description)
                            .font(.caption).foregroundStyle(.secondary)
                        // What it actually contributed, which is not the same
                        // as whether it is installed.
                        let tools = model.toolNames[plugin.name] ?? []
                        Text(tools.isEmpty
                             ? t("not connected — none of this plug-in's tools are on the list",
                                 "Shown for a plug-in whose server is not running.")
                             : tools.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(tools.isEmpty ? .orange : .secondary)
                    }
                    Spacer()
                    Button(t("Remove", "Button that uninstalls a plug-in."), role: .destructive) {
                        Task { await model.uninstall(plugin) }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }

            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(model.isError ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .fileImporter(isPresented: $choosing,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result {
                Task { await model.install(from: folder) }
            }
        }
    }
}
