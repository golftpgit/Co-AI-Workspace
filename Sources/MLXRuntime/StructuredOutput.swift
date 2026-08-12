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
    ///
    /// The key list is spelled out on top of the schema because a 4B model
    /// reads a shape better than a specification — measured on Qwen3-VL-4B,
    /// the schema alone produced `{"role: "engineer"` with a quote and both
    /// braces missing, which is not JSON at all.
    static func instruction(name: String, schemaJSON: String) -> String {
        var lines = [
            "Reply with one JSON object and nothing else. No explanation, "
            + "no markdown fence, no text before or after it.",
            "Start your reply with { and end it with }.",
        ]
        // A shape to copy, not a specification to satisfy. Measured on
        // Qwen3-VL-4B: given the schema alone it produced `{"role: "engineer"`
        // — a key with no closing quote, a newline where the comma belonged,
        // and no closing brace. Given the example below, the same request
        // comes back as JSON.
        if let example = exampleObject(for: schemaJSON) {
            lines.append("Copy this shape exactly, replacing only the values:")
            lines.append(example)
        }
        lines.append("It must match this JSON Schema named \"\(name)\":")
        lines.append(schemaJSON)
        return lines.joined(separator: "\n")
    }

    /// A filled-in skeleton of the schema: every required key, with a value of
    /// the right type (the first `enum` case when the schema names one).
    static func exampleObject(for schemaJSON: String) -> String? {
        guard let schema = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))
                as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { return nil }
        let required = (schema["required"] as? [String]) ?? Array(properties.keys).sorted()

        var pairs: [String] = []
        for key in required {
            guard let property = properties[key] as? [String: Any] else { continue }
            pairs.append("\"\(key)\": \(placeholder(for: property))")
        }
        return pairs.isEmpty ? nil : "{" + pairs.joined(separator: ", ") + "}"
    }

    private static func placeholder(for property: [String: Any]) -> String {
        if let cases = property["enum"] as? [Any], let first = cases.first {
            return "\"\(first)\""
        }
        switch property["type"] as? String {
        case "boolean": return "false"
        case "integer", "number": return "0"
        case "array": return "[]"
        case "object": return "{}"
        default: return "\"…\""
        }
    }

    /// `required` when the schema names it, otherwise every property.
    static func requiredKeys(in schemaJSON: String) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))
                as? [String: Any] else { return nil }
        if let required = object["required"] as? [String] { return required }
        return (object["properties"] as? [String: Any]).map { Array($0.keys).sorted() }
    }

    /// The first JSON object in the text, repaired if a small model mangled
    /// its punctuation.
    ///
    /// Measured on Qwen3-VL-4B at temperature 0, asked in Thai: it produced
    /// `{"role: "researcher", needsClarification: false` — every value right,
    /// a closing quote missing from one key, quotes missing from another, and
    /// no closing brace. The same request in English came back perfect. The
    /// content was never in doubt; the punctuation was.
    ///
    /// Only these three repairs, and only when the result parses: a repair
    /// that guesses at *values* would invent an answer, which is the one thing
    /// this layer must never do.
    static func object(in text: String) -> String? {
        if let clean = firstJSONObject(in: text) { return clean }
        guard let candidate = firstBracedSpan(in: text) else { return nil }

        for repaired in [quotedKeys(candidate), candidate].map(closedBraces) {
            if (try? JSONSerialization.jsonObject(with: Data(repaired.utf8))) != nil {
                return repaired
            }
        }
        return nil
    }

    /// `{` to the last `}`, or to the end when the model never closed it.
    private static func firstBracedSpan(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        let end = text.lastIndex(of: "}").map { text.index(after: $0) } ?? text.endIndex
        guard start < end else { return nil }
        return String(text[start..<end])
    }

    /// `{"role: "x", needsClarification: false` → both keys quoted properly.
    private static func quotedKeys(_ text: String) -> String {
        var result = text
        // A key whose closing quote is missing: `"role: ` → `"role": `
        result = result.replacingOccurrences(
            of: #"("[A-Za-z_][A-Za-z0-9_ ]*)\s*:"#,
            with: "$1\":",
            options: .regularExpression)
        // A key with no quotes at all: `, needsClarification:` → `, "needsClarification":`
        result = result.replacingOccurrences(
            of: #"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
            with: "$1\"$2\":",
            options: .regularExpression)
        return result
    }

    /// Appends the braces and brackets the model never closed.
    private static func closedBraces(_ text: String) -> String {
        var depth = 0
        var brackets = 0
        var inString = false
        var escaped = false
        for character in text {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": depth += 1
            case "}": depth -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            default: break
            }
        }
        var result = text
        if inString { result += "\"" }
        result += String(repeating: "]", count: max(0, brackets))
        result += String(repeating: "}", count: max(0, depth))
        return result
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
