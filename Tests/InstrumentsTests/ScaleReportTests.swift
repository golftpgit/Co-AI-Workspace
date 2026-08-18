import Testing
import Foundation
import AgentKit
@testable import Instruments

// The step between stored answers and the arithmetic. It lives in M15 rather
// than in the screen precisely so that these can exist: everything here is a
// decision about what to leave out, and a decision nothing checks is a decision
// that changes by accident.

private func likert(_ prompt: String, construct: String?, order: Int) -> Item {
    Item(prompt: Bilingual(prompt),
         kind: .likert(levels: (1...5).map { Bilingual("ระดับ \($0)") }),
         constructID: construct, order: order)
}

/// Two constructs of three Likert items each, in the order they were written.
private func instrument(extra: [Item] = []) -> (Instrument, [String], [String]) {
    var built = Instrument(projectID: ProjectID("p1"), title: Bilingual("ความพึงพอใจ"))
    let question = ResearchQuestion(text: Bilingual("อะไรทำให้พยาบาลอยู่ต่อ"))
    let workload = Construct(name: Bilingual("ภาระงาน"), definition: "งานต่อเวร",
                             researchQuestionID: question.id)
    let team = Construct(name: Bilingual("ความสัมพันธ์ในทีม"), definition: "การช่วยกัน",
                         researchQuestionID: question.id)
    built.researchQuestions = [question]
    built.constructs = [workload, team]
    let first = (0..<3).map { likert("ภาระ \($0)", construct: workload.id, order: $0) }
    let second = (0..<3).map { likert("ทีม \($0)", construct: team.id, order: 3 + $0) }
    built.items = first + second + extra
    return (built, first.map(\.id) + second.map(\.id), [workload.id, team.id])
}

/// The same 40 × 6 answers the factor tests use, as text keyed by item id.
private func answers(_ itemIDs: [String], _ rows: [[Int]]) -> [[String: String]] {
    rows.map { row in
        Dictionary(zip(itemIDs, row.map(String.init)), uniquingKeysWith: { first, _ in first })
    }
}

private let rawRows: [[Int]] = [
    [3, 3, 4, 1, 2, 2], [2, 2, 2, 3, 3, 3], [3, 3, 3, 4, 2, 4], [4, 5, 5, 3, 3, 2],
    [4, 3, 5, 3, 3, 4], [2, 3, 4, 2, 4, 4], [3, 5, 4, 5, 4, 4], [3, 3, 4, 2, 3, 2],
    [2, 1, 2, 2, 1, 2], [3, 3, 3, 3, 2, 2], [4, 3, 4, 3, 4, 3], [4, 3, 4, 1, 1, 2],
    [3, 3, 5, 4, 3, 3], [3, 3, 4, 3, 2, 3], [2, 3, 3, 2, 3, 2], [3, 4, 3, 4, 5, 4],
    [3, 2, 2, 1, 1, 2], [4, 5, 4, 4, 4, 4], [2, 1, 1, 2, 1, 2], [2, 2, 2, 3, 4, 3],
    [5, 3, 4, 2, 2, 3], [4, 4, 4, 2, 3, 3], [4, 3, 4, 3, 5, 4], [3, 3, 3, 1, 2, 2],
    [2, 1, 2, 3, 2, 4], [4, 4, 5, 4, 4, 5], [1, 1, 2, 2, 2, 3], [2, 3, 1, 4, 3, 5],
    [2, 2, 2, 3, 4, 4], [3, 3, 2, 3, 4, 3], [3, 3, 3, 2, 2, 2], [2, 2, 3, 3, 2, 3],
    [2, 1, 2, 4, 3, 4], [4, 4, 5, 3, 2, 3], [2, 3, 3, 3, 3, 3], [4, 3, 3, 4, 4, 4],
    [3, 3, 3, 4, 4, 3], [3, 2, 3, 4, 3, 3], [5, 5, 5, 3, 4, 3], [3, 3, 3, 3, 4, 4],
]

@Suite("scoring answers")
struct ScoringTests {

    @Test("Likert and number items become the matrix, in the instrument's order")
    func scores() {
        let (built, items, _) = instrument()
        let scored = ScoredResponses.score(instrument: built,
                                           answers: answers(items, rawRows))
        #expect(scored.itemIDs == items)
        #expect(scored.matrix.count == 40)
        #expect(scored.matrix[0] == [3, 3, 4, 1, 2, 2])
        #expect(scored.droppedRespondents == 0)
        #expect(scored.skippedItems.isEmpty)
    }

    @Test("an item whose options have no order is left out, and says why")
    func unorderedOptions() {
        let choice = Item(prompt: Bilingual("สังกัด"),
                          kind: .single(options: [Bilingual("รัฐ"), Bilingual("เอกชน")]),
                          constructID: nil, isDemographic: false, order: 9)
        let (built, items, _) = instrument(extra: [choice])
        var rows = answers(items, rawRows)
        for index in rows.indices { rows[index][choice.id] = "รัฐ" }

        let scored = ScoredResponses.score(instrument: built, answers: rows)
        #expect(!scored.itemIDs.contains(choice.id))
        #expect(scored.skippedItems.map(\.itemID) == [choice.id])
        #expect(scored.skippedItems[0].reason.contains("no order of their own"))
        // Left out, not counted as a missing answer: the respondent answered it.
        #expect(scored.droppedRespondents == 0)
    }

