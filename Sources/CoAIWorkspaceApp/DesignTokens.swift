import SwiftUI

// ─────────────────────────────────────────────────────────────
// The design system, as values (ARCHITECTURE §24, P20.2).
//
// §24.1 names consistency as the worst of the four pillars here, and the reason
// is in the history: screens were built one at a time in the order the tasks
// came, so the same problem is solved by a `GroupBox` in one place, a `List` in
// another, and a row of buttons in a third — with spacings of 4, 6, 8, 10 and
// 12 all present and none of them chosen.
//
// **This file only works if `check.sh` enforces it**, which is what P20.2's
// Done-when asks for: a new view that writes its own `.padding(11)` or its own
// `Color(red:…)` fails the build. Without that rule this is one more document
// describing an intention — and §24.1 says so in as many words.
//
// Deliberately *not* here: a colour palette of our own. The system colours
// already answer light mode, dark mode, increased contrast and the accent the
// user picked, and a hand-rolled palette answers none of them while looking
// tidy in one screenshot.
// ─────────────────────────────────────────────────────────────

enum Space {
    /// Inside a control — between an icon and its label.
    static let tight: CGFloat = 4
    /// Between related rows.
    static let row: CGFloat = 8
    /// Inside a box, and between a heading and what it heads.
    static let box: CGFloat = 12
    /// Between sections of a screen.
    static let section: CGFloat = 20
}

enum Radius {
    static let control: CGFloat = 5
    static let box: CGFloat = 8
    static let sheet: CGFloat = 12
}

/// Which layer something is on (§24.2's honest materiality).
///
/// **Glass is only for what floats above content and partly hides it** — a
/// toolbar, a status strip, a popover. Anything a person reads a number off
/// sits on a solid layer, always: this app puts p-values, confidence intervals
/// and quoted text on screen, and a number misread because a translucent
/// background ran under it is damage that cannot be undone by a later edit.
enum Surface {
    /// Floating chrome. Uses the glass API measured on this SDK (E.27) — note
    /// there is no `isEnabled:` parameter, so a conditional is a branch in the
    /// view rather than an argument here.
    case floating
    /// Content. Numbers, tables, statistics, quotations.
    case solid
}

extension View {
    /// The one place a box gets its background, so "which layer is this on" is
    /// a decision somebody made rather than whatever the nearest screen did.
    @ViewBuilder
    func surface(_ surface: Surface, radius: CGFloat = Radius.box) -> some View {
        switch surface {
        case .floating:
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        case .solid:
            // `.background` rather than glass, and a shape rather than a plain
            // fill, so a solid layer is visibly a layer without becoming
            // translucent.
            self.background(.background.secondary, in: RoundedRectangle(cornerRadius: radius))
        }
    }

    /// A standard content box: solid, padded once, with the same corner as
    /// every other box.
    func contentBox() -> some View {
        self.padding(Space.box).surface(.solid)
    }
}

/// The heading every area uses, so "where am I" reads the same everywhere
/// (§24.1's Deference: one shape — heading, main action, content, explanation).
struct SectionHeading: View {
    let title: String
    /// The one sentence explaining what this section is for. §24.1 is explicit
    /// that the explanations are *not* to be deleted — they are what makes the
    /// numbers in this app arguable — only moved out of the first line.
    var help: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(title).font(.headline)
                if let help {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.title) { action.run() }
            }
        }
        .padding(.bottom, Space.row)
        .accessibilityElement(children: .contain)
    }
}
