import Foundation

/// Generates identifiers that cannot be mistaken for another type.
///
/// SurrealDB v3 coerces *bound* strings by shape: `"table:id"` becomes a
/// record link and `"a487d755-9ec0-…"` becomes a UUID value, both of which
/// then fail a `TYPE string` field with a confusing error (ARCHITECTURE
/// App. C.0). A short alphabetic prefix plus dash-free hex removes the
/// ambiguity everywhere ids travel — parameters, JSON, log lines.
public enum OpaqueID {
    /// e.g. `cv_3f8a1c2b9d4e5f60718293a4b5c6d7e8`
    public static func make(_ prefix: String) -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)_\(hex)"
    }

    public static let conversation = "cv"
    public static let message = "ms"
    public static let span = "sp"
    public static let approval = "ap"
    public static let assignment = "as"
}
