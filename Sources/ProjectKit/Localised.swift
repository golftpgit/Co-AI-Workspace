import Foundation
import Localisation

// ─────────────────────────────────────────────────────────────
// This module's own string catalogue.
//
// Every module that shows text needs one of these, bound to its own bundle —
// the same three-line shape as `CoAIWorkspaceApp/Localised.swift`, and for the
// same reasons written there: the key is the English sentence, every string
// carries a comment, and the bundle is found by `Localisation.bundle(named:)`
// rather than `Bundle.module`, which cannot be reached from inside a packaged
// `.app` (see that type for the measurement).
//
// **Why a domain module has user-facing text at all.** These are the words for
// things the domain owns — a project's stage, a register entry's kind, the
// sentences a progress report is assembled from. They reach the screen through
// values rather than through views, so a screen cannot translate them on the
// way past; the module that defines the concept is the only place that can.
// ─────────────────────────────────────────────────────────────

private let catalogue = Localisation.bundle(named: "CoAIWorkspace_ProjectKit.bundle")

/// A localised string from this module's catalogue.
///
/// - Parameters:
///   - key: the English text, which is also the key.
///   - comment: what a translator needs that the sentence does not say.
func t(_ key: String.LocalizationValue, _ comment: StaticString) -> String {
    String(localized: key, bundle: catalogue, comment: comment)
}
