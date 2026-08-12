import Testing
import Foundation
@testable import MLXRuntime

// ─────────────────────────────────────────────────────────────
// Keeping thinking out of the answer, on a tier that gets one stream of text.
// ─────────────────────────────────────────────────────────────

private func segments(_ chunks: [String], startsInsideReasoning: Bool = false) -> [ResponseSegment] {
    var splitter = ReasoningSplitter(startsInsideReasoning: startsInsideReasoning)
    var all: [ResponseSegment] = []
    for chunk in chunks { all += splitter.consume(chunk) }
    all += splitter.flush()
    return all
}

private func answer(_ segments: [ResponseSegment]) -> String {
    segments.compactMap { if case .answer(let text) = $0 { return text } else { return nil } }
        .joined()
}

private func reasoning(_ segments: [ResponseSegment]) -> String {
    segments.compactMap { if case .reasoning(let text) = $0 { return text } else { return nil } }
        .joined()
}

@Suite("Reasoning splitter")
struct ReasoningSplitterTests {

    @Test("a tagged thought never reaches the answer")
    func splitsTaggedReasoning() {
        let result = segments(["<think>17×3 is 51</think>\n\n51"])
        #expect(reasoning(result) == "17×3 is 51")
        #expect(answer(result) == "51")
    }

    /// The tags arrive a token at a time, so a chunk boundary lands in the
    /// middle of one regularly. Emitting "</thi" as answer text would corrupt
    /// every structured reply and show markup to the user.
    @Test("a tag split across chunks is still a tag")
    func handlesSplitTags() {
        let result = segments(["<thi", "nk>thinking", " hard</th", "ink>the answer"])
        #expect(reasoning(result) == "thinking hard")
        #expect(answer(result) == "the answer")
    }

    /// Qwen-style templates append `<think>` to the prompt, so the model's own
    /// output starts mid-thought with no opening tag anywhere. A splitter that
    /// waits for one reports the entire chain of thought as the answer — and
    /// with a response schema, that answer contains no JSON at all.
    @Test("output that begins inside an open think block is reasoning, not answer")
    func handlesPreSeededThinkTag() {
        let result = segments(["I should count the patients", "</think>", "\n\n42 patients"],
                              startsInsideReasoning: true)
        #expect(reasoning(result) == "I should count the patients")
        #expect(answer(result) == "42 patients")
    }

    @Test("text with no tags at all is the answer")
    func plainTextIsAnswer() {
        let result = segments(["hello ", "world"])
        #expect(answer(result) == "hello world")
        #expect(reasoning(result).isEmpty)
    }

    /// Hitting the token cap mid-thought is normal on a local model. The
    /// reasoning must still be reported — `LLMCompletion.structuredText` falls
    /// back to it — rather than silently dropped at the end of the stream.
    @Test("a thought cut off by the token limit is not lost")
    func unterminatedReasoningIsFlushed() {
        let result = segments(["still thinking about it"], startsInsideReasoning: true)
        #expect(reasoning(result) == "still thinking about it")
        #expect(answer(result).isEmpty)
    }

    @Test("a truncated tag at the very end is kept as the text it is")
    func trailingPartialTagIsFlushed() {
        let result = segments(["the answer is 51 <thi"])
        #expect(answer(result) == "the answer is 51 <thi")
    }

    @Test("the blank lines the markup leaves behind are not part of the answer")
    func trimsTheGapAfterTheClosingTag() {
        let result = segments(["<think>hmm</think>\n\n", "51"])
        #expect(answer(result) == "51")
    }
}

@Suite("Structured output on a tier with no guided generation")
struct StructuredOutputTests {

    @Test("the object is found inside whatever the model wrote around it")
    func extractsFromProse() {
        let text = """
        Sure! Here is the JSON you asked for:
        ```json
        {"role": "engineer", "needsClarification": false}
        ```
        Let me know if you need anything else.
        """
        #expect(StructuredOutput.firstJSONObject(in: text)
                == #"{"role": "engineer", "needsClarification": false}"#)
    }

    @Test("a brace inside a string does not end the object early")
    func respectsStringsAndEscapes() {
        let text = #"prefix {"note": "a } and a \" quote", "ok": true} suffix"#
        let found = StructuredOutput.firstJSONObject(in: text)
        #expect(found == #"{"note": "a } and a \" quote", "ok": true}"#)
    }

    @Test("nested objects come back whole")
    func keepsNestedObjects() {
        let text = #"{"outer": {"inner": 1}}"#
        #expect(StructuredOutput.firstJSONObject(in: text) == text)
    }

