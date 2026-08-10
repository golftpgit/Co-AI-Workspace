import Testing
import Foundation
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P2.2's Done-when, in two halves: the loanwords ARCHITECTURE E.3 found
// shattered must survive whole, and the merge layer has to be worth its
// existence in measured retrieval, not in principle.
// ─────────────────────────────────────────────────────────────

@Suite("Thai tokenisation")
struct TokenizerTests {
    @Test("the loanwords NLTokenizer shatters come back whole")
    func loanwordsSurvive() {
        let tokenizer = Tokenizer()

        // Both cases are quoted verbatim from ARCHITECTURE E.3.
        let logistic = tokenizer.tokens("แบบจำลองการถดถอยโลจิสติก")
        #expect(logistic.contains("โลจิสติก"), "got \(logistic)")
        #expect(!logistic.contains("สติ"), "the fragment survived: \(logistic)")

        let covid = tokenizer.tokens("โควิด-19 กับวัคซีน mRNA ในผู้สูงอายุ")
        #expect(covid.contains("โควิด"), "got \(covid)")
        #expect(covid.contains("วัคซีน"), "got \(covid)")
        #expect(covid.contains("mrna"), "Latin terms are kept, lower-cased: \(covid)")
    }

    @Test("without the merge layer they really do shatter")
    func withoutTheLayerTheyShatter() {
        // Proves the fix is load-bearing rather than decorative: the same input
        // through the same segmenter, with only the merge layer removed.
        let plain = Tokenizer(mergesDictionaryTerms: false)
        let tokens = plain.tokens("แบบจำลองการถดถอยโลจิสติก")
        #expect(!tokens.contains("โลจิสติก"), "nothing to fix, so E.3 no longer holds: \(tokens)")
    }

    @Test("native Thai segmentation is left alone")
    func nativeThaiUntouched() {
        let tokens = Tokenizer().tokens("ผู้ป่วยเบาหวานชนิดที่ 2 ที่มีภาวะไตเรื้อรัง")
        // E.3 rated these correct; the merge layer must not disturb them.
        #expect(tokens.contains("ผู้ป่วย"), "got \(tokens)")
        #expect(tokens.contains("เบาหวาน"), "got \(tokens)")
    }

    @Test("a term that is only half a token is left alone")
    func partialOverlapIsNotMerged() {
        // "เซลล์" is in the dictionary; inside "เซลล์เม็ดเลือดแดง" the segmenter
        // may read the boundary differently. Merging on a partial overlap would
        // swallow a neighbouring word, so the layer declines instead.
        let tokens = Tokenizer().tokens("เซลล์เม็ดเลือดแดง")
        #expect(!tokens.isEmpty)
        #expect(tokens.joined() == "เซลล์เม็ดเลือดแดง", "text was altered: \(tokens)")
    }

    @Test("index and query see the same terms")
    func indexAndQueryAgree() {
        // The one invariant that makes BM25 work at all.
        let tokenizer = Tokenizer()
        let document = tokenizer.tokens("การถดถอยโลจิสติกใช้กับข้อมูลทวิภาค")
        let query = tokenizer.tokens("โลจิสติก")
        #expect(query.allSatisfy { document.contains($0) }, "query \(query) vs document \(document)")
    }
}
