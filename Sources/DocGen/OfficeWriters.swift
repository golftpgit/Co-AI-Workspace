import Foundation

// ─────────────────────────────────────────────────────────────
// Word and Keynote files (ARCHITECTURE §14.1, P7.6).
//
// Both formats are OOXML: a zip of XML parts, tied together by relationship
// files. What is written here is the smallest package each application will
// open — a real one, not a rich one. Styles are declared rather than inherited
// from a template, because a document that opens with the wrong fonts is a
// fixable complaint and a document that does not open is not.
//
// **Thai text is why the fonts are named.** Word picks a fallback for a script
// the theme font does not cover, and the fallback it picks for Thai is not
// always one that renders the vowel marks correctly. `w:cs` (complex script)
// has to be set alongside `w:ascii`, which is the kind of detail that is
// invisible until a document full of Thai comes out looking wrong.
// ─────────────────────────────────────────────────────────────

public enum OfficeWriter {

    // MARK: - .docx

    public static func docx(_ document: RenderedDocument) -> Data {
        var archive = ZipArchive()
        archive.add("[Content_Types].xml", contentTypesForWord)
        archive.add("_rels/.rels", packageRelationships(target: "word/document.xml"))
        archive.add("word/_rels/document.xml.rels", documentRelationships)
        archive.add("word/styles.xml", wordStyles)
        archive.add("word/document.xml", wordDocument(document))
        return archive.build()
    }

    private static func wordDocument(_ document: RenderedDocument) -> String {
        var body = document.lines.map(paragraph(for:)).joined()
        if !document.bibliography.isEmpty {
            body += paragraph(for: RenderedLine(style: .heading, text: "เอกสารอ้างอิง"))
            body += document.bibliography
                .map { paragraph(for: RenderedLine(style: .body, text: $0)) }
                .joined()
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
        <w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr>
        </w:body></w:document>
        """
    }

    private static func paragraph(for line: RenderedLine) -> String {
        let style: String
        switch line.style {
        case .title: style = "Title"
        case .subtitle: style = "Subtitle"
        case .heading: style = "Heading1"
        case .body, .bullet: style = "Normal"
        }
        // A bullet drawn as a character rather than through numbering.xml: a
        // numbering definition is a second part, a second relationship and a
        // second way for the package to be wrong, and this document does not
        // need list continuation or nesting.
        let text = line.style == .bullet ? "• " + line.text : line.text
        return """
        <w:p><w:pPr><w:pStyle w:val="\(style)"/></w:pPr>\
        <w:r><w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Thonburi"/></w:rPr>\
        <w:t xml:space="preserve">\(escaped(text))</w:t></w:r></w:p>
        """
    }

    private static let contentTypesForWord = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" \
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" \
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    </Types>
    """

    private static let documentRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" \
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" \
    Target="styles.xml"/>
    </Relationships>
    """

    private static let wordStyles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:style w:type="paragraph" w:styleId="Normal" w:default="1"><w:name w:val="Normal"/>
    <w:pPr><w:spacing w:after="120"/></w:pPr><w:rPr><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>
    <w:pPr><w:spacing w:after="240"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/>
    <w:pPr><w:spacing w:after="240"/></w:pPr>
    <w:rPr><w:i/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>
    <w:pPr><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style>
    </w:styles>
    """

    // MARK: - .pptx

    /// One slide per heading, its body lines as bullets. A deck is an outline
    /// with a title on top, and that is exactly what a rendered document is.
    public static func pptx(_ document: RenderedDocument) -> Data {
        let slides = self.slides(from: document)
        var archive = ZipArchive()
        archive.add("[Content_Types].xml", contentTypesForSlides(count: slides.count))
        archive.add("_rels/.rels", packageRelationships(target: "ppt/presentation.xml"))
        archive.add("ppt/presentation.xml", presentation(slideCount: slides.count))
        archive.add("ppt/_rels/presentation.xml.rels", presentationRelationships(count: slides.count))
        for (index, slide) in slides.enumerated() {
            archive.add("ppt/slides/slide\(index + 1).xml", slideXML(slide))
        }
        return archive.build()
    }

    struct Slide: Equatable {
        let title: String
        let bullets: [String]
    }

    /// Groups the rendered lines into slides. A heading starts one; the title
    /// gets its own.
    static func slides(from document: RenderedDocument) -> [Slide] {
        var slides: [Slide] = []
        var title = document.title
        var bullets: [String] = []
        for line in document.lines {
            switch line.style {
            case .title:
                title = line.text
            case .subtitle:
                bullets.append(line.text)
            case .heading:
                slides.append(Slide(title: title, bullets: bullets))
                title = line.text
                bullets = []
            case .body, .bullet:
                bullets.append(line.text)
            }
        }
        slides.append(Slide(title: title, bullets: bullets))
        if !document.bibliography.isEmpty {
            slides.append(Slide(title: "เอกสารอ้างอิง", bullets: document.bibliography))
        }
        return slides
    }

    private static func slideXML(_ slide: Slide) -> String {
        // Two text boxes with explicit geometry rather than placeholders from a
        // layout: a layout means a slideLayout part, a slideMaster part and the
        // relationships between them — three more ways for the package to be
        // rejected, for a deck that is an outline.
        let bullets = slide.bullets.isEmpty ? [""] : slide.bullets
        let body = bullets.map {
            """
            <a:p><a:pPr marL="171450" indent="-171450"><a:buChar char="•"/></a:pPr>\
            <a:r><a:rPr lang="th-TH" sz="1800"/><a:t>\(escaped($0))</a:t></a:r></a:p>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr/>
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="628650" y="365125"/><a:ext cx="7886700" cy="1325563"/></a:xfrm>
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
        <p:txBody><a:bodyPr/><a:lstStyle/>
        <a:p><a:r><a:rPr lang="th-TH" sz="3200" b="1"/><a:t>\(escaped(slide.title))</a:t></a:r></a:p>
        </p:txBody></p:sp>
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Body"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="628650" y="1825625"/><a:ext cx="7886700" cy="4351338"/></a:xfrm>
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
        <p:txBody><a:bodyPr/><a:lstStyle/>\(body)</p:txBody></p:sp>
        </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }

    private static func presentation(slideCount: Int) -> String {
        let ids = (1...max(slideCount, 1)).map {
            "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:sldIdLst>\(ids)</p:sldIdLst>
        <p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
    }

    private static func presentationRelationships(count: Int) -> String {
        let relationships = (1...max(count, 1)).map {
            """
            <Relationship Id="rId\($0)" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" \
            Target="slides/slide\($0).xml"/>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(relationships)</Relationships>
        """
    }

    private static func contentTypesForSlides(count: Int) -> String {
        let overrides = (1...max(count, 1)).map {
            """
            <Override PartName="/ppt/slides/slide\($0).xml" \
            ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/ppt/presentation.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        \(overrides)</Types>
        """
    }

    // MARK: - shared

    private static func packageRelationships(target: String) -> String {
        let type = target.hasPrefix("word")
            ? "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
            : "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="\(type)" Target="\(target)"/>
        </Relationships>
        """
    }

    /// XML escaping. Not optional and not clever: a title with an ampersand in
    /// it is the most ordinary thing in the world, and it would make the
    /// package unreadable.
    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            // Control characters are not legal in XML 1.0 at all; tabs and
            // newlines inside a run would be dropped by the reader anyway.
            case "\n", "\r", "\t": result += " "
            default: result.append(character)
            }
        }
        return result
    }
}
