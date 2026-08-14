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
    public static let project = "pj"
    public static let workPackage = "wp"
    public static let exception = "ex"
    public static let register = "rg"
    public static let baseline = "bl"
    public static let benefit = "bn"
    public static let tailoring = "tr"
    public static let report = "rp"
    // M15 Instruments (§20.3, P11.2)
    public static let instrument = "in"
    public static let item = "it"
    public static let construct = "cn"
    public static let researchQuestion = "rq"

    // M15 Instruments, the qualitative half (§20.3, P11.8)
    public static let codebook = "cb"
    public static let code = "cd"
    public static let codingUnit = "cu"
    public static let transcript = "ts"
}
