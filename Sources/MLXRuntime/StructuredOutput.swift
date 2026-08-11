import Foundation

// ─────────────────────────────────────────────────────────────
// Structured output on a model we run ourselves.
//
// The two tiers around this one enforce a schema for us: Apple's on-device
// model has guided generation, and an OpenAI-compatible server takes
// `response_format: json_schema`. mlx-swift-lm has neither — there is no
// grammar or logit-constraint API in it — so on Tier 0.5 the schema is an
// instruction, and the answer has to be dug out of whatever the model wrote
// around it.
//
// That difference is invisible above `LLMExecutor` on purpose: callers decode
// JSON the same way on every tier. What is *not* hidden is failure — text with
// no JSON object in it is an error from this executor, so the router escalates
// instead of handing a caller an empty string that reads like "no conflicts".
// ─────────────────────────────────────────────────────────────

enum StructuredOutput {
    /// Appended to the system instructions. Deliberately blunt and repetitive:
    /// a 4–9B model follows a short imperative far better than a polite one.
    static func instruction(name: String, schemaJSON: String) -> String {
        """
        Reply with one JSON object and nothing else. No explanation, no \
        markdown fence, no text before or after it.
        The object must match this JSON Schema named "\(name)":
        \(schemaJSON)
        """
    }

    /// The first complete JSON object in the text, or nil.
    ///
    /// Scans for a balanced `{...}`, honouring strings and escapes so a brace
    /// inside a value does not end the object early. Everything else the model
    /// wrote — a code fence, "Here is the JSON:", a trailing remark — is
    /// simply not part of the match.
    static func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let opening = start {
                    let candidate = String(text[opening...index])
                    // Balanced braces are not proof of valid JSON; the caller
                    // is about to decode this, so check here instead of
                    // handing on something that only looks like an object.
                    if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil {
                        return candidate
                    }
                    // Malformed: keep looking. A model that thinks in braces
                    // before answering should not cost the caller its answer.
                    start = nil
                }
            default: continue
            }
        }
        return nil
    }
}
