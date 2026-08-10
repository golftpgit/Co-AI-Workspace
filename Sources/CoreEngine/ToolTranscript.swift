import Foundation

// ─────────────────────────────────────────────────────────────
// How a tool call is written into the conversation, in one place.
//
// It used to be `"\(name)\n\(output)"`, which threw away the one fact the
// reader most needs: whether the call actually ran. On reload every historical
// tool call rendered as "เสร็จแล้ว" — including the ones the user had refused
// and the ones for tools that do not exist. A transcript that quietly upgrades
// a refusal into a success is worse than no transcript.
//
// The marker is plain readable text rather than a delimiter or a JSON blob,
// because this string is also what a later turn replays to the model: it
// should read as a sentence, not as a wire format.
// ─────────────────────────────────────────────────────────────

public enum ToolTranscript {
    public struct Entry: Sendable, Equatable {
        public let toolName: String
        public let executed: Bool
        public let text: String

        public init(toolName: String, executed: Bool, text: String) {
            self.toolName = toolName
            self.executed = executed
            self.text = text
        }
    }

    static let blockedSuffix = " (ไม่ได้รัน)"

    public static func encode(_ entry: Entry) -> String {
        let header = entry.toolName + (entry.executed ? "" : blockedSuffix)
        return "\(header)\n\(entry.text)"
    }

    /// Tolerant by design: a row written before this format existed still
    /// decodes, it just reports what it can.
    public static func decode(_ content: String) -> Entry {
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = parts.first.map(String.init) ?? content
        let text = parts.count > 1 ? String(parts[1]) : ""
        let executed = !header.hasSuffix(blockedSuffix)
        let name = executed ? header : String(header.dropLast(blockedSuffix.count))
        return Entry(toolName: name, executed: executed, text: text)
    }
}
