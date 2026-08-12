import Foundation

// ─────────────────────────────────────────────────────────────
// Tool calls a small model got *nearly* right.
//
// The library's parser expects `<tool_call>{json}</tool_call>`. Qwen3-VL-4B,
// following the example printed in its own chat template, emitted the opening
// tag twice — so the parser handed the whole block back as prose and the turn
// looked like the model had ignored the tools entirely. The call was right
// there in the text, correctly formed, inside one tag too many.
//
// Salvage rather than a laxer parser: the library keeps its behaviour, and
// this runs only when the parser found nothing at all. A model that formats
// correctly never reaches this file.
// ─────────────────────────────────────────────────────────────

enum ToolCallSalvage {
    static let openTag = "<tool_call>"
    static let closeTag = "</tool_call>"

    struct Call: Equatable {
        let name: String
        let argumentsJSON: String
    }

    /// Every `{"name": …, "arguments": {…}}` found inside tool-call markup.
    static func calls(in text: String) -> [Call] {
        var found: [Call] = []
        var rest = Substring(text)

        while let open = rest.range(of: openTag) {
            let afterOpen = rest[open.upperBound...]
            let close = afterOpen.range(of: closeTag)
            let block = close.map { afterOpen[..<$0.lowerBound] } ?? afterOpen

            if let json = StructuredOutput.firstJSONObject(in: String(block)),
               let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                   as? [String: Any],
               let name = object["name"] as? String {
                let arguments = object["arguments"] ?? [String: Any]()
                let encoded = (try? JSONSerialization.data(withJSONObject: arguments,
                                                           options: [.withoutEscapingSlashes]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                found.append(Call(name: name, argumentsJSON: encoded))
            }
            guard let close else { break }
            rest = afterOpen[close.upperBound...]
        }
        return found
    }

    /// The prose with the markup taken out, so a salvaged turn does not leave
    /// a half-parsed XML tag in the transcript.
    static func stripped(_ text: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let open = rest.range(of: openTag) {
            output += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: closeTag) else {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            rest = afterOpen[close.upperBound...]
        }
        output += rest
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
