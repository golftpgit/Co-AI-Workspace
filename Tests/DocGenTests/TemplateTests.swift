import Testing
import Foundation
import AgentKit
import Knowledge
@testable import DocGen

// ─────────────────────────────────────────────────────────────
// Templates learned from a document somebody already has
// (ARCHITECTURE §14.1, P7.9).
//
// The Done-when is "ใช้ template ที่ parse มาสร้างเอกสารได้", so the first
// test goes the whole way round: a real `.docx` in, a template out, a
// different draft poured into it, a real `.docx` back out, and the headings
// read out of that file by `textutil` — Apple's reader, not ours.
//
// The rest are about the two things that decide whether this is usable on
// documents people actually have. One: a heading is written three different
// ways and only one of them is the tidy one. Two: what happens to content the
// template has no place for, which must never be quietly deleted.
// ─────────────────────────────────────────────────────────────

private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "coai-template-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A `.docx` containing exactly the given `word/document.xml`. Used to build
/// the shapes our own writer never produces — which is the point: a parser
/// tested only against documents we wrote is a parser tested against itself.
private func docx(withBody body: String, at url: URL) throws {
    var archive = ZipArchive()
    archive.add("[Content_Types].xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" \
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """)
    archive.add("_rels/.rels", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" \
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
    Target="word/document.xml"/>
    </Relationships>
    """)
    archive.add("word/document.xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:body>\(body)</w:body></w:document>
    """)
    try archive.build().write(to: url)
}

private func styled(_ style: String, _ text: String) -> String {
    "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
}

private func bold(_ text: String) -> String {
    "<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>\(text)</w:t></w:r></w:p>"
}

private func plain(_ text: String) -> String {
    "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>"
}

/// The sample document a person would upload: last year's proposal.
private func sampleProposal() -> DocumentDraft {
    DocumentDraft(
        title: "โครงร่างวิจัย เรื่อง ผลของการให้ความรู้ต่อการควบคุมน้ำตาล",
        authors: ["ผู้วิจัยเดิม"],
        sections: [
            Section(heading: "ความเป็นมา", paragraphs: [
                .plain("โรคเบาหวานเป็นปัญหาสาธารณสุขที่สำคัญของอำเภอนี้มาต่อเนื่องหลายปี"),
            ]),
            Section(heading: "วัตถุประสงค์", paragraphs: [
                .bullets(["เพื่อศึกษาผลของโปรแกรม", "เพื่อเปรียบเทียบก่อนและหลัง"]),
            ]),
            Section(heading: "ระเบียบวิธีวิจัย", paragraphs: [
                .plain("การศึกษาแบบกึ่งทดลอง เก็บข้อมูลที่โรงพยาบาลส่งเสริมสุขภาพตำบล"),
            ]),
            Section(heading: "ประโยชน์ที่คาดว่าจะได้รับ", paragraphs: [
                .plain("ได้แนวทางที่นำไปใช้ต่อในพื้นที่อื่น"),
            ]),
        ])
}

@Suite("Templates", .serialized)
struct TemplateTests {

    /// **The Done-when.** A file in, a different document out, in that file's
    /// shape — checked by reading the result with Apple's reader rather than
    /// by inspecting our own structures.
    @Test("a template parsed from a .docx produces a new document in that shape")
    func roundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = directory.appending(path: "โครงร่างปีที่แล้ว.docx")
        try OfficeWriter.docx(try DocumentBuilder.render(sampleProposal())).write(to: sample)

        let template = try TemplateParser.parse(docx: sample)
        #expect(template.headings == ["ความเป็นมา", "วัตถุประสงค์",
                                      "ระเบียบวิธีวิจัย", "ประโยชน์ที่คาดว่าจะได้รับ"])
        #expect(template.titleExample?.contains("โครงร่างวิจัย") == true)
        #expect(template.source == "โครงร่างปีที่แล้ว.docx")
        // The sample used a list under วัตถุประสงค์ and prose elsewhere.
        #expect(template.sections[1].expectsBullets)
        #expect(template.sections[0].expectsBullets == false)

        // A different study, written in a different order, with one section
        // the template does not know about.
        let thisYear = DocumentDraft(
            title: "ผลของเมตฟอร์มินต่อระดับ HbA1c",
            sections: [
                Section(heading: "วิธีการ", paragraphs: [.plain("เก็บข้อมูลย้อนหลัง")]),
                Section(heading: "ความเป็นมา", paragraphs: [.plain("ผู้ป่วยเบาหวานในคลินิก")]),
                Section(heading: "ข้อพิจารณาด้านจริยธรรม",
                        paragraphs: [.plain("ผ่านการรับรองจากคณะกรรมการ")]),
            ])

        let applied = TemplateFiller.apply(template, to: thisYear)
        let file = directory.appending(path: "ปีนี้.docx")
        try OfficeWriter.docx(try DocumentBuilder.render(applied.draft)).write(to: file)

        let text = run("/usr/bin/textutil",
                       ["-convert", "txt", "-stdout", file.path(percentEncoded: false)]).output
        // Every heading the template asked for is in the finished file, in the
        // template's order.
        var cursor = text.startIndex
        for heading in template.headings {
            let found = try #require(text.range(of: heading, range: cursor..<text.endIndex),
                                     "ไม่พบหัวข้อ '\(heading)' ตามลำดับของแม่แบบ")
            cursor = found.upperBound
        }
        // And the section the template had no place for survived.
        #expect(text.contains("ข้อพิจารณาด้านจริยธรรม"))
        #expect(text.contains("ผ่านการรับรองจากคณะกรรมการ"))
    }

    /// The rule that keeps this from being dangerous. A template is a shape
    /// somebody chose; it is not permission to delete the parts of their work
    /// that did not fit it.
    @Test("content the template has no section for is kept, not dropped")
    func extraContentSurvives() {
        let template = DocumentTemplate(name: "สั้น", sections: [
            TemplateSection(heading: "บทนำ"),
        ])
        let draft = DocumentDraft(title: "ร่าง", sections: [
            Section(heading: "บทนำ", paragraphs: [.plain("ก")]),
            Section(heading: "ผลการศึกษา", paragraphs: [.plain("ข")]),
            Section(heading: "อภิปราย", paragraphs: [.plain("ค")]),
        ])

        let applied = TemplateFiller.apply(template, to: draft)
        #expect(applied.draft.sections.map(\.heading) == ["บทนำ", "ผลการศึกษา", "อภิปราย"])
        #expect(applied.extra == ["ผลการศึกษา", "อภิปราย"])
        #expect(applied.filled == ["บทนำ"])
    }

    /// A heading the document does not have is a to-do, and it has to be
    /// visible as one. An empty heading reads as an oversight.
    @Test("a required section with nothing to put in it is reported and marked")
    func missingSectionsAreMarked() {
        let template = DocumentTemplate(name: "เต็ม", sections: [
            TemplateSection(heading: "บทนำ"),
            TemplateSection(heading: "ระเบียบวิธี"),
            TemplateSection(heading: "ภาคผนวก", isRequired: false),
        ])
        let applied = TemplateFiller.apply(
            template,
            to: DocumentDraft(title: "ร่าง",
                              sections: [Section(heading: "บทนำ", paragraphs: [.plain("ก")])]))

        #expect(applied.missing == ["ระเบียบวิธี", "ภาคผนวก"])
        #expect(!applied.isComplete)
        // Required and empty: in the document, with a line that says so.
        #expect(applied.draft.sections.map(\.heading) == ["บทนำ", "ระเบียบวิธี"])
        #expect(applied.draft.sections[1].paragraphs == [.plain(TemplateFiller.emptyMarker)])
    }

    @Test("headings match across numbering, case and spacing")
    func headingMatching() {
        #expect(TemplateFiller.matches("2. วิธีการ", "วิธีการ"))
        #expect(TemplateFiller.matches("บทที่ 1 บทนำ", "บทนำ"))
        #expect(TemplateFiller.matches("METHODS", "Methods"))
        #expect(TemplateFiller.matches("ผล การ ศึกษา", "ผลการศึกษา"))
        #expect(!TemplateFiller.matches("บทนำ", "บทสรุป"))
    }

    /// Rule 3 of the reader, and the one that decides whether this works on
    /// real files: most documents people have were typed, not styled.
    @Test("a document with no heading styles still yields its bold one-liners")
    func boldHeadingsAreFound() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "typed.docx")
        try docx(withBody: bold("บทนำ")
                 + plain("เนื้อหาของบทนำอยู่ตรงนี้")
                 + bold("วิธีการศึกษา")
                 + plain("เก็บข้อมูลย้อนหลัง"),
                 at: file)

        let template = try TemplateParser.parse(docx: file, name: "พิมพ์เอง")
        #expect(template.headings == ["บทนำ", "วิธีการศึกษา"])
        #expect(template.sections[0].guidance == "เนื้อหาของบทนำอยู่ตรงนี้")
    }

    /// A `.docx` written by somebody else's writer, which is the case the
    /// fixtures above cannot cover.
    ///
    /// `textutil` is Apple's, it is on every Mac, and what it produces is
    /// instructive: converting HTML with `<h1>` headings, it emits **no
    /// `w:pStyle` and no `w:outlineLvl` at all** — every heading is just a
    /// bold run at a larger size. A parser that handled only Word's tidy
    /// markup would find nothing in a file macOS itself wrote, which is the
    /// clearest argument there is for rule 3.
    @Test("a Word file written by macOS itself, with no styles anywhere, still parses")
    func parsesAForeignWordFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = directory.appending(path: "sample.html")
        try """
        <html><body>
        <h1>บทนำ</h1><p>ที่มาของการศึกษา</p>
        <h1>วิธีการ</h1><p>เก็บข้อมูลย้อนหลัง</p>
        <h1>ผลการศึกษา</h1><p>พบความแตกต่างอย่างมีนัยสำคัญ</p>
        </body></html>
        """.write(to: html, atomically: true, encoding: .utf8)

        let file = directory.appending(path: "apple.docx")
        let converted = run("/usr/bin/textutil",
                            ["-convert", "docx", "-inputencoding", "UTF-8",
                             "-output", file.path(percentEncoded: false),
                             html.path(percentEncoded: false)])
        try #require(converted.status == 0, "textutil: \(converted.output)")

        let template = try TemplateParser.parse(docx: file, name: "จากไฟล์จริง")
        #expect(template.headings == ["บทนำ", "วิธีการ", "ผลการศึกษา"])
        #expect(template.sections[2].guidance == "พบความแตกต่างอย่างมีนัยสำคัญ")
    }

    /// The other half of rule 3: a document that *does* use styles must not
    /// have its emphasised sentences promoted into sections.
    @Test("bold sentences are not headings in a document that has real ones")
    func boldIsNotPromotedWhenStylesExist() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "styled.docx")
        try docx(withBody: styled("Heading1", "บทนำ")
                 + bold("ข้อความเน้นที่ไม่ใช่หัวข้อ")
                 + plain("เนื้อหา")
                 + styled("Heading1", "วิธีการ")
                 + plain("เนื้อหา"),
                 at: file)

        let template = try TemplateParser.parse(docx: file)
        #expect(template.headings == ["บทนำ", "วิธีการ"])
    }

    /// What Word writes when somebody uses "add to table of contents" without
    /// applying a style.
    @Test("outline levels count as headings")
    func outlineLevelsAreHeadings() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "outline.docx")
        try docx(withBody: "<w:p><w:pPr><w:outlineLvl w:val=\"0\"/></w:pPr>"
                 + "<w:r><w:t>ผลการศึกษา</w:t></w:r></w:p>" + plain("ตารางที่ 1"),
                 at: file)

        #expect(try TemplateParser.parse(docx: file).headings == ["ผลการศึกษา"])
    }

    /// A document with nothing that looks like a heading cannot be a template,
    /// and the message has to say what would make it one.
    @Test("a document with no headings is refused, with a reason to act on")
    func noHeadingsIsRefused() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "flat.docx")
        try docx(withBody: plain("ย่อหน้าเดียว ไม่มีหัวข้อ") + plain("อีกย่อหน้า"), at: file)

        #expect(throws: TemplateError.self) { try TemplateParser.parse(docx: file) }
        #expect(TemplateError.noHeadings("flat.docx").description.contains("Heading"))
    }

    /// A template is a shape, not text to reuse. The sample's sentences are
    /// somebody's actual writing about an actual study.
    @Test("the sample's own words are guidance and never reach the new document")
    func guidanceIsNotContent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = directory.appending(path: "sample.docx")
        try OfficeWriter.docx(try DocumentBuilder.render(sampleProposal())).write(to: sample)

        let template = try TemplateParser.parse(docx: sample)
        let guidance = try #require(template.sections.first?.guidance)
        #expect(guidance.contains("โรคเบาหวานเป็นปัญหาสาธารณสุข"))

        let applied = TemplateFiller.apply(
            template,
            to: DocumentDraft(title: "ใหม่",
                              sections: [Section(heading: "ความเป็นมา",
                                                 paragraphs: [.plain("เนื้อหาใหม่")])]))
        let rendered = try DocumentBuilder.render(applied.draft)
        #expect(!rendered.plainText.contains("โรคเบาหวานเป็นปัญหาสาธารณสุข"))
        #expect(rendered.plainText.contains("เนื้อหาใหม่"))
    }

    @Test("templates survive being written to disk and read back")
    func storeRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TemplateStore(file: directory.appending(path: "templates.json"))
        #expect(store.load().isEmpty)

        let template = DocumentTemplate(name: "โครงร่างวิจัย",
                                        titleExample: "โครงร่างวิจัย เรื่อง …",
                                        sections: [TemplateSection(heading: "บทนำ",
                                                                   guidance: "ที่มา")],
                                        source: "เดิม.docx")
        try store.add(template)
        #expect(store.load() == [template])

        try store.remove(template.id)
        #expect(store.load().isEmpty)
    }
}
