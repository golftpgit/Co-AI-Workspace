import Testing
import Foundation
import AgentKit
import Knowledge
@testable import DocGen

// ─────────────────────────────────────────────────────────────
// Real files (ARCHITECTURE §14.1, P7.6).
//
// The Done-when is that the file opens in Word, and a test that only checks our
// own bytes against our own expectations cannot say anything about that. So
// these tests hand the generated file to two readers that are not ours:
// `/usr/bin/unzip -t`, which validates the archive and every CRC in it, and
// `/usr/bin/textutil`, which is the OOXML reader Apple ships and TextEdit uses.
// Text coming back out of textutil is the strongest evidence available without
// a person double-clicking the file.
// ─────────────────────────────────────────────────────────────

private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "coai-docgen-\(UUID().uuidString)")
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

/// Every file under an unpacked package, as package-relative part names.
private func partNames(under root: URL) -> Set<String> {
    let prefix = root.path(percentEncoded: false) + "/"
    guard let walker = FileManager.default.enumerator(atPath: root.path(percentEncoded: false))
    else { return [] }
    var names: Set<String> = []
    for case let entry as String in walker {
        let full = root.appending(path: entry).path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
              !isDirectory.boolValue else { continue }
        names.insert(String(full.dropFirst(prefix.count)))
    }
    return names
}

/// Collapses `..` in a package-relative path. `standardizingPath` will not:
/// it leaves `..` alone in a relative path, since it cannot know what the path
/// is relative to.
private func normalized(_ path: String) -> String {
    var result: [String] = []
    for component in path.split(separator: "/") {
        if component == ".." { result.removeLast() } else if component != "." {
            result.append(String(component))
        }
    }
    return result.joined(separator: "/")
}

/// The `Target` of every relationship in a `.rels` part, parsed rather than
/// matched: XMLDocument is Apple's reader, and it fails on malformed XML the
/// way a regular expression would not.
private func targets(ofRelationshipsIn file: URL) -> [String] {
    guard let document = try? XMLDocument(contentsOf: file),
          let nodes = try? document.nodes(forXPath: "//*[local-name()='Relationship']")
    else { return [] }
    return nodes.compactMap {
        guard let element = $0 as? XMLElement,
              element.attribute(forName: "TargetMode")?.stringValue != "External"
        else { return nil }
        return element.attribute(forName: "Target")?.stringValue
    }
}

private func source(_ id: String, _ title: String, tier: SourceTier = .t1,
                    authors: [String] = ["สมชาย ก."], year: Int? = 2025) -> Provenance {
    Provenance(documentID: id, title: title, origin: .upload(filename: "\(id).pdf"),
               tier: tier, authors: authors, year: year)
}

/// A draft with everything in it that a real one has: Thai text, an ampersand,
/// citations from two works, bullets, and an automatic Limitations section.
private func draft() -> DocumentDraft {
    var plan = AnalysisPlan(title: "แผน")
    plan.add(AnalysisDecision(question: "นิยามของการติดตามครบ",
                              value: "ผลเลือด ≥ 2 ครั้งใน 12 เดือน",
                              origin: .agentSuggested, note: "โครงร่างไม่ได้ระบุ"))
    return DocumentDraft(
        title: "ผลของเมตฟอร์มินต่อระดับ HbA1c",
        authors: ["ผู้วิจัย ก.", "R&D group"],
        sections: [
            Section(heading: "บทนำ", paragraphs: [
                .plain("การศึกษานี้ทบทวนหลักฐานที่มีอยู่ <ทั้งหมด> & สรุปช่องว่าง"),
                .cited([CitedText("เมตฟอร์มินลด HbA1c ได้ราว 1%",
                                  from: source("a", "การศึกษา ก")),
                        CitedText("ผลชัดเจนที่สุดในหกเดือนแรก",
                                  from: source("b", "การศึกษา ข", tier: .t2))]),
            ]),
            Section(heading: "วิธีการ", paragraphs: [
                .bullets(["เก็บข้อมูลย้อนหลัง", "วิเคราะห์ด้วย Welch t-test"]),
            ]),
        ],
        style: .apa,
        limitations: LimitationsBuilder.build(plan: plan))
}

