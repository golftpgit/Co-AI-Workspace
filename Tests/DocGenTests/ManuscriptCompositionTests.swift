import Testing
import Foundation
import AgentKit
@testable import DocGen

// ─────────────────────────────────────────────────────────────
// P11.9 — the half that was missing: somebody has to be able to *write* one.
//
// The binding rules already had tests. These are about the way a person makes
// a bound number in the first place, and the first test is the one the design
// exists for: the placeholder in the text and the label on the reference are
// written by the same action, so they cannot be typed differently.
// ─────────────────────────────────────────────────────────────

private func reference(_ label: String, cell: String = "c1", column: String = "mean_age",
                       row: Int = 0) -> ResultReference {
    ResultReference(notebookID: "nb1", cellID: cell, column: column, row: row, label: label)
}

private func run(cell: String = "c1", columns: [String] = ["mean_age"],
                 rows: [[String?]] = [["42.7"]], source: String = "SELECT avg(age) …",
                 at: Date = Date(timeIntervalSince1970: 1_000_000)) -> CellRun {
    CellRun(notebookID: "nb1", cellID: cell, source: source, columns: columns,
            rows: rows, ranAt: at)
}

@Suite("Composing a reported sentence")
struct SentenceComposerTests {

    // The whole reason this type exists. Two strings typed twice, that have to
    // match exactly, in a script where a trailing space is invisible.
    @Test("inserting a number writes the placeholder and the reference in one move")
    func insertWritesBoth() throws {
        var composer = SentenceComposer("อายุเฉลี่ยของกลุ่มตัวอย่างเท่ากับ")
        try composer.insert(reference("ค่าเฉลี่ยอายุ"))

        #expect(composer.text.contains("{ค่าเฉลี่ยอายุ}"))
        #expect(composer.references.count == 1)
        // Nothing left to disagree about.
        #expect(composer.problems.isEmpty)
    }

    // Filling is a string replacement, so a repeated label prints the first
    // number twice and the second never.
    @Test("a duplicate label in one sentence is refused, and says what goes wrong")
    func duplicateLabelRefused() throws {
        var composer = SentenceComposer()
        try composer.insert(reference("ค่าเฉลี่ย"))

        #expect(throws: SentenceCompositionError.duplicateLabel("ค่าเฉลี่ย")) {
            try composer.insert(reference("ค่าเฉลี่ย", cell: "c2"))
        }
        #expect(composer.references.count == 1, "the refused reference was recorded anyway")
    }

    @Test("a label with a brace in it is refused — it would make an unfillable slot")
    func braceInLabelRefused() {
        var composer = SentenceComposer()
        #expect(throws: SentenceCompositionError.labelContainsBrace("ค่า{เฉลี่ย}")) {
            try composer.insert(reference("ค่า{เฉลี่ย}"))
        }
    }

    @Test("an empty label is refused rather than producing {} in the document")
    func emptyLabelRefused() {
        var composer = SentenceComposer()
        #expect(throws: SentenceCompositionError.emptyLabel) {
            try composer.insert(reference("   "))
        }
    }

    @Test("removing a number takes the placeholder out of the text too")
    func removeTakesBoth() throws {
        var composer = SentenceComposer("อายุเฉลี่ย")
        let mean = reference("ค่าเฉลี่ยอายุ")
        try composer.insert(mean)
        composer.remove(mean)

        #expect(composer.text.contains("{") == false)
        #expect(composer.references.isEmpty)
    }

    // The case the author creates by editing prose around a number.
    @Test("a reference whose placeholder was edited away is reported, not silently kept")
    func orphanIsReported() throws {
        var composer = SentenceComposer("อายุเฉลี่ย")
        try composer.insert(reference("ค่าเฉลี่ยอายุ"))
        composer.write("เขียนใหม่ทั้งประโยค โดยไม่มีช่องเติมเลขแล้ว")

        #expect(composer.problems.count == 1)
        #expect(composer.problems[0].contains("the text no longer has a slot for it"))
        // And it is not carried into the document, where it would appear in the
        // appendix as a figure the reader cannot find in the text.
        #expect(composer.sentence.references.isEmpty)
    }

    @Test("a placeholder typed by hand with nothing behind it is reported too")
    func unfilledIsReported() {
        let composer = SentenceComposer("ค่าเฉลี่ยเท่ากับ {ค่าที่ยังไม่ผูก}")
        #expect(composer.problems.count == 1)
        #expect(composer.problems[0].contains("has nothing behind it"))
    }
}

