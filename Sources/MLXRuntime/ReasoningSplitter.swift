import Foundation

// ─────────────────────────────────────────────────────────────
// Separating what a local model thought from what it said.
//
// A hosted OpenAI-compatible endpoint hands these back in two different
// fields (`reasoning_content` vs `content` — ARCHITECTURE E.9 case 8c). A
// model we run ourselves gives us one stream of text with `<think>` markers in
// it, so the split has to happen here, and it has to happen while streaming:
// merging the two would store thinking as the reply and make every
// schema-constrained call return a paragraph of deliberation instead of JSON.
//
// The tags can be cut in half by a chunk boundary, so anything that could
// still turn out to be the start of a tag is held back rather than emitted.
// ─────────────────────────────────────────────────────────────

enum ResponseSegment: Equatable, Sendable {
    case answer(String)
    case reasoning(String)
}

struct ReasoningSplitter {
    static let openTag = "<think>"
    static let closeTag = "</think>"

    private var insideReasoning: Bool
    /// Text held back because it might be the first half of a tag.
    private var pending = ""
    /// The newline pair that follows `</think>` belongs to the markup, not to
    /// the answer, and a reply that starts with blank lines looks broken.
    private var trimLeadingWhitespace = false

    /// - Parameter startsInsideReasoning: whether the *prompt* left a `<think>`
    ///   block open. Qwen-style templates append the opening tag themselves, so
    ///   the model's own output begins mid-thought with no tag to detect — see
    ///   `ChatTemplate.opensReasoningBlock`.
    init(startsInsideReasoning: Bool) {
        self.insideReasoning = startsInsideReasoning
    }

    mutating func consume(_ chunk: String) -> [ResponseSegment] {
        pending += chunk
        var segments: [ResponseSegment] = []

        while true {
            let tag = insideReasoning ? Self.closeTag : Self.openTag
            if let range = pending.range(of: tag) {
                append(String(pending[pending.startIndex..<range.lowerBound]), to: &segments)
                pending = String(pending[range.upperBound...])
                insideReasoning.toggle()
                // Only the answer suffers from the markup's trailing newlines;
                // reasoning is not shown next to anything.
                trimLeadingWhitespace = !insideReasoning
                continue
            }
            // No complete tag: emit everything that cannot still become one.
            let held = Self.tagPrefixLength(atEndOf: pending, tag: tag)
            let cut = pending.index(pending.endIndex, offsetBy: -held)
            append(String(pending[pending.startIndex..<cut]), to: &segments)
            pending = String(pending[cut...])
            return segments
        }
    }

    /// Whatever was held back at the end of the stream. A truncated tag is text
    /// the model actually produced; dropping it would silently lose output.
    mutating func flush() -> [ResponseSegment] {
        var segments: [ResponseSegment] = []
        append(pending, to: &segments)
        pending = ""
        return segments
    }

    private mutating func append(_ text: String, to segments: inout [ResponseSegment]) {
        var text = text
        if trimLeadingWhitespace, !insideReasoning {
            text = String(text.drop { $0 == "\n" || $0 == "\r" || $0 == " " })
            if !text.isEmpty { trimLeadingWhitespace = false }
        }
        guard !text.isEmpty else { return }
        segments.append(insideReasoning ? .reasoning(text) : .answer(text))
    }

    /// Length of the longest suffix of `text` that is a proper prefix of `tag`.
    private static func tagPrefixLength(atEndOf text: String, tag: String) -> Int {
        let maximum = min(tag.count - 1, text.count)
        var length = maximum
        while length > 0 {
            if text.hasSuffix(String(tag.prefix(length))) { return length }
            length -= 1
        }
        return 0
    }
}
