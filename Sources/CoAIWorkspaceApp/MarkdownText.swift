import SwiftUI

// ─────────────────────────────────────────────────────────────
// Bold that is actually bold (ARCHITECTURE §14.2).
//
// SwiftUI parses markdown in `Text` only when the argument is a *string
// literal* — that is what makes it a `LocalizedStringKey`. The moment a line
// grows past the margin and somebody splits it with `+`, the argument becomes a
// `String` and the asterisks stop being emphasis and start being asterisks.
//
// Driving the participants screen found exactly that: "a different file from the answers" was
// on screen wrapped in two stars. It is a small thing that reads as sloppiness
// in the one place the app is explaining a privacy guarantee, and it is invisible
// to every test — so `check.sh` now fails on a concatenated `Text` containing
// `**`, and this is where those strings go instead.
// ─────────────────────────────────────────────────────────────

extension Text {
    /// A `Text` from a runtime string, with `**bold**` rendered rather than
    /// printed. Falls back to the plain string if the markdown will not parse,
    /// because a caption is worth showing imperfectly and not worth crashing for.
    init(markdown text: String) {
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            self.init(parsed)
        } else {
            self.init(verbatim: text)
        }
    }
}