    @Test("a demographic item is out of the factor solution without being reported as broken")
    func demographic() {
        let age = Item(prompt: Bilingual("อายุ"), kind: .number(minimum: 18, maximum: 80),
                       constructID: nil, isDemographic: true, order: 9)
        let (built, items, _) = instrument(extra: [age])
        var rows = answers(items, rawRows)
        for index in rows.indices { rows[index][age.id] = "35" }

        let scored = ScoredResponses.score(instrument: built, answers: rows)
        #expect(!scored.itemIDs.contains(age.id))
        // It is not a *problem* — it is a question about who somebody is.
        #expect(scored.skippedItems.isEmpty)
    }

    @Test("a respondent who left a scored item blank is excluded, and counted")
    func listwise() {
        let (built, items, _) = instrument()
        var rows = answers(items, rawRows)
        rows[0][items[2]] = nil
        rows[7][items[5]] = ""

        let scored = ScoredResponses.score(instrument: built, answers: rows)
        #expect(scored.matrix.count == 38)
        #expect(scored.droppedRespondents == 2)
    }

    @Test("an instrument with nothing scorable produces no matrix rather than an empty one")
    func nothingScorable() {
        var built = Instrument(projectID: ProjectID("p1"), title: Bilingual("สัมภาษณ์"))
        built.items = [Item(prompt: Bilingual("เล่าให้ฟังหน่อย"),
                            kind: .openText(maximumLength: 500),
                            isDemographic: true, order: 0)]
        let scored = ScoredResponses.score(instrument: built,
                                           answers: [["x": "ยาว"], ["x": "ยาวอีก"]])
        #expect(scored.itemIDs.isEmpty)
        #expect(scored.matrix.isEmpty)
        #expect(scored.droppedRespondents == 2)
    }
}

@Suite("the reliability and validity report")
struct ScaleReportTests {

    @Test("α and ω come out per declared construct, not over the whole instrument")
    func perSubscale() {
        let (built, items, constructs) = instrument()
        let scored = ScoredResponses.score(instrument: built,
                                           answers: answers(items, rawRows))
        let report = ScaleReport.of(instrument: built, scored: scored,
                                    rule: .parallelAnalysis)

        #expect(report.subscales.count == 2)
        #expect(report.subscales.map(\.constructID).sorted() == constructs.sorted())
        for subscale in report.subscales {
            #expect(subscale.itemIDs.count == 3)
            #expect(subscale.alpha != nil)
            #expect(subscale.omega != nil)
        }
        // The planted structure is strong, so both coefficients clear .70 — and
        // ω is the one that used to be impossible without factor loadings.
        #expect(report.subscales.allSatisfy { $0.alpha?.passes == true })
        #expect(report.subscales.allSatisfy { $0.omega?.passes == true })
    }

    @Test("the factor solution and the declared constructs are compared, not left side by side")
    func fitIsComputed() throws {
        let (built, items, _) = instrument()
        let scored = ScoredResponses.score(instrument: built,
                                           answers: answers(items, rawRows))
        let report = ScaleReport.of(instrument: built, scored: scored,
                                    rule: .parallelAnalysis)

        let solution = try #require(report.solution)
        #expect(solution.retained == 2)
        let fit = try #require(report.fit)
        #expect(fit.constructs.count == 2)
        #expect(fit.misplaced.isEmpty)
        #expect(fit.mergedConstructs.isEmpty)
        #expect(report.refusal == nil)
    }

    @Test("too little data leaves a refusal in words, and the α it could still compute")
    func refusalKeepsWhatItCan() {
        let (built, items, _) = instrument()
        // Five respondents: α survives (it needs three), EFA does not (it needs
        // more people than items).
        let scored = ScoredResponses.score(instrument: built,
                                           answers: answers(items, Array(rawRows[0..<5])))
        let report = ScaleReport.of(instrument: built, scored: scored, rule: .kaiser)

        #expect(report.solution == nil)
        #expect(report.fit == nil)
        #expect(report.refusal?.contains("respondents") == true)
        #expect(report.subscales.count == 2)
        #expect(report.subscales.contains { $0.alpha != nil })
        #expect(report.hasAnything)
    }

    @Test("a construct whose items are all unscorable gets no row rather than a zero")
    func noRowForUnscorableConstruct() {
        var built = Instrument(projectID: ProjectID("p1"), title: Bilingual("ผสม"))
        let question = ResearchQuestion(text: Bilingual("ทำไม"))
        let spoken = Construct(name: Bilingual("เสียงจากหน้างาน"), definition: "คำบอกเล่า",
                               researchQuestionID: question.id)
        built.researchQuestions = [question]
        built.constructs = [spoken]
        built.items = [Item(prompt: Bilingual("เล่าเหตุการณ์"),
                            kind: .openText(maximumLength: 500),
                            constructID: spoken.id, order: 0)]
        let scored = ScoredResponses.score(instrument: built, answers: [["a": "b"]])
        let report = ScaleReport.of(instrument: built, scored: scored, rule: .kaiser)

        #expect(report.subscales.isEmpty)
        #expect(report.skippedItems.count == 1)
        #expect(!report.hasAnything)
    }
}
