import Testing
import Foundation
@testable import LLMProviders

// ─────────────────────────────────────────────────────────────
// Keeping thinking out of the answer, wherever it arrives as one stream of
// text.
//
// Lived in MLXRuntime while the local tier was the only place a `<think>` tag
// could reach: a hosted endpoint hands the two back in separate fields. That
// turned out to be a property of the *server's flags*, not of the protocol —
// drop `--reasoning-parser` and vLLM streams the tags in `content` like any
// local model does (E.21). One splitter, used by both tiers (P15.2b).
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
