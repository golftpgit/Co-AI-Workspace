import Foundation
import Localisation

// ─────────────────────────────────────────────────────────────
// This module's own catalogue.
//
// `Bundle.module` is not used here, and not anywhere outside `Localisation`:
// the accessor SwiftPM generates looks beside `Bundle.main.bundleURL`, which
// inside a packaged `.app` is the bundle *root* — the one place `codesign`
// forbids loose resources (E.49). `Localisation.bundle(named:)` looks in
// `Contents/Resources` first and degrades to English rather than trapping.
// ─────────────────────────────────────────────────────────────

private let catalogue = Localisation.bundle(named: "CoAIWorkspace_AgentKit.bundle")

/// `localised` rather than `t`: two modules have now had a one-letter helper
/// shadowed out from under them — `Analysis` by `let t` for a t-statistic,
/// `Knowledge` by `case t = "T"` — so the long name is the default for a new
/// module rather than something to reach for after the collision.
func localised(_ key: String.LocalizationValue, _ comment: StaticString) -> String {
    String(localized: key, bundle: catalogue, comment: comment)
}
