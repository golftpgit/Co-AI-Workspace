import Testing
import Foundation
@testable import ScreenDriver

// ─────────────────────────────────────────────────────────────
// When one label contains another (§23.1, P17.1).
//
// Every tab in the app carries two controls whose names overlap by
// construction:
//
//     "แท็บ Burnout among ICU nurses · กดเพื่อสลับมา"
//     "ปิดแท็บ Burnout among ICU nurses — ปิดแค่หน้าต่าง ไม่ใช่ปิดโครงการ"
//
// Ask for "แท็บ Burnout among ICU nurses" and both match, because "ปิดแท็บ"
// ends in "แท็บ". The driver refused, which was the right call for what it
// knew — and it made pressing a tab by its own name impossible, and every
// well-named close button in the app poisons its own control the same way.
//
// It cost a real mistake before it was fixed: a script pressing tabs threw the
// refusals away, so five silently-skipped switches read as five successful
// ones, and the app was very nearly blamed for losing state it had never been
// asked to change (E.34).
//
// The rule that resolves it without weakening the refusal: **a match at the
// start of a label beats one buried in the middle.** A control whose name
// begins with what you asked for is the control you named; one that merely
// mentions it is a different control talking about the same thing. When two
// are equally close, it is still a tie and still refused — the point of the
// refusal is unchanged.
// ─────────────────────────────────────────────────────────────

@Suite("Choosing between labels that overlap")
struct ClosestMatchTests {

    private func screen(_ labels: [String]) -> ScreenSnapshot {
        ScreenSnapshot(
            takenAt: Date(timeIntervalSince1970: 0),
            windowTitle: "w",
            root: ScreenElement(role: "AXWindow", label: "w",
                                children: labels.map {
                                    ScreenElement(role: "AXButton", label: $0)
                                }))
    }

    @Test("the control whose name starts with the query wins over one that only mentions it")
    func prefixBeatsInfix() throws {
        let snapshot = screen([
            "แท็บ Burnout among ICU nurses · กดเพื่อสลับมา",
            "ปิดแท็บ Burnout among ICU nurses — ปิดแค่หน้าต่าง ไม่ใช่ปิดโครงการ",
        ])
        let found = try ElementFinder.find(.button("แท็บ Burnout among ICU nurses"), in: snapshot)
        #expect(found.label.hasPrefix("แท็บ Burnout"))
    }

    @Test("asking for the close button still gets the close button")
    func theOtherOneIsStillReachable() throws {
        let snapshot = screen([
            "แท็บ Burnout among ICU nurses · กดเพื่อสลับมา",
            "ปิดแท็บ Burnout among ICU nurses — ปิดแค่หน้าต่าง",
        ])
        let found = try ElementFinder.find(.button("ปิดแท็บ Burnout"), in: snapshot)
        #expect(found.label.hasPrefix("ปิดแท็บ"))
    }

    @Test("two equally close matches are still a refusal, not a guess")
    func genuineTiesAreStillRefused() {
        // Three Save buttons remain three Save buttons. Preferring a prefix
        // resolves overlap, and must not turn a real ambiguity into a coin flip.
        let snapshot = screen(["บันทึก", "บันทึก", "บันทึก"])
        #expect(throws: ScreenDriverError.self) {
            _ = try ElementFinder.find(.button("บันทึก"), in: snapshot)
        }
    }

    @Test("a tie among prefix matches is refused too")
    func tiedPrefixesAreRefused() {
        let snapshot = screen(["แท็บ ก · กดเพื่อสลับมา", "แท็บ ก · กำลังดูอยู่"])
        #expect(throws: ScreenDriverError.self) {
            _ = try ElementFinder.find(.button("แท็บ ก"), in: snapshot)
        }
    }
}
