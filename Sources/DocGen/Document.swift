import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// What a document is before it is a file (ARCHITECTURE §14.1, P7.6).
//
// Rendering and formatting are separated on purpose: `DocumentBuilder` turns a
// draft into a flat list of styled lines — headings, body text with citation
// markers in place, the bibliography, the Limitations section — and the writers
// turn that list into Word's XML or Keynote's. So the interesting half is
// testable without unzipping anything, and a second output format is a new
// writer rather than a second copy of the rules.
//
// The rule §14.1 states and this file enforces: **a source with no author or
// year stops generation**. Not a warning printed next to a finished document —
// the document is not produced, because a citation with an invented year is
// worse than a missing one, and by the time anybody notices it is in a
// manuscript.
// ─────────────────────────────────────────────────────────────

public enum Paragraph: Sendable, Equatable {
    /// Text the system wrote itself — a method description, a transition.
    case plain(String)
    /// Sentences from the knowledge base. Each one carries its source, so the
    /// markers are placed from the provenance rather than typed by anyone.
    case cited([CitedText])
    case bullets([String])
}

public struct Section: Sendable, Equatable {
    public var heading: String
    public var paragraphs: [Paragraph]

    public init(heading: String, paragraphs: [Paragraph]) {
        self.heading = heading
        self.paragraphs = paragraphs
    }
}

public struct DocumentDraft: Sendable, Equatable {
    public var title: String
    public var authors: [String]
    public var sections: [Section]
    public var style: CitationStyle
    /// §14.1: written by the system out of what the run recorded, and appended
    /// without anybody asking (P7.8).
    public var limitations: LimitationsSection?

    public init(title: String,
                authors: [String] = [],
                sections: [Section] = [],
                style: CitationStyle = .apa,
                limitations: LimitationsSection? = nil) {
        self.title = title
        self.authors = authors
        self.sections = sections
        self.style = style
        self.limitations = limitations
    }

    /// Every cited sentence in the document, in order — what the audit and the
    /// bibliography both work from.
    public var citations: [CitedText] {
        sections.flatMap { section in
            section.paragraphs.flatMap { paragraph -> [CitedText] in
                if case .cited(let citations) = paragraph { return citations }
                return []
            }
        }
    }
}

/// One line of the finished document, with the role it plays.
public struct RenderedLine: Sendable, Equatable {
    public enum Style: String, Sendable, Equatable {
        case title
        case subtitle
        case heading
        case body
        case bullet
    }

    public let style: Style
    public let text: String
}

public struct RenderedDocument: Sendable, Equatable {
    public let title: String
    public let lines: [RenderedLine]
    /// Kept apart from `lines` so a slide deck can put it on its own slide and
    /// a report can put it at the end.
    public let bibliography: [String]

    public var plainText: String {
        (lines.map(\.text) + (bibliography.isEmpty ? [] : ["", "เอกสารอ้างอิง"] + bibliography))
            .joined(separator: "\n")
    }
}

public enum DocumentError: Error, CustomStringConvertible, Equatable {
    case incompleteCitations(CitationAudit)
    case empty

    public var description: String {
        switch self {
        case .empty: "ยังไม่มีเนื้อหาให้สร้างเอกสาร"
        case .incompleteCitations(let audit):
            "สร้างเอกสารไม่ได้ — มีแหล่งอ้างอิงที่ข้อมูลไม่ครบ:\n"
                + audit.missing.map { "• \($0.title): ขาด\($0.fields.joined(separator: ", "))" }
                    .joined(separator: "\n")
        }
    }
}

public enum DocumentBuilder {

    /// Renders a draft, refusing when a citation could not be written properly.
    ///
    /// `allowingIncompleteCitations` exists because a person may knowingly want
    /// a working draft of something not yet finished — but it is a parameter
    /// they have to pass, not a default they can forget.
    public static func render(_ draft: DocumentDraft,
                              allowingIncompleteCitations: Bool = false) throws -> RenderedDocument {
        guard !draft.sections.isEmpty || draft.limitations?.isEmpty == false else {
            throw DocumentError.empty
        }
        let audit = CitationAudit.audit(draft.citations)
        guard audit.isComplete || allowingIncompleteCitations else {
            throw DocumentError.incompleteCitations(audit)
        }

        var bibliography = Bibliography(style: draft.style)
        var lines: [RenderedLine] = [RenderedLine(style: .title, text: draft.title)]
        if !draft.authors.isEmpty {
            lines.append(RenderedLine(style: .subtitle,
                                      text: draft.authors.joined(separator: ", ")))
        }

        for section in draft.sections {
            lines.append(RenderedLine(style: .heading, text: section.heading))
            for paragraph in section.paragraphs {
                switch paragraph {
                case .plain(let text):
                    lines.append(RenderedLine(style: .body, text: text))
                case .cited(let citations):
                    // The markers are placed here, from the provenance —
                    // nobody types a citation into a sentence.
                    lines.append(RenderedLine(style: .body,
                                              text: bibliography.render(citations)))
                case .bullets(let items):
                    lines.append(contentsOf: items.map { RenderedLine(style: .bullet, text: $0) })
                }
            }
        }

        // §14.1: the Limitations section is part of the document, not an
        // appendix somebody remembers to add.
        if let limitations = draft.limitations, !limitations.isEmpty {
            lines.append(RenderedLine(style: .heading, text: "ข้อจำกัดของการศึกษานี้"))
            lines.append(contentsOf: limitations.items.map {
                RenderedLine(style: .bullet, text: $0.text)
            })
        }

        return RenderedDocument(title: draft.title, lines: lines,
                                bibliography: bibliography.entries())
    }
}
