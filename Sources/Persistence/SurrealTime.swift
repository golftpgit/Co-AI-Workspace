import Foundation

/// Datetime conversion for SurrealDB, in one place.
///
/// `ISO8601DateFormatter` is a class and not Sendable, so Swift 6 rejects it
/// as a shared static. `Date.ISO8601FormatStyle` is a value type and is safe
/// to hold globally — another instance of the pattern recorded in
/// ARCHITECTURE App. C: prefer value-typed Foundation APIs at boundaries.
enum SurrealTime {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func string(from date: Date) -> String {
        date.formatted(withFraction)
    }

    /// SurrealDB emits fractional seconds, but be tolerant of either form.
    static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        if let d = try? Date(raw, strategy: withFraction) { return d }
        return try? Date(raw, strategy: withoutFraction)
    }
}
