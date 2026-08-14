import Testing
import Foundation
import AgentKit
@testable import DocGen

// P11.9's Done-when: a five-chapter document Word can open, whose chapter-4
// statistics point back to a cell that actually ran.
//
// The first half is P7.7's renderer and is checked at the end. Everything before
// that is the second half, which is really a set of refusals — the ways a number
// gets into a thesis without being true. Each one has a test because each one is
// a real thing that happens to real theses, and none of them looks wrong on the
// page afterwards.

private let meanAge = ResultReference(notebookID: "nb_1", cellID: "c1",
                                      column: "mean_age", label: "อายุเฉลี่ย")
private let sdAge = ResultReference(notebookID: "nb_1", cellID: "c1",
                                    column: "sd_age", label: "ส่วนเบี่ยงเบน")

private let statement = "SELECT avg(age) AS mean_age, stddev(age) AS sd_age FROM respondents"

private func run(source: String = statement,
                 rows: [[String?]] = [["34.7", "8.2"]],
                 at date: Date = Date(timeIntervalSince1970: 1_770_000_000)) -> CellRun {
    CellRun(notebookID: "nb_1", cellID: "c1", source: source,
            columns: ["mean_age", "sd_age"], rows: rows, ranAt: date)
}

private func manuscript() -> Manuscript {
    Manuscript(title: "ปัจจัยที่สัมพันธ์กับการคงอยู่ของพยาบาล",
               authors: ["ภาณุพงศ์ ต."],
               sections: [
                .introduction: [ManuscriptSection(heading: "ความเป็นมา",
                                                  prose: ["โรงพยาบาลรัฐมีอัตราการลาออกสูง"])],
                .results: [ManuscriptSection(
                    heading: "ข้อมูลทั่วไปของผู้ตอบ",
                    prose: ["ผู้ตอบทั้งหมดเป็นพยาบาลวิชาชีพ"],
                    reported: [ReportedSentence("อายุเฉลี่ยของผู้ตอบเท่ากับ {อายุเฉลี่ย} ปี "
                                                + "(SD = {ส่วนเบี่ยงเบน})",
                                                references: [meanAge, sdAge])])],
               ])
}

@Suite("numbers that must come from a run")
struct ResultBindingTests {

    @Test("a number resolves out of the run, carrying when it ran and what produced it")
    func bindsToARun() throws {
        let bound = try BoundResult.bind(meanAge, to: [run()]).get()
        #expect(bound.value == "34.7")
        #expect(bound.source == statement)
        #expect(bound.ranAt == Date(timeIntervalSince1970: 1_770_000_000))
    }

    @Test("a cell that never ran does not resolve")
    func cellNeverRan() {
        guard case .failure(let failure) = BoundResult.bind(meanAge, to: []) else {
            Issue.record("a reference with no run must not resolve")
            return
        }
        #expect(failure == .cellNeverRan(meanAge))
        #expect(failure.text.contains("ยังไม่เคยรัน"))
    }

    @Test("a run whose statement has since been edited does not resolve")
    func sourceChanged() {
        // The commonest way a thesis stops being true: the number was produced,
        // the query was then changed, and the draft still says what it said.
        let edited = "SELECT avg(age) AS mean_age, stddev(age) AS sd_age FROM respondents WHERE age > 20"
        guard case .failure(let failure) = BoundResult.bind(
            meanAge, to: [run()], currentSources: ["c1": edited]) else {
            Issue.record("a stale run must not resolve")
            return
        }
        #expect(failure.text.contains("ถูกแก้หลังจากนั้น"))
        // And it resolves again once the run matches what the cell now holds.
        let rerun = run(source: edited, rows: [["35.1", "7.9"]])
        let rebound = try? BoundResult.bind(meanAge, to: [rerun],
                                            currentSources: ["c1": edited]).get()
        #expect(rebound?.value == "35.1")
    }

