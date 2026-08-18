import SwiftUI

// ─────────────────────────────────────────────────────────────
// Where every screen from §14.2 went (ARCHITECTURE §19.2, P10.12).
//
// Risk R13 names this task's failure mode exactly: "collapse 14 screens into 4
// areas and lose things". It is the same mistake as v1's `Scope.project` — a
// reorganisation that reads as complete because the new structure is tidy, while
// two of the old screens quietly have no home.
//
// So the mapping is data rather than a claim in a commit message: one row per
// §14.2 entry, saying which area and sub-tab it lives in and what state it is
// actually in. `check.sh` parses §14.2's table out of ARCHITECTURE.md and fails
// if a row here is missing — a screen cannot be dropped by being forgotten,
// only by being deleted from the standard it is measured against.
//
// The three states are deliberately distinguished. "not built" with a task
// number is an honest answer; a row silently absent is not.
// ─────────────────────────────────────────────────────────────

struct IAEntry: Identifiable {
    enum State {
        /// Everything §14.2 lists for this screen is reachable.
        case done
        /// Reachable, but some of what §14.2 lists is not there yet.
        case partial(String)
        /// Not built. The task that will build it is named.
        case notBuilt(String)

        var label: String {
            switch self {
            case .done: t("complete", "Screen-map state: everything the spec lists is reachable.")
            case .partial: t("partial", "Screen-map state: reachable, but not everything is there.")
            case .notBuilt: t("not built", "Screen-map state: nothing of it exists yet.")
            }
        }

        var note: String? {
            switch self {
            case .done: nil
            case .partial(let text), .notBuilt(let text): text
            }
        }
    }

    /// The name as §14.2 spells it. Matched against the document by check.sh, so
    /// this string is not free text.
    let screen: String
    let area: String
    let subTab: String
    let state: State

    var id: String { screen }
}

enum IAInventory {
    // The area and sub-tab names, written once and reused, so the map says the
    // same words the picker does. Reusing the picker's own keys rather than new
    // ones keeps them one string in the catalogue, not two that drift.
    private static var chat: String { t("Chat", "Area 1 of 5: asking the team to do something.") }
    private static var plan: String { t("Plan", "Area 2 of 5: what was agreed, and who is accountable.") }
    private static var workbench: String { t("Workbench", "Area 3 of 5: where the data is and what to do with it.") }
    private static var knowledge: String { t("Knowledge", "Area 4 of 5: what is true, and how we know.") }
    private static var system: String { t("System", "Area 5 of 5: settings — models, budget, channels.") }
    private static var console: String { t("Script + console", "Sub-tab: the notebook and its output.") }
    private static var collect: String { t("Collect", "Sub-tab: gathering data into the project.") }
    private static var coding: String { t("Code", "Sub-tab: qualitative coding of collected material.") }
    private static var sources: String { t("Sources and tiers", "Sub-tab: where knowledge came from and how far it is trusted. 'tier' is a term of art here.") }
    private static var rail: String { t("Right rail: watch the team", "Screen-map location for the team rail.") }

