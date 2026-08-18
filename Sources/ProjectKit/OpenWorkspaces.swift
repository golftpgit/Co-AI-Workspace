import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Which workspaces are open, and which one you are looking at
// (ARCHITECTURE §19.1.1, P21.1).
//
// **The misunderstanding this corrects**: the app has treated General and
// Project as two *modes that swap*, so `selection` was a single value and every
// screen was rebuilt with `.id(scope.storageKey)` on each change. Rebuilding is
// the right answer to "do not show the last project's rows"; it is the wrong
// answer to "do not stop the work that is running", and it makes the second
// project you open cost you the first one's place in the app.
//
// What it should be: **General is the page that is always there, and a project
// is a tab.** Somebody researching two things at once is the ordinary case.
//
// Four rules, and each one is a way tabs go wrong:
//
//  • **General cannot be closed and is not a project.** It is where work that
//    is not a promise happens (§19.1), so it has no lifecycle and no gate.
//  • **Opening something already open moves you to it.** A second tab for the
//    same project would be two views of one scope that disagree about which of
//    them saved last.
//  • **Closing the tab you are looking at has to leave you somewhere sensible**
//    — the neighbour, not General, because General is usually not what you were
//    doing.
//  • **A closed (archived) project can be opened to read and never to write.**
//    Closing is a decision that was recorded; a project that can still be edited
//    afterwards makes the closing report describe something that changed later.
//
// Deliberately *not* here: any per-project state. This type answers "which
// workspaces exist on screen and which is in front", and nothing else — the
// state each one holds belongs to whatever owns that workspace, and putting it
// here would make this the second place that knows what a project is.
// ─────────────────────────────────────────────────────────────

public struct OpenWorkspaces: Sendable, Equatable {

    /// One thing that can be in front.
    public enum Tab: Sendable, Equatable, Hashable, Identifiable {
        case general
        case project(ProjectID)

        public var id: String {
            switch self {
            case .general: "general"
            case .project(let id): id.rawValue
            }
        }

        public var scope: Scope {
            switch self {
            case .general: .central
            case .project(let id): .project(id)
            }
        }

        public var projectID: ProjectID? {
            switch self {
            case .general: nil
            case .project(let id): id
            }
        }
    }

    /// How a tab may be used. Carried per tab rather than looked up on demand,
    /// because the thing that decides it — whether the project was closed —
    /// is a fact from the moment the tab was opened, and a tab that silently
    /// becomes writable again when a stale row is re-read is worse than one
    /// that asks you to reopen it.
    public enum Access: Sendable, Equatable {
        case readWrite
        /// An archived project: everything readable, nothing writable (§19.1.1).
        case readOnly
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public let tab: Tab
        public let title: String
        public let access: Access
        public var id: String { tab.id }

        public var isArchived: Bool { access == .readOnly }
    }

    public private(set) var entries: [Entry]
    public private(set) var active: Tab

    /// The tab that is always there. Not a project, has no lifecycle, and every
    /// list starts with it.
    public static var generalTitle: String {
        t("General", "Name of the workspace that is not a project.")
    }

    public init() {
        entries = [Entry(tab: .general, title: Self.generalTitle, access: .readWrite)]
        active = .general
    }

    // ─────────────────────────────────────────────────────────

    public var activeEntry: Entry {
        entries.first { $0.tab == active }
            // Unreachable by construction — `active` is only ever set to a tab
            // that is in `entries` — and answered rather than trapped, because
            // a crash here would take the whole window with it.
            ?? Entry(tab: .general, title: Self.generalTitle, access: .readWrite)
    }

    public var activeScope: Scope { active.scope }

    /// Whether the thing in front may be written to. The one question every
    /// screen asks before offering an action.
    public var activeIsWritable: Bool { activeEntry.access == .readWrite }

    public var openProjectIDs: [ProjectID] { entries.compactMap(\.tab.projectID) }

    public func isOpen(_ id: ProjectID) -> Bool { entries.contains { $0.tab.projectID == id } }

    // ─────────────────────────────────────────────────────────

    /// Opens a project in a tab, or moves to it if it is already open.
    ///
    /// A closed project opens read-only — reading an archive is a normal thing
    /// to want, and refusing to open it would make "archived" mean "gone".
    @discardableResult
    public mutating func open(_ project: Project) -> Tab {
        let tab = Tab.project(project.id)
        let access: Access = project.isOpen ? .readWrite : .readOnly
        if let index = entries.firstIndex(where: { $0.tab == tab }) {
            // Already open: move to it, and take the chance to correct the
            // title and the access. A project closed in another tab while this
            // one sat in the background must not stay writable here.
            entries[index] = Entry(tab: tab, title: project.name, access: access)
        } else {
            entries.append(Entry(tab: tab, title: project.name, access: access))
        }
        active = tab
        return tab
    }

    /// Brings an already-open tab to the front. Does nothing for a tab that is
    /// not open — asking for something that is not there is not a reason to
    /// change what somebody is looking at.
    public mutating func focus(_ tab: Tab) {
        guard entries.contains(where: { $0.tab == tab }) else { return }
        active = tab
    }

    /// Closes a tab. **This is closing a window, not closing a project** — the
    /// project's own life cycle (§19.12's closing gate) is a different act with
    /// a different gate, and conflating the two would let somebody end a project
    /// by tidying their screen.
    public mutating func close(_ tab: Tab) {
        guard tab != .general else { return }
        guard let index = entries.firstIndex(where: { $0.tab == tab }) else { return }
        entries.remove(at: index)
        guard active == tab else { return }
        // The neighbour, not General: General is rarely what you were doing,
        // and being thrown back to it is how you lose your place.
        active = entries[min(index, entries.count - 1)].tab
    }

    /// Re-reads titles and access from the current project list, and closes
    /// tabs whose project no longer exists.
    ///
    /// Called after the project list reloads. A tab pointing at a deleted
    /// project is the same failure as a work package that outlived its plan —
    /// it looks like a place you can go and it is not.
    public mutating func reconcile(with projects: [Project]) {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [Entry] = []
        for entry in entries {
            guard let id = entry.tab.projectID else { kept.append(entry); continue }
            guard let project = byID[id] else { continue }
            kept.append(Entry(tab: entry.tab, title: project.name,
                              access: project.isOpen ? .readWrite : .readOnly))
        }
        entries = kept
        if !entries.contains(where: { $0.tab == active }) { active = .general }
    }
}
