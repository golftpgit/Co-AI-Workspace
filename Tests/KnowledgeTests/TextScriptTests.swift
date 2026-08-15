import Testing
import Foundation
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P18.1/P18.2 — which language a passage is in, decided from its characters.
//
// The embedding filter this was meant to feed does not exist: measured on the
// real model, translations and real disagreements overlap (E.25), and the
// reason is structural — an embedding measures what a passage is about, and a
// contradiction is about the same thing as what it contradicts. What is left is
// this, and it has to be conservative in one direction: never claim two
// passages are in different languages unless they plainly are.
// ─────────────────────────────────────────────────────────────

private let thaiText = "การนอนหลับที่เพียงพอช่วยลดความเสี่ยงของโรคหัวใจในผู้ใหญ่"
private let englishText = "Adequate sleep reduces the risk of heart disease in adults"
private let otherThaiText = "การออกกำลังกายสม่ำเสมอช่วยควบคุมระดับน้ำตาลในเลือด"

@Suite("Which language a passage is in")
struct TextScriptTests {

    @Test("Thai and English are different languages; two Thai passages are not")
    func readsTheScript() {
        #expect(TextScriptReader.script(of: thaiText) == .thai)
        #expect(TextScriptReader.script(of: englishText) == .latin)
        #expect(TextScriptReader.differentLanguages(thaiText, englishText))
        #expect(TextScriptReader.differentLanguages(thaiText, otherThaiText) == false)
    }

    // A Thai medical paragraph carries English in it — a drug name, a p-value,
    // a citation. Calling that "mixed" would take the rule off exactly the
    // documents it exists for.
    @Test("English inside a Thai sentence is still Thai")
    func latinInsideThaiIsStillThai() {
        let withTerms = "ผู้ป่วยที่ได้รับ metformin มีระดับ HbA1c ลดลงอย่างมีนัยสำคัญ (p < 0.05)"
        #expect(TextScriptReader.script(of: withTerms) == .thai)
        #expect(TextScriptReader.differentLanguages(withTerms, otherThaiText) == false)
    }

    @Test("too little text is undetermined, not a language")
    func shortTextIsUndetermined() {
        #expect(TextScriptReader.script(of: "ok") == .undetermined)
        #expect(TextScriptReader.script(of: "42") == .undetermined)
        // An undetermined side never makes a pair "different languages":
        // everything downstream treats that as a reason to be stricter, and
        // being stricter on a guess is its own kind of wrong.
        #expect(TextScriptReader.differentLanguages("ok", thaiText) == false)
    }

    @Test("a passage that is half and half is neither, not whichever is ahead")
    func halfAndHalfIsMixed() {
        let bilingual = "ภาวะหมดไฟในการทำงาน burnout syndrome is a workplace phenomenon ตามนิยาม WHO"
        #expect(TextScriptReader.script(of: bilingual) == .mixed)
        #expect(TextScriptReader.differentLanguages(bilingual, englishText) == false)
    }

    @Test("cosine is the same measure everywhere it is used")
    func cosineIsShared() {
        #expect(TextScriptReader.cosine([1, 0, 0], [1, 0, 0]) == 1)
        #expect(TextScriptReader.cosine([1, 0, 0], [0, 1, 0]) == 0)
        // Length must not change it: chunks are not the same size.
        #expect(TextScriptReader.cosine([2, 0], [8, 0]) == 1)
        #expect(TextScriptReader.cosine([], []) == 0)
    }
}