    /// One row per §14.2 screen, in that table's order.
    static let entries: [IAEntry] = [
        IAEntry(screen: "Chat", area: chat, subTab: t("Conversations", "Heading and window title over the list of past conversations."),
                state: .done),
        IAEntry(screen: "Team View", area: chat, subTab: rail,
                state: .partial(t("The team *settings* moved to Plan → Team & RACI per §19.2.5 — what is left here is watching and asking for reports",
                                  "Screen-map note for the Team View row."))),
        IAEntry(screen: "Live Monitor", area: chat, subTab: rail,
                state: .partial(t("There is no card per step yet — assignments and QA status are visible, but the raw output of a single step cannot be expanded",
                                  "Screen-map note for the Live Monitor row."))),
        IAEntry(screen: "Approvals", area: chat,
                subTab: t("Approval bar inside the conversation", "Screen-map location for approvals."),
                state: .partial(t("Approving inline in the conversation works · there is no combined list across conversations yet",
                                  "Screen-map note for the Approvals row."))),
        IAEntry(screen: "Notebook", area: workbench, subTab: console,
                state: .done),
        IAEntry(screen: "DB Explorer", area: workbench,
                subTab: t("Internal database", "Sub-tab: the project's own store.")
                    + " · " + t("External database", "Sub-tab: databases outside the project."),
                state: .done),
        IAEntry(screen: "Knowledge Base", area: knowledge,
                subTab: t("Documents", "Sub-tab: source documents in the knowledge base."),
                state: .partial(t("The entity/relation graph exists (the “Graph” tab) — the neighbourhood around what is selected rather than the whole graph, and every edge opens the passage it came from · there is still no way to edit a relation from the graph itself",
                                  "Screen-map note for the Knowledge Base row."))),
        IAEntry(screen: "Conflict Ledger", area: knowledge,
                subTab: t("Conflicts", "Sub-tab: claims that contradict each other."),
                state: .done),
        IAEntry(screen: "Models", area: system,
                subTab: t("Models", "Sub-tab: which models are available."),
                state: .done),
        IAEntry(screen: "Workflow Builder", area: workbench, subTab: console,
                state: .partial(t("A sequence of steps can be saved and re-run · every step goes through `ToolGateway` · the palette is read from the tools really connected · **there is deliberately no n8n-style node canvas** — steps are a sequence, and splitting work is the team lead's decision (§2.2) rather than a line somebody drags",
                                  "Screen-map note for the Workflow Builder row."))),
        IAEntry(screen: "Templates", area: workbench,
                subTab: t("Results + documents", "Sub-tab: findings and what is written from them."),
                state: .partial(t("A template can be learned from an uploaded .docx · there is no screen of its own for managing templates yet",
                                  "Screen-map note for the Templates row."))),
        IAEntry(screen: "File Viewer/Editor", area: workbench, subTab: console,
                state: .partial(t("Text and code files can be opened, edited and saved · `.docx`/`.pptx`/`.pdf` show as read-only text · there is no image viewer, and files cannot be created, deleted or renamed from here",
                                  "Screen-map note for the File Viewer/Editor row."))),
        IAEntry(screen: "Processes", area: chat,
                subTab: t("Right rail: processes", "Screen-map location for the process list."),
                state: .partial(t("Running processes are visible and can be stopped · there is no table across every conversation yet",
                                  "Screen-map note for the Processes row."))),
        IAEntry(screen: "Settings", area: system,
                subTab: t("Budget + endpoints", "Sub-tab: spending limits and the servers that answer.")
                    + " · " + t("Models", "Sub-tab: which models are available.")
                    + " · " + t("Channels", "Sub-tab: ways the app reaches out, such as mail or chat.")
                    + " · " + t("Plug-ins", "Screen-map location for bundled plug-ins."),
                state: .partial(t("There are sections for inference, budget, models, plug-ins and channels · **there is still no screen for adding an MCP server** — `MCPServerStore` lives on the engine and no screen reads it (bundled plug-ins can be added) · the remaining sections of §15 have no screen",
                                  "Screen-map note for the Settings row."))),
        // Not in §14.2 because it did not exist then. Listed so the inventory is
        // the whole app rather than only the parts that were reorganised.
        IAEntry(screen: "Plan", area: plan,
                subTab: t("Overview", "Plan sub-tab: the project brief, scope and standards.")
                    + " · " + t("Plan + sequence", "Plan sub-tab: the work breakdown and what depends on what.")
                    + " · " + t("Board", "Plan sub-tab: work packages as a kanban board.")
                    + " · " + t("Team & RACI", "Plan sub-tab: who is accountable for each package.")
                    + " · " + t("Benefits & closing", "Plan sub-tab: measured benefits and the conditions for closing."),
                state: .done),
        // Kept current deliberately: the three things this row said were missing
        // were built in P11.5, P11.6b and P11.7b, and an inventory that lags the
        // app is the R13 failure it exists to prevent, one level up.
        IAEntry(screen: "Collect", area: workbench, subTab: collect,
                state: .partial(t("Instrument design · the gate before collection · serving the form on the LAN · resuming a part-filled form · anonymous codes and attrition · a closed wave really closing · a response table with an edit record · materialising into DuckDB · α/ω/EFA from real answers — missing: matrix, ranking and file-upload question kinds in the served form",
                                  "Screen-map note for the Collect row."))),
        IAEntry(screen: "Code", area: workbench, subTab: coding,
                state: .partial(t("A codebook with definitions and parent codes · passages fixed once so every coder rates the same set · inter-coder κ (Cohen/Fleiss) overall and per code · a saturation curve — missing: transcripts entering the knowledge base with provenance, and citing back to the real passage (second half of P11.8)",
                                  "Screen-map note for the Code row."))),
        IAEntry(screen: "Sources and tiers", area: knowledge, subTab: sources,
                state: .partial(t("The register of sources and their tiers can be read · turning one on or off is not stored yet (P13)",
                                  "Screen-map note for the Sources and tiers row."))),
    ]
}

/// The inventory, on screen. R13 asks for a checklist per item, and a checklist
/// only a developer can read is a checklist the person who cares cannot use.
struct IAInventoryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(localised: "Where each of the old screens went", "Title of the screen map.")
                    .font(.headline)
                Text(localised: "§14.2 of the architecture lists 14 screens · they were reorganised into four areas plus System by §19.2 · a row that is not built says so plainly, with its task number — `check.sh` goes red if a screen in §14.2 has no row here",
                     "Explains what the screen map is and what keeps it honest.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(IAInventory.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(entry.screen).font(.callout).bold()
                            Text("→ \(entry.area) · \(entry.subTab)")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.state.label)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(tint(entry.state).opacity(0.18), in: Capsule())
                                .foregroundStyle(tint(entry.state))
                        }
                        if let note = entry.state.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(t("\(entry.screen) is in \(entry.area) \(entry.subTab) — \(entry.state.label) \(entry.state.note ?? "")",
                                          "Screen-reader label for a screen-map row. Placeholders: the screen, its area, its sub-tab, its state and any note."))
                }
            }
            .padding(Space.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tint(_ state: IAEntry.State) -> Color {
        switch state {
        case .done: .green
        case .partial: .orange
        case .notBuilt: .secondary
        }
    }
}
