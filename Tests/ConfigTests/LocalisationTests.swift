import Testing
import Foundation
@testable import Config

// ─────────────────────────────────────────────────────────────
// The localisation mechanism itself (2026-08-17).
//
// This is not a test of any one sentence. It is a test that translations
// **reach the running program**, which is the part that failed silently the
// first time: `.xcstrings` was declared as a resource, SwiftPM shipped the
// authoring file uncompiled, and every lookup fell through to the key. Because
// the keys are English, the app looked perfectly correct — and Thai would never
// have appeared once. Nothing would have said so.
//
// So the check is deliberately about plumbing: the translated bundle is present
// and its contents load. A missing translation degrades to English by design;
// a missing *bundle* degrades to English too, and only one of those is fine.
// ─────────────────────────────────────────────────────────────

@Suite("Translations reach the running program")
struct LocalisationTests {
    @Test("the module ships a translated bundle, not just the English one")
    func translatedBundleIsShipped() throws {
        let thai = try #require(Bundle.module.path(forResource: "th", ofType: "lproj"),
                                "no th.lproj in the bundle — translations were never packaged")
        #expect(Bundle.module.path(forResource: "en", ofType: "lproj") != nil,
                "no en.lproj — the base language has to be present too")
        _ = thai
    }

    @Test("a key resolves to the translation, not back to itself")
    func translationLoads() throws {
        let path = try #require(Bundle.module.path(forResource: "th", ofType: "lproj"))
        let thai = try #require(Bundle(path: path))
        let translated = thai.localizedString(forKey: "Ready", value: nil, table: nil)
        // A lookup that returns its own key is what an uncompiled catalogue
        // looks like from the inside.
        #expect(translated == "พร้อมใช้", "the key came back untranslated")
    }

    /// The assumption `scripts/check.sh` is built on, established by running it
    /// rather than by reading documentation.
    ///
    /// The check derives the keys a build *will* look up by reading the call
    /// sites, and compares them against the keys in the `.strings` files. If it
    /// derives the wrong key the check still passes — and every lookup at
    /// runtime misses, falling back to English, saying nothing. So the rule it
    /// encodes is pinned here: a `String` interpolation becomes `%@`, an `Int`
    /// becomes `%lld`, and they are not interchangeable.
    @Test("an Int in a key is %lld and a String is %@, which is what the key check assumes")
    func interpolationBecomesTheSpecifierTheCheckExpects() throws {
        #expect(String(localized: "\(3) things", bundle: .module) == "MARKER-LLD 3",
                "an Int interpolation did not resolve through the %lld key")
        #expect(String(localized: "\("some") things", bundle: .module) == "MARKER-AT some",
                "a String interpolation did not resolve through the %@ key")

        // And that the translated bundle carries the same two keys, so the
        // check's rule — a translation keeps its key's specifiers — is being
        // measured against a catalogue that really has them.
        let path = try #require(Bundle.module.path(forResource: "th", ofType: "lproj"))
        let thai = try #require(Bundle(path: path))
        #expect(thai.localizedString(forKey: "%lld things", value: nil, table: nil)
                == "MARKER-TH-LLD %lld")
        #expect(thai.localizedString(forKey: "%@ things", value: nil, table: nil)
                == "MARKER-TH-AT %@")
    }

    @Test("English is the base language, so a missing translation reads correctly")
    func englishIsTheFallback() throws {
        let path = try #require(Bundle.module.path(forResource: "en", ofType: "lproj"))
        let english = try #require(Bundle(path: path))
        #expect(english.localizedString(forKey: "Ready", value: nil, table: nil) == "Ready")
        // A key nobody has translated comes back as itself — which is the whole
        // reason the keys are English sentences rather than dotted identifiers.
        #expect(english.localizedString(forKey: "Not translated yet", value: nil, table: nil)
                == "Not translated yet")
    }
}
