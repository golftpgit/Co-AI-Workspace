import Foundation

// ─────────────────────────────────────────────────────────────
// Reading a `.docx` back, for its shape (P7.9).
//
// `DocumentReader` (P2.3) already gets the *text* out of a Word file, and that
// is the right thing for the knowledge base — it wants sentences. A template
// wants the opposite: which paragraph is a heading, which is body, which is a
// list. That information is in `w:pStyle` and `w:numPr`, and it is exactly
// what a text extractor is built to discard. Hence a second reader rather than
// a flag on the first: they want different halves of the same file.
//
// **Three ways a heading is written, because documents come from people.**
//
//  1. `w:pStyle` naming one of Word's heading styles. The clean case.
//  2. `w:outlineLvl` on the paragraph, which is what Word sets when someone
//     uses "Add to table of contents" without applying a style.
//  3. Nothing at all — a short, entirely bold line. This is the common case in
//     documents that were typed rather than styled, and a parser that only
//     handled the first two would report "no headings" on the very files
//     people most want to use as templates: the ones they wrote by hand.
//
// The third rule is only applied when the first two found nothing. A document
// that has real heading styles and also some bold sentences must not have the
// bold sentences promoted into sections.
// ─────────────────────────────────────────────────────────────

struct WordOutline: Equatable {
    struct Heading: Equatable {
        let text: String
        let level: Int
        let body: [String]
        let hasBullets: Bool
    }

    let title: String?
    let headings: [Heading]
}

extension WordOutline {

    static func read(_ url: URL) throws -> WordOutline {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "coai-template-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", "-o", url.path(percentEncoded: false),
                           "word/document.xml", "-d", directory.path(percentEncoded: false)]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            throw TemplateError.unreadable(url.lastPathComponent)
        }
        guard unzip.terminationStatus == 0,
              let data = try? Data(contentsOf: directory.appending(path: "word/document.xml"))
        else { throw TemplateError.unreadable(url.lastPathComponent) }

        return outline(from: WordParagraphReader().paragraphs(fromXML: data))
    }

    /// One flat list of paragraphs becomes a title and a list of sections.
    static func outline(from paragraphs: [WordParagraph]) -> WordOutline {
        var paragraphs = paragraphs.filter { !$0.text.isEmpty }
        let styled = paragraphs.contains { $0.role == .heading }
        if !styled {
            // Rule 3, and only now: a bold one-liner is a heading in a
            // document that has no styled ones.
            paragraphs = paragraphs.map { paragraph in
                guard paragraph.role == .body, paragraph.isEntirelyBold,
                      paragraph.text.count <= 120 else { return paragraph }
                var promoted = paragraph
                promoted.role = .heading
                return promoted
            }
        }

        var title: String?
        var headings: [Heading] = []
        var current: (text: String, level: Int, body: [String], bullets: Bool)?

        for paragraph in paragraphs {
            switch paragraph.role {
            case .title:
                // The first title wins; a second one is a subtitle somebody
                // styled oddly, and it belongs to the body.
                if title == nil { title = paragraph.text } else { current?.body.append(paragraph.text) }
            case .heading:
                if let open = current {
                    headings.append(Heading(text: open.text, level: open.level,
                                            body: open.body, hasBullets: open.bullets))
                }
                current = (paragraph.text, paragraph.level, [], false)
            case .body, .bullet:
                // Body before the first heading is the title block — authors,
                // a date, an affiliation. Not a section.
                guard current != nil else {
                    if title == nil { title = paragraph.text }
                    continue
                }
                current?.body.append(paragraph.text)
                if paragraph.role == .bullet { current?.bullets = true }
            }
        }
        if let open = current {
            headings.append(Heading(text: open.text, level: open.level,
                                    body: open.body, hasBullets: open.bullets))
        }
        return WordOutline(title: title, headings: headings)
    }
}

struct WordParagraph: Equatable {
    enum Role: Equatable { case title, heading, body, bullet }
    var role: Role
    var level: Int
    var text: String
    /// Every run in it is bold, and there is at least one run. Used only by
    /// rule 3 above.
    var isEntirelyBold: Bool
}

