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

private let catalogue = Localisation.bundle(named: "CoAIWorkspace_Knowledge.bundle")

/// Named `localised` rather than `t`: `LCClass` and `LCSubject` in this module
/// declare `case t = "T"` (Library of Congress class T), and inside those enums
/// a one-letter helper resolves to the case instead of the function. The second
/// module to hit this — `Analysis` hit it via `let t` for a t-statistic — so
/// the long name is the module default now rather than a special case.
func localised(_ key: String.LocalizationValue, _ comment: StaticString) -> String {
    String(localized: key, bundle: catalogue, comment: comment)
}
