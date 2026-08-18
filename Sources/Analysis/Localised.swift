import Foundation
import Localisation

// ─────────────────────────────────────────────────────────────
// This module's own string catalogue — the same three-line shape as every
// other module's (see `CoAIWorkspaceApp/Localised.swift` for the reasoning,
// and `Localisation` for why the bundle is found rather than assumed).
//
// **What is user-facing here.** Statistical verdicts. `StatGate` decides
// whether a test may be run and says why not; the SQL guard says what a
// statement will do before it runs. Those sentences are read by a person who
// is about to make a research decision, so they are text — and their exact
// wording is what the tests pin.
// ─────────────────────────────────────────────────────────────

private let catalogue = Localisation.bundle(named: "CoAIWorkspace_Analysis.bundle")

/// A localised string from this module's catalogue.
/// Named `localised` rather than `t`: this module computes t-statistics, and
/// every t-test in it writes `let t = …`. A one-letter helper that a local
/// shadows is a compile error at each new test — so the module spells it out.
func localised(_ key: String.LocalizationValue, _ comment: StaticString) -> String {
    String(localized: key, bundle: catalogue, comment: comment)
}