/// Pulls paragraphs *with their styles* out of `word/document.xml`.
///
/// Written against the elements rather than the text: `w:p` opens a paragraph,
/// `w:pStyle` names its style, `w:numPr` makes it a list item, `w:b` makes a
/// run bold, and `w:t` is the only place characters live.
final class WordParagraphReader: NSObject, XMLParserDelegate {
    private var paragraphs: [WordParagraph] = []
    private var text = ""
    private var style: String?
    private var outlineLevel: Int?
    private var isList = false
    private var runCount = 0
    private var boldRunCount = 0
    private var inRunProperties = false
    private var runIsBold = false
    private var capturing = false

    func paragraphs(fromXML data: Data) -> [WordParagraph] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return paragraphs
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch element {
        case "w:p":
            text = ""; style = nil; outlineLevel = nil; isList = false
            runCount = 0; boldRunCount = 0
        case "w:pStyle":
            style = attributes["w:val"]
        case "w:outlineLvl":
            outlineLevel = attributes["w:val"].flatMap(Int.init)
        case "w:numPr":
            isList = true
        case "w:r":
            runCount += 1
            runIsBold = false
        case "w:rPr":
            inRunProperties = true
        case "w:b":
            // `<w:b w:val="0"/>` is bold turned *off*, which is how a bold
            // paragraph gets one un-bold word in it.
            if inRunProperties, attributes["w:val"] != "0", attributes["w:val"] != "false" {
                runIsBold = true
            }
        case "w:t":
            capturing = true
        case "w:tab":
            text += " "
        case "w:br":
            text += " "
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing else { return }
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "w:t":
            capturing = false
        case "w:rPr":
            inRunProperties = false
        case "w:r":
            if runIsBold { boldRunCount += 1 }
        case "w:p":
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let (body, drawnAsList) = Self.stripBullet(trimmed)
            paragraphs.append(
                WordParagraph(role: Self.role(style: style, outlineLevel: outlineLevel,
                                              isList: isList || drawnAsList),
                              level: Self.level(style: style, outlineLevel: outlineLevel),
                              text: body,
                              isEntirelyBold: runCount > 0 && boldRunCount == runCount))
        default:
            break
        }
    }

    /// A list item drawn as a character rather than declared as one.
    ///
    /// Not an edge case, and the nearest example is this project: `OfficeWriter`
    /// writes bullets as a literal "• " precisely so it does not need a
    /// `numbering.xml` (P7.6), which means a reader that only understood
    /// `w:numPr` could not read the documents this app itself produces. Typed
    /// documents do the same thing for the same reason — it is easier than
    /// finding the list button.
    static func stripBullet(_ text: String) -> (text: String, wasList: Bool) {
        for marker in ["• ", "•", "- ", "– ", "— ", "* ", "● ", "▪ ", "· "]
        where text.hasPrefix(marker) {
            return (String(text.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespaces), true)
        }
        return (text, false)
    }

    /// Word's own style ids, which are stable across localisations — a Thai
    /// Word still writes `w:val="Heading1"` for หัวเรื่อง 1, and matching on
    /// the display name instead is how this breaks on somebody else's machine.
    static func role(style: String?, outlineLevel: Int?, isList: Bool) -> WordParagraph.Role {
        if let style {
            let normalised = style.replacingOccurrences(of: " ", with: "").lowercased()
            if normalised == "title" { return .title }
            if normalised.hasPrefix("heading") { return .heading }
            if normalised == "listparagraph" { return .bullet }
        }
        if outlineLevel != nil { return .heading }
        return isList ? .bullet : .body
    }

    static func level(style: String?, outlineLevel: Int?) -> Int {
        if let outlineLevel { return outlineLevel + 1 }
        guard let style,
              let digit = style.last, digit.isNumber,
              style.lowercased().hasPrefix("heading") else { return 1 }
        return digit.wholeNumberValue ?? 1
    }
}
