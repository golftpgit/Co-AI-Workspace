import Foundation
import SwiftUI
import Localisation

// ─────────────────────────────────────────────────────────────
// Text on screen, in the reader's language (2026-08-17).
//
// The app was written in Thai — every label, every explanation, every refusal.
// That made it unusable to anybody who does not read Thai, which is most people
// who would want it. The owner's decision was to open it up, and to do that as
// **a localisation system with English as the base language** rather than a
// one-way translation: the point is more languages later, and only one of those
// two makes the next language a translation job instead of a code job.
//
// **Why this file exists at all.** `Text("…")` localises against the *main*
// bundle. Inside a SwiftPM module that is the wrong bundle — the strings live
// in this module's own — and the failure is silent: the key comes back as
// itself, so the screen shows a raw key and nothing errors. One helper, used
// everywhere, is the difference between that being impossible and being a
// mistake anybody can make once per file.
//
// **The key is the English sentence**, not a dotted identifier. `"Save"` rather
// than `"button.save"`, because a key that is already the English text means a
// missing translation degrades to correct English instead of to `button.save`,
// and because the person writing the view can read what it says.
//
// **Not `Bundle.module`** — see `Localisation`. SwiftPM's accessor looks at the
// bundle root of the `.app`, where `codesign` forbids loose contents, and its
// only fallback is an absolute path on the machine that compiled it. In the
// packaged app it crashed on the first localised `Text` (2026-08-18).
// ─────────────────────────────────────────────────────────────

/// This module's catalogue, found once.
private let catalogue = Localisation.bundle(named: "CoAIWorkspace_CoAIWorkspaceApp.bundle")

/// A localised string from this module's catalogue.
///
/// - Parameters:
///   - key: the English text, which is also the key.
///   - comment: what a translator needs to know that the sentence does not say
///     — who says it, when, and what happens next. Never optional in practice:
///     "Open" alone is untranslatable into languages that inflect by object.
func t(_ key: String.LocalizationValue, _ comment: StaticString) -> String {
    String(localized: key, bundle: catalogue, comment: comment)
}

extension Text {
    /// `Text` that knows which bundle its words are in.
    ///
    /// Takes the comment for the same reason `t` does: a translator seeing only
    /// "Stop" cannot tell whether it stops a process, a subscription, or a
    /// recording, and this app has all three.
    ///
    /// **Goes through `Text(markdown:)`, and that is a fix, not a flourish.**
    /// SwiftUI parses markdown only when the argument is a string *literal*; a
    /// looked-up string is not one. So the first pass of this migration turned
    /// `Text("… **including rounds of rework** …")` — which rendered bold —
    /// into a call that printed its own asterisks on screen. Exactly the U5
    /// failure, arriving through a door U5 does not watch: that rule looks for
    /// `+` concatenation, and there is none here.
    init(localised key: String.LocalizationValue, _ comment: StaticString) {
        self.init(markdown: String(localized: key, bundle: catalogue, comment: comment))
    }
}
