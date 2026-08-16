import Testing
import Foundation
import AgentKit
import Instruments
import OLTP
@testable import FieldServer

// ─────────────────────────────────────────────────────────────
// P11.6 / P11.7 — two question types the model has had since it was written
// and the web form could not draw, so an instrument using them was publishable
// and unanswerable.
//
// Both are several questions wearing one prompt, which is where the rules come
// from: a grid answered for some rows and not others is not a partial answer
// to tidy up, and a ranking with two things in third place is a different
// claim about preference rather than a nearly-right one.
// ─────────────────────────────────────────────────────────────

private let rows = [Bilingual("ก่อนผ่าตัด"), Bilingual("ระหว่างพัก"), Bilingual("ก่อนกลับบ้าน")]
private let columns = [Bilingual("ไม่เคย"), Bilingual("บางครั้ง"), Bilingual("บ่อย")]
private let options = [Bilingual("ความปวด"), Bilingual("การนอน"), Bilingual("ค่าใช้จ่าย")]

private func item(_ kind: ItemKind, required: Bool = true) -> Item {
    Item(id: "q1", prompt: Bilingual("คำถาม"), kind: kind, required: required,
         constructID: "c1", order: 1)
}

@Suite("Grids and rankings on the web form (P11.6/P11.7)")
struct MatrixRankingTests {

    // MARK: - matrix

    @Test("each row of a grid becomes its own answer")
    func matrixRowsAreSeparateAnswers() throws {
        let grid = item(.matrix(rows: rows, columns: columns))
        let answers = try SubmissionValidator.matrixAnswers(
            grid, rows: rows, parts: [0: "0", 1: "2", 2: "1"])

        #expect(answers.count == 3)
        // A matrix is several questions wearing one prompt; an analysis that
        // cannot tell the rows apart has one variable where it needs three.
        #expect(answers.map(\.itemID) == ["q1#0", "q1#1", "q1#2"])
        #expect(answers[1].text == "บ่อย")
        #expect(answers[1].number == 2)
    }

    /// A half-filled grid analysed as though the blanks meant "no" is the
    /// quiet version of making data up.
    @Test("a required grid missing rows says which rows")
    func partialGridNamesTheRows() {
        let grid = item(.matrix(rows: rows, columns: columns))
        #expect(throws: SubmissionProblem.matrixIncomplete(prompt: "คำถาม",
                                                           rows: ["ระหว่างพัก"])) {
            _ = try SubmissionValidator.matrixAnswers(grid, rows: rows,
                                                      parts: [0: "0", 2: "1"])
        }
    }

    @Test("an optional grid keeps the rows that were answered")
    func optionalGridKeepsWhatCame() throws {
        let grid = item(.matrix(rows: rows, columns: columns), required: false)
        let answers = try SubmissionValidator.matrixAnswers(grid, rows: rows, parts: [1: "0"])
        #expect(answers.map(\.itemID) == ["q1#1"])
    }

    @Test("a column that does not exist is refused")
    func inventedColumnIsRefused() {
        let grid = item(.matrix(rows: rows, columns: columns))
        #expect(throws: SubmissionProblem.notAnOption(prompt: "คำถาม")) {
            _ = try SubmissionValidator.matrixAnswers(grid, rows: rows,
                                                      parts: [0: "0", 1: "9", 2: "1"])
        }
    }

    // MARK: - ranking

    @Test("a ranking is stored as a place per option")
    func rankingStoresPlaces() throws {
        let ranking = item(.ranking(options: options))
        let answers = try SubmissionValidator.rankingAnswers(
            ranking, options: options, parts: [0: "2", 1: "1", 2: "3"])

        #expect(answers.count == 3)
        #expect(answers[0].number == 2)
        #expect(answers[1].text == "การนอน")
        #expect(answers[1].number == 1)
    }

    /// Two things in third place is a different claim, not a nearly-right one.
    @Test("a repeated place is refused, and named")
    func repeatedPlaceIsRefused() {
        let ranking = item(.ranking(options: options))
        do {
            _ = try SubmissionValidator.rankingAnswers(ranking, options: options,
                                                       parts: [0: "1", 1: "1", 2: "3"])
            Issue.record("a ranking with two firsts was accepted")
        } catch let problem as SubmissionProblem {
            #expect("\(problem)".contains("1"))
            #expect("\(problem)".contains("ซ้ำ"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a gap in the places is refused")
    func gapIsRefused() {
        let ranking = item(.ranking(options: options))
        #expect(throws: SubmissionProblem.self) {
            _ = try SubmissionValidator.rankingAnswers(ranking, options: options,
                                                       parts: [0: "1", 1: "2", 2: "4"])
        }
    }

    @Test("a partly-filled ranking is refused rather than completed")
    func partialRankingIsRefused() {
        let ranking = item(.ranking(options: options))
        #expect(throws: SubmissionProblem.self) {
            _ = try SubmissionValidator.rankingAnswers(ranking, options: options,
                                                       parts: [0: "1", 1: "2"])
        }
    }

    // MARK: - the page

    @Test("the grid is drawn as a table with headers a screen reader can use")
    func gridIsATable() {
        let html = FormRuntime.itemSection(item(.matrix(rows: rows, columns: columns)),
                                           in: nil, answered: [], parts: [:])
        #expect(html.contains("<table class=\"matrix\""))
        #expect(html.contains("scope=\"row\""))
        #expect(html.contains("scope=\"col\""))
        // Every radio has its own label: the visual header is two cells away,
        // and a table header is not a label.
        #expect(html.contains("ก่อนผ่าตัด — บางครั้ง"))
        #expect(html.contains("name=\"q1#0\""))
    }

    @Test("a ranking is typed, not dragged")
    func rankingIsTyped() {
        let html = FormRuntime.itemSection(item(.ranking(options: options)),
                                           in: nil, answered: [], parts: [:])
        // Dragging is unreachable by keyboard and unusable with one thumb on a
        // ward round, which is where this form is answered.
        #expect(html.contains("draggable") == false)
        #expect(html.contains("type=\"number\""))
        #expect(html.contains("max=\"3\""))
    }

    @Test("a resumed form comes back with the grid still filled in")
    func resumeRefillsTheGrid() {
        let html = FormRuntime.itemSection(item(.matrix(rows: rows, columns: columns)),
                                           in: nil, answered: [], parts: [1: "2"])
        #expect(html.contains("name=\"q1#1\" value=\"2\" checked"))
    }

    @Test("file upload still says out loud that it cannot be drawn")
    func fileUploadStaysHonest() {
        let html = FormRuntime.itemSection(item(.fileUpload(accepts: ["pdf"])),
                                           in: nil, answered: [], parts: [:])
        #expect(html.contains("unsupported"))
        #expect(html.contains("ติดต่อผู้วิจัย"))
    }
}
