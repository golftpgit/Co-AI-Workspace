import Foundation

// ─────────────────────────────────────────────────────────────
// Finding a module's string catalogue at runtime (2026-08-18).
//
// **Why this exists instead of `Bundle.module`.** SwiftPM generates, for every
// target with resources:
//
//     Bundle.main.bundleURL.appendingPathComponent("<pkg>_<target>.bundle")
//     ?? Bundle(path: "<the build directory on the machine that compiled it>")
//     ?? fatalError("could not load resource bundle")
//
// For an app, `Bundle.main.bundleURL` is the `.app` itself — so it looks at the
// bundle *root*, where a `.app` may not have loose contents: `codesign` refuses
// with "unsealed contents present in the bundle root". The only valid place is
// `Contents/Resources`, and that is the one place the accessor does not look.
//
// So in the packaged app the first candidate misses, the second is an absolute
// path that exists on exactly one machine in the world, and the third is a
// crash. Measured: the app died on its first localised `Text`, before drawing
// anything, while the same binary run from the terminal was fine — because
// there the build-directory fallback resolved. Works here, traps everywhere
// else, which is the P9.6 trap this project already has a rule about.
//
// **What this does instead**: look where the bundle can actually be, in the
// order it can actually be there, and — the part that matters — **fall back to
// the main bundle rather than crashing**. A missing catalogue is supposed to
// degrade to English. It is not supposed to be fatal, and it certainly is not
// supposed to be fatal only once the app is packaged.
// ─────────────────────────────────────────────────────────────

public enum Localisation {
    /// The bundle holding a module's `.lproj` catalogues.
    ///
    /// - Parameter name: the SwiftPM bundle name, `<package>_<target>.bundle`.
    /// - Returns: that bundle, or `Bundle.main` if it cannot be found — which
    ///   yields the keys, and the keys are English sentences.
    public static func bundle(named name: String) -> Bundle {
        if let cached = cache.withLock({ $0[name] }) { return cached }
        let resolved = resolve(name)
        cache.withLock { $0[name] = resolved }
        return resolved
    }

    private static let cache = Mutex<[String: Bundle]>([:])

    private static func resolve(_ name: String) -> Bundle {
        let candidates = [
            // A packaged `.app`: the only place codesign allows.
            Bundle.main.resourceURL,
            // `swift run` / `swift test`: beside the executable, which is also
            // the one place SwiftPM's own accessor looks.
            Bundle.main.bundleURL,
        ]
        for base in candidates.compactMap({ $0 }) {
            if let found = Bundle(url: base.appending(path: name)) { return found }
        }
        return .main
    }
}

/// A tiny lock so the lookup happens once per module without importing anything.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