@Suite("Previewing the manuscript before it is exported")
struct ManuscriptPreviewTests {

    private func manuscript(_ sentence: ReportedSentence) -> Manuscript {
        Manuscript(scope: .project(ProjectID("pj1")), title: "การศึกษาภาวะหมดไฟ",
                   sections: [.results: [ManuscriptSection(heading: "4.1 ลักษณะของกลุ่มตัวอย่าง",
                                                           reported: [sentence])]])
    }

    @Test("the preview shows the sentence with the real number in it")
    func showsFilledText() throws {
        var composer = SentenceComposer("อายุเฉลี่ยเท่ากับ")
        try composer.insert(reference("ค่าเฉลี่ยอายุ"))

        let preview = ManuscriptPreview.of(manuscript(composer.sentence), runs: [run()])
        #expect(preview.isExportable)
        #expect(preview.filled[.results]?.first?.contains("42.7") == true)
    }

    // The point of previewing at all: "your chapter 4 will not export" is worth
    // knowing while writing, not on the afternoon it is due.
    @Test("a cell that never ran is shown as a problem before anybody presses export")
    func showsBindingFailureEarly() throws {
        var composer = SentenceComposer("อายุเฉลี่ยเท่ากับ")
        try composer.insert(reference("ค่าเฉลี่ยอายุ", cell: "never-ran"))

        let preview = ManuscriptPreview.of(manuscript(composer.sentence), runs: [run()])
        #expect(preview.isExportable == false)
        #expect(preview.failures.count == 1)
        #expect(preview.failures[0].text.contains("has never been run"))
    }

    // §20.8's central case: the number is stale because the query changed.
    @Test("a number from a run whose cell has since been edited is refused in the preview too")
    func staleNumberIsCaught() throws {
        var composer = SentenceComposer("อายุเฉลี่ยเท่ากับ")
        try composer.insert(reference("ค่าเฉลี่ยอายุ"))

        let preview = ManuscriptPreview.of(
            manuscript(composer.sentence), runs: [run()],
            currentSources: ["c1": "SELECT avg(age) FROM patients WHERE year > 2020"])

        #expect(preview.isExportable == false)
        #expect(preview.failures[0].text.contains("answers a different question"))
    }

    // The appendix must agree with the chapter about which numbers exist.
    @Test("an orphaned reference does not block the export and does not reach the appendix")
    func orphanNeitherBlocksNorPrints() throws {
        var composer = SentenceComposer("อายุเฉลี่ย")
        try composer.insert(reference("ค่าเฉลี่ยอายุ"))
        composer.write("ไม่รายงานตัวเลขนี้แล้ว")

        let document = manuscript(composer.sentence)
        #expect(document.references.isEmpty)

        let preview = ManuscriptPreview.of(document, runs: [])
        #expect(preview.isExportable, "an unquoted number blocked the whole document")
        #expect(ManuscriptBuilder.provenanceTable(document, runs: [run()]).isEmpty)
    }

    @Test("prose without numbers previews as itself")
    func proseSurvives() {
        let document = Manuscript(
            title: "บทนำ",
            sections: [.introduction: [ManuscriptSection(heading: "1.1 ความเป็นมา",
                                                         prose: ["ภาวะหมดไฟเป็นปัญหาที่พบมากขึ้น"])]])
        let preview = ManuscriptPreview.of(document, runs: [])
        #expect(preview.filled[.introduction] == ["ภาวะหมดไฟเป็นปัญหาที่พบมากขึ้น"])
        #expect(preview.isExportable)
    }
}
