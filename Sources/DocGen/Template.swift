import Foundation
import os
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// A template, learned from a document somebody already has
// (ARCHITECTURE §14.1, M10 "upload ตัวอย่าง→auto-parse เป็น template", P7.9).
//
// The premise is the one thing worth stating: nobody writes a template. They
// have last year's proposal, or the one their department accepts, and what
// they want is *that shape* with this year's content in it. So the input here
// is a finished `.docx`, and the output is its skeleton — the headings, in
// order, with what was under each one kept as guidance rather than as content.
//
// **A template is a shape, never text to reuse.** The sample's sentences are
// somebody's actual writing about an actual study; carrying them into a new
// document is how a template turns into plagiarism of the person who lent you
// their file. `guidance` exists to be shown to whoever is filling the section
// in, and `TemplateFiller` never emits it.
// ─────────────────────────────────────────────────────────────

public struct TemplateSection: Sendable, Codable, Equatable {
    public var heading: String
    /// What the sample had under this heading, shortened. Guidance for a
    /// person, not content for a document.
    public var guidance: String?
    /// The sample used a list here, so the filled document probably should.
    public var expectsBullets: Bool
    /// A section the finished document must not be missing. Everything the
    /// sample had is required by default: it was in a document that was
    /// accepted, which is the only evidence available about what matters.
    public var isRequired: Bool

    public init(heading: String, guidance: String? = nil,
                expectsBullets: Bool = false, isRequired: Bool = true) {
        self.heading = heading
        self.guidance = guidance
        self.expectsBullets = expectsBullets
        self.isRequired = isRequired
    }
}

public struct DocumentTemplate: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    /// The sample's own title, kept as an example of the form — "โครงร่างวิจัย
    /// เรื่อง …" tells the next person what is expected of theirs.
    public var titleExample: String?
    public var sections: [TemplateSection]
    public var style: CitationStyle
    /// The file it was learned from, for the screen that lists templates.
    public var source: String?

    public init(id: String = OpaqueID.make("tpl"),
                name: String,
                titleExample: String? = nil,
                sections: [TemplateSection] = [],
                style: CitationStyle = .apa,
                source: String? = nil) {
        self.id = id
        self.name = name
        self.titleExample = titleExample
        self.sections = sections
        self.style = style
        self.source = source
    }

    public var headings: [String] { sections.map(\.heading) }

    /// Renames a heading, keeping everything else about the section (P7.9).
    ///
    /// A rename rather than a replace because `guidance` is the only record of
    /// what the accepted document had under that heading, and it is not
    /// recoverable once thrown away — the sample file may be long gone.
    ///
    /// An empty name is refused: a section with no heading cannot be found in
    /// the finished document, so the "is anything missing" check would pass it
    /// forever.
    public func renaming(_ index: Int, to heading: String) -> DocumentTemplate? {
        let trimmed = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sections.indices.contains(index), !trimmed.isEmpty else { return nil }
        // Two sections with one name is a document where "หัวข้อนี้ยังว่าง"
        // cannot say which one.
        guard !sections.enumerated().contains(where: { $0.offset != index
            && $0.element.heading.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return nil
        }
        var next = self
        next.sections[index].heading = trimmed
        return next
    }

    /// Turns a section's "must be there" on or off.
    ///
    /// Everything the sample had starts required — it was in a document
    /// somebody accepted, which is the only evidence available about what
    /// matters. Turning it off is a person disagreeing with that evidence, and
    /// they are allowed to.
    public func settingRequired(_ index: Int, _ required: Bool) -> DocumentTemplate? {
        guard sections.indices.contains(index) else { return nil }
        var next = self
        next.sections[index].isRequired = required
        return next
    }

    /// Moves a section to another position. Order is the order the document is
    /// read in, and a template learned from a file that put Methods last
    /// should be fixable without finding another file.
    public func moving(_ index: Int, to destination: Int) -> DocumentTemplate? {
        guard sections.indices.contains(index), sections.indices.contains(destination),
              index != destination else { return nil }
        var next = self
        let section = next.sections.remove(at: index)
        next.sections.insert(section, at: destination)
        return next
    }
}

