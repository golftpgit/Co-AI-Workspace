import Testing
import Foundation
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P18.4/P18.5 — the shelf, and the lines that cross it.
// ─────────────────────────────────────────────────────────────

@Suite("Library of Congress classes")
struct ClassificationTests {

    @Test("a public-health paper that uses statistics is filed under both")
    func oneDocumentSeveralClasses() {
        // §11.9's second decision: forcing a choice throws away the fact that
        // made the paper interesting.
        let result = Classifier.classify("""
            การศึกษาระบาดวิทยาเรื่องการคัดกรองเบาหวานในชุมชน วิเคราะห์ด้วยการถดถอยโลจิสติก
            และรายงานช่วงความเชื่อมั่น 95%
            """)
        let codes = Set(result.subjects.map(\.code))
        #expect(codes.contains("RA"))
        #expect(codes.contains("HA"))
        #expect(result.assignedBy == .system)
    }

    /// §11.9's fourth decision, and the one that keeps the scheme meaningful.
    @Test("a document nothing matches is unclassified, not swept into A")
    func unclassifiedIsAnAnswer() {
        let result = Classifier.classify("บันทึกการประชุมประจำสัปดาห์ วาระที่หนึ่ง")
        #expect(result.isClassified == false)
        #expect(result.subjects.isEmpty)
        // Sweeping it into "general works" would look tidy and empty the whole
        // scheme of meaning.
        #expect(result.subjects.contains { $0.class == .a } == false)
        #expect(result.reason.contains("no word in it said clearly enough"))
    }

    @Test("a guess says which words made it, so a person has something to disagree with")
    func guessesExplainThemselves() {
        let result = Classifier.classify("แนวทางการพยาบาลผู้ป่วยเวรดึก")
        #expect(result.subjects.first?.code == "RT")
        #expect(result.assignedBy == .system)
        // A matched word is an argument. A score is not.
        #expect(result.reason.contains("พยาบาล"))
    }

    @Test("what a person decided is marked as theirs")
    func userAssignmentsAreMarked() {
        let mine = Classifier.assign([LCSubject(.r, "T"), LCSubject(.l, "B")])
        #expect(mine.assignedBy == .user)
        #expect(mine.reason.isEmpty, "a person does not owe the machine an explanation")
        #expect(mine.subjects.map(\.code) == ["RT", "LB"])
    }

    @Test("a code is read down to the subclass and no further")
    func codesStopAtSubclass() {
        // `RA1234` is a shelf position, and shelf positions mean nothing here.
        #expect(LCSubject(code: "RA1234")?.code == "RA")
        #expect(LCSubject(code: "ra")?.code == "RA")
        #expect(LCSubject(code: "R")?.code == "R")
        #expect(LCSubject(code: "R")?.subclass == nil)
        // I, O, W, X and Y are unassigned in LC itself.
        #expect(LCSubject(code: "W") == nil)
        #expect(LCSubject(code: "123") == nil)
    }

    @Test("the shelf breakdown counts unclassified documents rather than hiding them")
    func breakdownIncludesTheUnclassified() {
        let shelf = [
            Classifier.classify("ระบาดวิทยาและการคัดกรอง"),
            Classifier.classify("การพยาบาลผู้ป่วยหนัก"),
            Classifier.classify("รายงานการประชุม"),
        ]
        let (byCode, unclassified) = Classifier.breakdown(shelf)
        #expect(unclassified == 1)
        #expect(byCode.contains { $0.code == "RA" })
        #expect(byCode.contains { $0.code == "RT" })
        // Leaving the third out would make the proportions add up while
        // describing a smaller library than the one that exists.
        #expect(byCode.reduce(0) { $0 + $1.count } + unclassified >= shelf.count)
    }

    /// P18.5 — the reason the graph is still worth opening after everything is
    /// classified: the interesting line in interdisciplinary work goes from
    /// `RA` to `QA`, not between two `RA` nodes.
    @Test("an edge between two classes is told apart from one inside a class")
    func crossClassEdgesAreIdentifiable() {
        let publicHealth = Classifier.classify("ระบาดวิทยาการคัดกรองในชุมชน")
        let statistics = Classifier.classify("อัลกอริทึมและการเรียนรู้ของเครื่อง")
        let nursing = Classifier.classify("การพยาบาลผู้ป่วยเวรดึก")

        #expect(Classifier.crossesClasses(publicHealth, statistics))
        // Both R: same class, different subclass — not a crossing.
        #expect(Classifier.crossesClasses(publicHealth, nursing) == false)
        // An unclassified end cannot be said to cross anything, and guessing
        // that it does would highlight exactly the edges nobody has placed.
        #expect(Classifier.crossesClasses(publicHealth, .unclassified) == false)
    }
}