    /// The alternative is handing the caller a string that fails to decode
    /// later, somewhere with no idea which model produced it.
    @Test("text with no object in it is nothing, not a guess")
    func returnsNilWhenThereIsNoObject() {
        #expect(StructuredOutput.firstJSONObject(in: "I cannot answer that.") == nil)
        #expect(StructuredOutput.firstJSONObject(in: "{not json at all}") == nil)
    }

    @Test("a malformed object does not hide a valid one after it")
    func keepsLookingAfterMalformedObject() {
        let text = #"{oops} then {"role":"analyst"}"#
        #expect(StructuredOutput.firstJSONObject(in: text) == #"{"role":"analyst"}"#)
    }

    @Test("the schema goes into the prompt, because nothing here can constrain decoding")
    func instructionCarriesTheSchema() {
        let instruction = StructuredOutput.instruction(name: "Routing",
                                                       schemaJSON: #"{"type":"object"}"#)
        #expect(instruction.contains("Routing"))
        #expect(instruction.contains(#"{"type":"object"}"#))
    }
}

@Suite("Salvaging a tool call the parser missed")
struct ToolCallSalvageTests {

    /// What Qwen3-VL-4B actually emitted, following the example in its own
    /// chat template: the opening tag twice. The library's parser handed the
    /// whole block back as prose, so the turn looked like the model had
    /// ignored the tools — with a perfectly good call sitting inside it.
    @Test("a doubled opening tag does not lose the call")
    func salvagesDoubledOpeningTag() {
        let text = """
        <tool_call>
        <tool_call>
        {"name": "lookup_patient_count", "arguments": {"cohort": "diabetes"}}
        </tool_call>
        """
        let calls = ToolCallSalvage.calls(in: text)
        #expect(calls.count == 1)
        #expect(calls.first?.name == "lookup_patient_count")
        #expect(calls.first?.argumentsJSON == #"{"cohort":"diabetes"}"#)
    }

    @Test("two calls in one turn both come back")
    func salvagesSeveralCalls() {
        let text = #"""
        <tool_call>{"name": "a", "arguments": {"x": 1}}</tool_call>
        then
        <tool_call>{"name": "b", "arguments": {}}</tool_call>
        """#
        #expect(ToolCallSalvage.calls(in: text).map(\.name) == ["a", "b"])
    }

    @Test("the markup is taken out of what the user sees")
    func stripsMarkup() {
        let text = #"""
        ก่อนหน้า <tool_call>{"name": "a", "arguments": {}}</tool_call> หลังจากนั้น
        """#
        #expect(ToolCallSalvage.stripped(text) == "ก่อนหน้า  หลังจากนั้น")
    }

    /// Only a last resort: prose that merely mentions the tag is not a call.
    @Test("text with no call in it salvages nothing")
    func findsNothingWhenThereIsNothing() {
        #expect(ToolCallSalvage.calls(in: "ไม่ได้เรียกทูล").isEmpty)
        #expect(ToolCallSalvage.calls(in: "<tool_call>not json</tool_call>").isEmpty)
    }
}

@Suite("A shape to copy, not a schema to interpret")
struct SchemaExampleTests {

    /// Measured on Qwen3-VL-4B: the schema alone produced `{"role: "engineer"`
    /// — a key with no closing quote and no closing brace. With the example
    /// below in the prompt, the same request comes back as JSON.
    @Test("the example fills every required key, using the enum's first case")
    func buildsExampleFromSchema() {
        let schema = #"""
        {"type":"object",
         "properties":{"role":{"type":"string","enum":["researcher","analyst"]},
                       "needsClarification":{"type":"boolean"}},
         "required":["role","needsClarification"]}
        """#
        #expect(StructuredOutput.exampleObject(for: schema)
                == #"{"role": "researcher", "needsClarification": false}"#)
    }

    @Test("numbers, arrays and objects get placeholders of the right type")
    func coversTheOtherTypes() {
        let schema = #"""
        {"type":"object",
         "properties":{"n":{"type":"number"},"xs":{"type":"array"},"o":{"type":"object"}},
         "required":["n","xs","o"]}
        """#
        #expect(StructuredOutput.exampleObject(for: schema)
                == #"{"n": 0, "xs": [], "o": {}}"#)
    }

    @Test("a schema with no properties has no example, and says so with nil")
    func noPropertiesNoExample() {
        #expect(StructuredOutput.exampleObject(for: #"{"type":"string"}"#) == nil)
    }

    @Test("the instruction carries the example and the schema")
    func instructionCarriesBoth() {
        let schema = #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}"#
        let instruction = StructuredOutput.instruction(name: "Verdict", schemaJSON: schema)
        #expect(instruction.contains(#"{"ok": false}"#))
        #expect(instruction.contains("Verdict"))
        #expect(instruction.contains(schema))
    }
}