public enum TemplateError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case noHeadings(String)

    public var description: String {
        switch self {
        case .unreadable(let file):
            return "อ่านไฟล์ \(file) ไม่ได้"
        case .noHeadings(let file):
            return "ไม่พบหัวข้อใน \(file) — เอกสารที่ใช้เป็นแม่แบบต้องมีหัวข้อ "
                + "(ใช้สไตล์ Heading ของ Word หรืออย่างน้อยให้หัวข้อเป็นตัวหนาบรรทัดเดียว)"
        }
    }
}

// ─────────────────────────────────────────────────────────────

public enum TemplateParser {

    /// Learns a template from a `.docx`.
    public static func parse(docx url: URL, name: String? = nil) throws -> DocumentTemplate {
        let outline = try WordOutline.read(url)
        return try template(from: outline, name: name ?? url.deletingPathExtension()
            .lastPathComponent, source: url.lastPathComponent)
    }

    static func template(from outline: WordOutline, name: String,
                         source: String?) throws -> DocumentTemplate {
        guard !outline.headings.isEmpty else {
            throw TemplateError.noHeadings(source ?? name)
        }
        let sections = outline.headings.map { heading in
            TemplateSection(heading: heading.text,
                            guidance: Self.guidance(from: heading.body),
                            expectsBullets: heading.hasBullets)
        }
        return DocumentTemplate(name: name, titleExample: outline.title,
                                sections: sections, source: source)
    }

    /// One line of what the sample said here, so a person filling the section
    /// can see what belongs in it. Short on purpose — see the note at the top
    /// about what a template is not.
    static func guidance(from body: [String], limit: Int = 160) -> String? {
        let joined = body.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return joined.count <= limit ? joined : String(joined.prefix(limit)) + "…"
    }
}

// ─────────────────────────────────────────────────────────────

/// The result of pouring a draft into a template. Returned rather than
/// applied silently: which sections the template wanted and the draft did not
/// have is the whole reason somebody chose a template.
public struct TemplateApplication: Sendable, Equatable {
    public let draft: DocumentDraft
    /// Template sections that found content.
    public let filled: [String]
    /// Template sections with nothing to put in them. Required ones are still
    /// in the document, with a line saying so.
    public let missing: [String]
    /// Content that the template has no section for. **Kept**, at the end —
    /// see `TemplateFiller`.
    public let extra: [String]

    public var isComplete: Bool { missing.isEmpty }
}

public enum TemplateFiller {

    /// The placeholder a required-but-empty section gets. Visible on purpose:
    /// a heading with nothing under it reads as an oversight, and this reads
    /// as a to-do.
    public static let emptyMarker = "(ยังไม่มีเนื้อหาในส่วนนี้ — ต้องเติมก่อนส่ง)"

    /// Reorders and renames a draft's sections to match a template.
    ///
    /// Two rules, and the second is the one that matters:
    ///
    ///  • A template section takes the draft's content whose heading matches
    ///    it — exactly, then ignoring case, spacing and any leading numbering,
    ///    because "2. วิธีการ" and "วิธีการ" are the same section to everyone
    ///    except a string comparison.
    ///  • **Content the template has no place for is never dropped.** It goes
    ///    at the end, under its own heading. A template is a shape somebody
    ///    chose for a document; it is not permission to delete the parts of
    ///    their work that did not fit, and a silent deletion here would be
    ///    found — if at all — by a reader of the finished manuscript.
    public static func apply(_ template: DocumentTemplate,
                             to draft: DocumentDraft) -> TemplateApplication {
        var remaining = draft.sections
        var sections: [Section] = []
        var filled: [String] = []
        var missing: [String] = []

        for wanted in template.sections {
            let index = remaining.firstIndex { matches($0.heading, wanted.heading) }
            if let index {
                var section = remaining.remove(at: index)
                // The template's spelling wins: it is the one the reader of
                // the finished document is expecting.
                section.heading = wanted.heading
                sections.append(section)
                filled.append(wanted.heading)
            } else {
                missing.append(wanted.heading)
                if wanted.isRequired {
                    sections.append(Section(heading: wanted.heading,
                                            paragraphs: [.plain(emptyMarker)]))
                }
            }
        }

        sections.append(contentsOf: remaining)
        var filledDraft = draft
        filledDraft.sections = sections
        filledDraft.style = template.style
        return TemplateApplication(draft: filledDraft, filled: filled, missing: missing,
                                   extra: remaining.map(\.heading))
    }