    @Test("a column that is not in the answer names what is")
    func noSuchColumn() {
        let median = ResultReference(notebookID: "nb_1", cellID: "c1",
                                     column: "median_age", label: "มัธยฐาน")
        guard case .failure(let failure) = BoundResult.bind(median, to: [run()]) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.text.contains("mean_age"))
        #expect(failure.text.contains("sd_age"))
    }

    @Test("a row past the end of the answer, and a NULL, are both refused")
    func rowAndNull() {
        let second = ResultReference(notebookID: "nb_1", cellID: "c1",
                                     column: "mean_age", row: 1, label: "กลุ่มที่สอง")
        guard case .failure(let missingRow) = BoundResult.bind(second, to: [run()]) else {
            Issue.record("expected a failure")
            return
        }
        #expect(missingRow.text.contains("มี 1 แถว"))

        guard case .failure(let null) = BoundResult.bind(
            meanAge, to: [run(rows: [[nil, "8.2"]])]) else {
            Issue.record("expected a failure")
            return
        }
        #expect(null.text.contains("NULL"))
    }

    @Test("BoundResult has one producer and no public initialiser")
    func boundResultIsUnforgeable() throws {
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/DocGenTests/ManuscriptTests.swift",
                                  with: "Sources/DocGen/Manuscript.swift"),
                                encoding: .utf8)
        let block = source[source.range(of: "public struct BoundResult")!.lowerBound...]
        let declaration = block[..<block.range(of: "/// A sentence whose numbers")!.lowerBound]
        #expect(declaration.contains("fileprivate init("))
        #expect(!declaration.contains("public init("))
        #expect(source.components(separatedBy: "BoundResult(reference:").count - 1 == 1)
    }
}

@Suite("the five-chapter manuscript")
struct ManuscriptBuilderTests {

    @Test("a manuscript with every number bound renders, and the numbers are in the sentence")
    func rendersWithNumbers() throws {
        let draft = try ManuscriptBuilder.draft(manuscript(), runs: [run()],
                                                currentSources: ["c1": statement])
        let rendered = try DocumentBuilder.render(draft)
        let text = rendered.plainText
        #expect(text.contains("อายุเฉลี่ยของผู้ตอบเท่ากับ 34.7 ปี (SD = 8.2)"))
        // No placeholder survives into the document.
        #expect(!text.contains("{"))
    }

    @Test("all five chapters are in the document, in order, even the empty ones")
    func fiveChapters() throws {
        let draft = try ManuscriptBuilder.draft(manuscript(), runs: [run()],
                                                currentSources: ["c1": statement])
        let headings = draft.sections.map(\.heading)
        for chapter in ManuscriptChapter.allCases {
            #expect(headings.contains(chapter.title), "missing \(chapter.title)")
        }
        // Order matters: a manuscript whose chapter 4 comes before chapter 3 is
        // not a manuscript with a formatting problem.
        let positions = ManuscriptChapter.allCases.compactMap { headings.firstIndex(of: $0.title) }
        #expect(positions == positions.sorted())
        #expect(ManuscriptChapter.allCases.count == 5)
    }

    @Test("a manuscript with an unbound number is refused, not rendered with a hole")
    func refusesUnbound() {
        // The refusal is the feature. A document that renders with a gap where a
        // mean should be is a document somebody sends anyway.
        #expect(throws: ManuscriptError.self) {
            try ManuscriptBuilder.draft(manuscript(), runs: [])
        }
        do {
            _ = try ManuscriptBuilder.draft(manuscript(), runs: [])
            Issue.record("expected a refusal")
        } catch let error as ManuscriptError {
            #expect(error.description.contains("อายุเฉลี่ย"))
            #expect(error.description.contains("ส่วนเบี่ยงเบน"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("a placeholder with no reference behind it is refused before it reaches the page")
    func refusesUnfilledPlaceholder() {
        var draft = manuscript()
        draft.sections[.results] = [ManuscriptSection(
            heading: "ผล",
            reported: [ReportedSentence("ค่าเฉลี่ย {อายุเฉลี่ย} และมัธยฐาน {มัธยฐาน}",
                                        references: [meanAge])])]
        do {
            _ = try ManuscriptBuilder.draft(draft, runs: [run()],
                                            currentSources: ["c1": statement])
            Issue.record("expected a refusal")
        } catch let error as ManuscriptError {
            #expect(error.description.contains("{มัธยฐาน}"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("where every number came from is printable beside the figures")
    func provenanceTable() {
        let table = ManuscriptBuilder.provenanceTable(manuscript(), runs: [run()],
                                                      currentSources: ["c1": statement])
        #expect(table.count == 2)
        #expect(table[0].contains("อายุเฉลี่ย = 34.7"))
        #expect(table[0].contains("SELECT avg(age)"))
    }

    @Test("the document Word opens is a real .docx package")
    func opensInWord() throws {
        let draft = try ManuscriptBuilder.draft(manuscript(), runs: [run()],
                                                currentSources: ["c1": statement])
        let data = OfficeWriter.docx(try DocumentBuilder.render(draft))
        // PK zip magic, and the parts Word refuses to open without.
        #expect(data.prefix(2) == Data([0x50, 0x4B]))
        let package = String(decoding: data, as: UTF8.self)
        #expect(package.contains("word/document.xml"))
        #expect(package.contains("[Content_Types].xml"))
        #expect(data.count > 1_000)
    }
}