@Suite("Office writers", .serialized)
struct OfficeWriterTests {

    /// P7.6's Done-when, checked by Apple's own reader rather than by us.
    @Test("a generated .docx is a valid archive that macOS can read the text out of")
    func docxOpens() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "report.docx")

        let rendered = try DocumentBuilder.render(draft())
        try OfficeWriter.docx(rendered).write(to: file)

        // Every entry and every CRC, checked by something that is not ours.
        let integrity = run("/usr/bin/unzip", ["-t", file.path(percentEncoded: false)])
        #expect(integrity.status == 0)
        #expect(integrity.output.contains("No errors detected"))

        // And the text comes back out through the reader TextEdit uses.
        let converted = run("/usr/bin/textutil",
                            ["-convert", "txt", "-stdout", file.path(percentEncoded: false)])
        #expect(converted.status == 0)
        #expect(converted.output.contains("ผลของเมตฟอร์มินต่อระดับ HbA1c"))
        #expect(converted.output.contains("เมตฟอร์มินลด HbA1c ได้ราว 1%"))
        // The citation markers were placed by the builder, from the provenance.
        #expect(converted.output.contains("(สมชาย ก., 2025)"))
        #expect(converted.output.contains("References"))
        // §14.1's Limitations section, in the file, without anyone asking.
        #expect(converted.output.contains("Limitations of this study"))
        #expect(converted.output.contains("นิยามของการติดตามครบ"))
        // The characters that would have broken the XML.
        #expect(converted.output.contains("<ทั้งหมด> & สรุปช่องว่าง"))
    }

    @Test("a generated .pptx is a valid archive with one slide per heading")
    func pptxIsAValidPackage() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "deck.pptx")

        let rendered = try DocumentBuilder.render(draft())
        try OfficeWriter.pptx(rendered).write(to: file)

        let integrity = run("/usr/bin/unzip", ["-t", file.path(percentEncoded: false)])
        #expect(integrity.status == 0)
        #expect(integrity.output.contains("No errors detected"))

        // The parts are there and the XML is well-formed — checked with
        // xmllint, which is also not ours.
        let listed = run("/usr/bin/unzip", ["-l", file.path(percentEncoded: false)])
        #expect(listed.output.contains("ppt/presentation.xml"))
        #expect(listed.output.contains("ppt/slides/slide1.xml"))

        let extracted = run("/usr/bin/unzip",
                            ["-o", "-q", file.path(percentEncoded: false),
                             "-d", directory.path(percentEncoded: false)])
        #expect(extracted.status == 0)
        let lint = run("/usr/bin/xmllint",
                       ["--noout",
                        directory.appending(path: "ppt/slides/slide1.xml")
                            .path(percentEncoded: false)])
        #expect(lint.status == 0)

        // Title, บทนำ, วิธีการ, ข้อจำกัด, เอกสารอ้างอิง.
        let slides = OfficeWriter.slides(from: rendered)
        #expect(slides.count == 5)
        #expect(slides[0].title == "ผลของเมตฟอร์มินต่อระดับ HbA1c")
        #expect(slides[1].title == "บทนำ")
        #expect(slides.last?.title == "References")
    }

    /// The bug this guards against shipped once: a deck with no master chain
    /// opens, but PowerPoint offers to repair it first and supplies the master
    /// itself — so the text arriving intact says nothing about the package being
    /// right. Every check below is on the package graph, where the fault was.
    @Test("a generated .pptx has the master chain every slide resolves through")
    func pptxHasACompleteMasterChain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "deck.pptx")
        let root = directory.appending(path: "unpacked")

        let rendered = try DocumentBuilder.render(draft())
        try OfficeWriter.pptx(rendered).write(to: file)
        #expect(run("/usr/bin/unzip",
                    ["-o", "-q", file.path(percentEncoded: false),
                     "-d", root.path(percentEncoded: false)]).status == 0)

        let parts = partNames(under: root)
        for required in ["ppt/slideMasters/slideMaster1.xml",
                         "ppt/slideLayouts/slideLayout1.xml",
                         "ppt/theme/theme1.xml",
                         "ppt/slides/_rels/slide1.xml.rels"] {
            #expect(parts.contains(required), "missing part: \(required)")
        }

        // Every relationship in the package points at a part that is in it. A
        // dangling target is the failure mode here, and it is invisible until a
        // reader follows the link.
        for relationships in parts.filter({ $0.hasSuffix(".rels") }) {
            let base = (relationships as NSString).deletingLastPathComponent  // …/_rels
            let owner = (base as NSString).deletingLastPathComponent
            for target in targets(ofRelationshipsIn: root.appending(path: relationships)) {
                let resolved = target.hasPrefix("/")
                    ? String(target.dropFirst())
                    : normalized((owner as NSString).appendingPathComponent(target))
                #expect(parts.contains(resolved),
                        "\(relationships) points at \(target), which is not in the package")
            }
        }

        // And every part is declared, which is the other half of the same
        // question: a reader that cannot type a part will not read it.
        let types = try String(contentsOf: root.appending(path: "[Content_Types].xml"),
                               encoding: .utf8)
        for part in parts where !part.hasSuffix(".rels") && part != "[Content_Types].xml" {
            #expect(types.contains("PartName=\"/\(part)\"") || types.contains("Extension=\"xml\""),
                    "no content type covers \(part)")
        }
        for declared in ["/ppt/slideMasters/slideMaster1.xml",
                         "/ppt/slideLayouts/slideLayout1.xml",
                         "/ppt/theme/theme1.xml"] {
            #expect(types.contains("PartName=\"\(declared)\""))
        }

        // The master is reachable from the presentation, not merely present.
        let presentation = try String(contentsOf: root.appending(path: "ppt/presentation.xml"),
                                      encoding: .utf8)
        #expect(presentation.contains("<p:sldMasterIdLst>"))
        // Schema order: the masters are listed before the slides.
        let masters = try #require(presentation.range(of: "<p:sldMasterIdLst>"))
        let slides = try #require(presentation.range(of: "<p:sldIdLst>"))
        #expect(masters.lowerBound < slides.lowerBound)

        // Each slide names its layout exactly once.
        for index in 1...OfficeWriter.slides(from: rendered).count {
            let rels = root.appending(path: "ppt/slides/_rels/slide\(index).xml.rels")
            let layouts = targets(ofRelationshipsIn: rels)
                .filter { $0.contains("slideLayout") }
            #expect(layouts.count == 1)
        }
    }

    /// §14.1: a source with no author or year stops generation. Not a warning
    /// beside a finished document — by then it is in a manuscript.
    @Test("a citation with no author or year stops the document being made")
    func incompleteCitationsRefuseToGenerate() {
        let incomplete = DocumentDraft(
            title: "ร่าง",
            sections: [Section(heading: "บทนำ", paragraphs: [
                .cited([CitedText("ข้อความ", from: source("x", "งานที่ไม่มีข้อมูล",
                                                          authors: [], year: nil))]),
            ])])
        #expect(throws: DocumentError.self) { try DocumentBuilder.render(incomplete) }

        // A person may knowingly want a working draft — but they have to say so.
        let anyway = try? DocumentBuilder.render(incomplete, allowingIncompleteCitations: true)
        #expect(anyway != nil)
        #expect(anyway?.bibliography.first?.contains("n.d.") == true)
    }

    @Test("an empty draft is refused rather than written as an empty file")
    func emptyDraftIsRefused() {
        #expect(throws: DocumentError.self) {
            try DocumentBuilder.render(DocumentDraft(title: "ว่าง"))
        }
    }

    /// The zip is written by hand, so the CRC is worth checking against a
    /// known value rather than only against unzip's opinion.
    @Test("the CRC-32 matches the standard test vector")
    func crcIsCorrect() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipArchive.crc32(Data()) == 0)
    }

    @Test("the rendered document is the same content the file gets")
    func renderingIsIndependentOfTheFormat() throws {
        let rendered = try DocumentBuilder.render(draft())
        #expect(rendered.lines.first?.style == .title)
        #expect(rendered.lines.contains { $0.style == .heading && $0.text == "วิธีการ" })
        #expect(rendered.bibliography.count == 2)
        // Both formats are written from this, so a check here is a check on
        // both of them.
        #expect(rendered.plainText.contains("Welch t-test"))
    }
}
