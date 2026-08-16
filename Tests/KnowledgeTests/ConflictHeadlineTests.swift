import Testing
import Foundation
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// U12 — the card was titled with whatever the user typed.
//
// The `question` on a conflict came from the model, falling back to the search
// that surfaced the pair — which is the user's prompt. So a list of cards read
// as ten copies of the search box, and none of them said what the two
// passages disagreed about.
//
// Nothing here writes prose. The rule is only: a title has to be about the two
// passages, and one that is not gets replaced by the passages themselves.
// ─────────────────────────────────────────────────────────────

private let a = "ค่ามาตรฐานของ HbA1c ในผู้ป่วยเบาหวานชนิดที่ 2 คือน้อยกว่า 7%"
private let b = "ค่ามาตรฐานของ HbA1c ในผู้สูงอายุที่มีโรคร่วมควรอยู่ที่ 8%"

@Suite("What a conflict card is called (U12)")
struct ConflictHeadlineTests {

    /// The bug, in one case: the prompt became the title.
    @Test("an instruction is not a question about the sources")
    func instructionsAreRejected() {
        for prompt in ["จงสรุปแนวทางการคุมน้ำตาลในผู้ป่วยเบาหวาน",
                       "ช่วยหาค่ามาตรฐาน HbA1c หน่อย",
                       "summarize the HbA1c guidance"] {
            #expect(ConflictHeadline.isUsable(prompt, a: a, b: b) == false,
                    "kept an instruction as a title: \(prompt)")
        }
    }

    @Test("a question about what the two say is kept as written")
    func groundedQuestionsSurvive() {
        let question = "ค่ามาตรฐาน HbA1c ควรเป็นเท่าไร"
        #expect(ConflictHeadline.isUsable(question, a: a, b: b))
        #expect(ConflictHeadline.headline(candidate: question, a: a, b: b) == question)
    }

    /// A title can be a perfectly good question and still be about something
    /// else — which is how the search box gets on the card.
    @Test("a question the passages never mention is not about them")
    func ungroundedQuestionsAreRejected() {
        #expect(ConflictHeadline.isUsable("อัตราการเกิดโรคหลอดเลือดสมองต่างกันอย่างไร",
                                          a: a, b: b) == false)
    }

    @Test("the fallback quotes both sides, so it cannot be wrong about the card")
    func fallbackQuotesBoth() {
        let headline = ConflictHeadline.headline(candidate: "จงสรุปให้หน่อย", a: a, b: b)
        #expect(headline.contains("HbA1c"))
        #expect(headline.contains("↔"))
        // Both claims are represented; a title showing only one side reads as
        // an answer rather than a disagreement.
        #expect(headline.contains("7%") || headline.contains("น้อยกว่า"))
        #expect(headline.contains("8%") || headline.contains("ผู้สูงอายุ"))
    }

    @Test("long passages are clipped rather than filling the card")
    func longPassagesAreClipped() {
        let long = String(repeating: "ยาว", count: 200)
        let headline = ConflictHeadline.headline(candidate: "", a: long, b: long)
        #expect(headline.count < 140)
        #expect(headline.contains("…"))
    }

    @Test("an empty or one-word candidate falls back rather than titling a card with nothing")
    func emptyCandidates() {
        #expect(ConflictHeadline.isUsable("", a: a, b: b) == false)
        #expect(ConflictHeadline.isUsable("ค่า", a: a, b: b) == false)
        #expect(ConflictHeadline.headline(candidate: "  ", a: a, b: b).contains("↔"))
    }
}
