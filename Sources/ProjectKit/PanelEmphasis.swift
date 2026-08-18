import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Which panels a project type puts first (ARCHITECTURE §24.3, P20.6).
//
// The plan's Done-when has two halves and the second one is the harder
// promise: **switching project type emphasises different panels, and nothing
// adapts to behaviour the system guessed at.** Those are not two features,
// they are a feature and a refusal.
//
// The refusal is the point. Usage-based adaptation — moving the panels
// somebody opens most to the front — is easy here: the spans already record
// every screen. It is also how an interface stops being learnable. A person
// navigates by position long before they navigate by reading, and a layout
// that rearranges itself in response to what they did last week takes that
// away without telling them. The frequent thing gets easier to reach and
// everything else gets harder to find, including the thing they need precisely
// because they have not needed it before.
//
// So emphasis comes from **one input**: the project type, which a person chose
// deliberately when they made the project. It is declared, it is visible, and
// it is changed the same way it was set.
//
// And even then, emphasis does not reorder anything. The panels stay where
// they are; the type decides which ones are marked and which one opens first.
// A screen that moves its own furniture is a screen nobody can learn the shape
// of — that is the same argument as above, and it does not stop applying just
// because the reason for moving things is a good one.
// ─────────────────────────────────────────────────────────────

/// A panel a workspace can show. The raw values are the app's own tab
/// identifiers, and `check.sh` holds them to that: a panel named here that no
/// longer exists on screen is emphasis pointing at nothing.
public enum WorkspacePanel: String, Sendable, Equatable, CaseIterable {
    case chat, plan
    case collect, coding, internalDB, externalDB, console, results
    case documents, graph, conflicts, sources
}

/// What a project type puts in front, and why.
///
/// A pure function of `ProjectKind` — the type has no way to reach usage
/// history, and that is deliberate rather than incidental.
public enum PanelEmphasis {

    /// The panels this kind of project spends its time in, in the order the
    /// work runs. **Order here is reading order for the reason, not screen
    /// order** — the screen keeps its own fixed arrangement.
    public static func panels(for kind: ProjectKind) -> [WorkspacePanel] {
        switch kind {
        case .research:
            // Fieldwork, then what was read, then where the numbers land.
            [.collect, .documents, .sources, .results]
        case .software:
            [.coding, .console, .results]
        case .analysis:
            // The data comes from somewhere before it is analysed; both
            // database panels are part of the same step.
            [.internalDB, .externalDB, .console, .results]
        case .blank:
            // A project the person did not classify gets no opinion. Guessing
            // from the name would be exactly the behaviour-derived adaptation
            // this refuses, wearing a different hat.
            []
        }
    }

    /// Which panel a freshly focused workspace of this kind opens on, or `nil`
    /// to leave the person where they were.
    ///
    /// Only ever the first emphasised panel: an opening panel that is not one
    /// of the marked ones would be the screen making a third, unexplained
    /// decision.
    public static func opening(for kind: ProjectKind) -> WorkspacePanel? {
        panels(for: kind).first
    }

    /// Said in words on screen, because emphasis a person cannot account for is
    /// indistinguishable from a screen behaving oddly.
    public static func reason(for kind: ProjectKind) -> String? {
        guard !panels(for: kind).isEmpty else { return nil }
        return t("Emphasised for the project type you chose (\(kind.label)) — not adjusted by how you use it",
                 "Explains why panels are emphasised. Placeholder is the project type.")
    }

    public static func isEmphasised(_ panel: WorkspacePanel, in kind: ProjectKind) -> Bool {
        panels(for: kind).contains(panel)
    }
}