    /// Heading equality as a person means it.
    static func matches(_ left: String, _ right: String) -> Bool {
        normalised(left) == normalised(right)
    }

    static func normalised(_ heading: String) -> String {
        var text = heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Leading numbering in any of the shapes documents use: "1.", "1)",
        // "๑.", "บทที่ 1", "Chapter 2".
        for prefix in ["บทที่", "chapter", "section", "ตอนที่"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.trimmingCharacters(in: .whitespaces)
        while let first = text.first, first.isNumber || first.isPunctuation || first == " " {
            text.removeFirst()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
    }
}

// ─────────────────────────────────────────────────────────────

/// Where templates are kept. A file, like the connectors and the channels: it
/// is readable before anything runs, and a template is a thing a person will
/// want to copy between machines.
public struct TemplateStore: Sendable {
    public let file: URL
    private let log = AppLog.logger("docgen")

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [DocumentTemplate] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        // P9.2 — both shapes: the envelope this build writes, and the bare
        // array every file written before it is. A newer file is left alone
        // and reported rather than read as though we understood it.
        switch VersionedList.decode(data, as: DocumentTemplate.self) {
        case .list(let templates, _):
            return templates
        case .fromNewerBuild(let version):
            FileStoreIncidents.shared.record(.newerSchema(doing: "template", version: version))
            return []
        case .unreadable:
            reportUnreadable(file, kind: "template", log: log)
            return []
        }
    }

    public func save(_ templates: [DocumentTemplate]) throws {
        // P9.2 — a file from a newer build is not written over. Running on
        // defaults for one session is recoverable; overwriting is not, and the
        // build somebody would go back to is the one that lost their settings.
        guard VersionedList.mayOverwrite(file, of: DocumentTemplate.self) else {
            throw FileStoreError.fileFromNewerBuild
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try VersionedList.encode(templates).write(to: file, options: .atomic)
    }

    @discardableResult
    public func add(_ template: DocumentTemplate) throws -> [DocumentTemplate] {
        var templates = load().filter { $0.id != template.id }
        templates.append(template)
        try save(templates)
        return templates
    }

    /// Writes an edited template back **where it was** (P7.9).
    ///
    /// Not `add`, which appends: a template that jumped to the bottom of the
    /// list every time somebody renamed a heading would be a list nobody could
    /// keep their place in.
    @discardableResult
    public func replace(_ template: DocumentTemplate) throws -> [DocumentTemplate] {
        var templates = load()
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else {
            return try add(template)
        }
        templates[index] = template
        try save(templates)
        return templates
    }

    public func remove(_ id: String) throws {
        try save(load().filter { $0.id != id })
    }
}

/// A list file that will not decode. The copy is taken here, before anything
/// can save over it, and the report is kept where a screen can show it — a
/// corrupt file that only ever reached the unified log is a list that went
/// empty one morning with no explanation (P9.4).
private func reportUnreadable(_ file: URL, kind: String, log: Logger) {
    let failure = FileStoreSafety.reportUnreadable(file, describedAs: kind)
    log.error("\(failure.summary, privacy: .public)")
}
