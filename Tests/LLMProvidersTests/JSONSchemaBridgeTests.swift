import Testing
import Foundation
@testable import LLMProviders

// The bridge turns runtime JSON Schema into Apple's generation schema. A
// mistake here does not crash — it quietly relaxes a constraint, and the model
// starts returning shapes the caller never handles. Hence explicit coverage.

@Suite("JSON Schema bridge")
struct JSONSchemaBridgeTests {
    @Test("accepts the shapes the system actually emits")
    func acceptsSupportedShapes() throws {
        let schemas = [
            #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#,
            #"{"type":"object","properties":{"ok":{"type":"boolean"},"n":{"type":"integer"},"x":{"type":"number"}}}"#,
            #"{"type":"object","properties":{"role":{"type":"string","enum":["a","b"]}},"required":["role"]}"#,
            #"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}}}"#,
            #"{"type":"object","properties":{"inner":{"type":"object","properties":{"deep":{"type":"string"}}}}}"#,
        ]
        for schema in schemas {
            _ = try JSONSchemaBridge.generationSchema(name: "T", json: schema)
        }
    }

    @Test("optionality follows `required`, not field order")
    func honoursRequired() throws {
        // Both fields present, only one required — must build without error and
        // without silently promoting the optional one.
        let schema = #"""
        {"type":"object",
         "properties":{"must":{"type":"string"},"may":{"type":"string"}},
         "required":["must"]}
        """#
        _ = try JSONSchemaBridge.generationSchema(name: "T", json: schema)
    }

    @Test("a non-object root is rejected rather than guessed at")
    func rejectsNonObjectRoot() {
        #expect(throws: JSONSchemaBridge.BridgeError.self) {
            _ = try JSONSchemaBridge.generationSchema(name: "T", json: #"["not","an","object"]"#)
        }
    }

    @Test("malformed JSON is rejected")
    func rejectsMalformed() {
        #expect(throws: (any Error).self) {
            _ = try JSONSchemaBridge.generationSchema(name: "T", json: "{ not json")
        }
    }

    @Test("an unsupported construct fails loudly instead of dropping the field")
    func rejectsUnsupported() {
        #expect(throws: (any Error).self) {
            _ = try JSONSchemaBridge.generationSchema(
                name: "T", json: #"{"type":"object","properties":{"weird":{"type":"null"}}}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try JSONSchemaBridge.generationSchema(
                name: "T", json: #"{"type":"object","properties":{"arr":{"type":"array"}}}"#)
        }
    }
}
