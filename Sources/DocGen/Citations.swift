import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// M10 DocGen — citations (ARCHITECTURE §14.1, P7.7).
//
// The Done-when is "ทุกประโยคจาก KB มี citation ผูก provenance จริง", and the
// only way to make that structural rather than hopeful is for a cited sentence
// to be a *type* that cannot exist without its source. `CitedText` has one
// initialiser and it takes a `Provenance`; a paragraph is built out of those,
// so a sentence with no source is not something a caller forgot — it is
// something they could not have written.
//
// The styles are the three §14.1 names. They differ in more than punctuation:
// APA cites by author and year, IEEE and Vancouver by a number in order of
// first appearance, which means the numbering is a property of the *document*
// and not of any one sentence. That is why numbering happens in `Bibliography`
// and not in the sentence.
// ─────────────────────────────────────────────────────────────

public enum CitationStyle: String, Sendable, Codable, CaseIterable, Identifiable {
    case apa
    case ieee
    case vancouver

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .apa: "APA"
        case .ieee: "IEEE"
        case .vancouver: "Vancouver"
        }
    }

    /// Whether the inline marker is a number assigned in order of appearance.
    var isNumbered: Bool { self != .apa }
}

/// A sentence, and where it came from. There is no way to make one without a
/// source — §14.1's promise, enforced by the initialiser.
public struct CitedText: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let provenance: Provenance

    public init(id: String = OpaqueID.make("cite"), _ text: String, from provenance: Provenance) {
        self.id = id
        self.text = text
        self.provenance = provenance
    }

    /// Two citations point at the same work when they name the same document,
    /// whatever page each sentence came from — a bibliography lists works, not
    /// paragraphs.
    var workKey: String { provenance.documentID }
}

/// The rule §14.1 states for how confidently something may be written.
public enum Corroboration: Sendable, Equatable {
    /// Two or more sources at T1–T2.
    case strong
    /// Enough to state, with the qualification that goes with it.
    case adequate
    /// Only weak sources, or only one of anything.
    case weak(reason: String)

    public var mayStatePlainly: Bool { self == .strong }

    public var note: String? {
        switch self {
        case .strong: nil
        case .adequate: "มีแหล่งรองรับพอสมควร แต่ยังไม่ถึงเกณฑ์ 'แหล่งชั้นต้นสองแหล่งขึ้นไป'"
        case .weak(let reason): reason
        }
    }
}

public enum CrossSource {
    /// §14.1's tier-aware rule, as arithmetic.
    ///
    /// Deliberately counting *works*, not sentences: quoting one paper three
    /// times is one source, and a rule that counted otherwise would let a
    /// single blog post look like a consensus.
    public static func assess(_ citations: [CitedText]) -> Corroboration {
        var tiers: [String: SourceTier?] = [:]
        for citation in citations { tiers[citation.workKey] = citation.provenance.tier }
        let works = tiers.values.map { $0 }
        guard !works.isEmpty else { return .weak(reason: "ไม่มีแหล่งอ้างอิงเลย") }

        let strongCount = works.filter { $0 == .t1 || $0 == .t2 }.count
        let midCount = works.filter { $0 == .t3 }.count
        if strongCount >= 2 { return .strong }
        if works.count == 1 {
            return .weak(reason: "มีแหล่งเดียว — ยังยืนยันข้ามแหล่งไม่ได้")
        }
        if strongCount + midCount >= 1 { return .adequate }
        // Ten weak sources are not two strong ones; §14.1 is explicit that
        // T5s need at least one T1–T3 standing behind them.
        return .weak(reason: "มีแต่แหล่งชั้นรอง (T4–T5) \(works.count) แหล่ง — "
                     + "ต้องมีแหล่ง T1–T3 ยืนยันอย่างน้อยหนึ่งแหล่ง")
    }
}

/// Numbers the works and renders both halves of the citation.
public struct Bibliography: Sendable {
    public let style: CitationStyle
    /// Works in order of first appearance, which is what IEEE and Vancouver
    /// number by.
    public private(set) var works: [Provenance] = []
    private var indexByWork: [String: Int] = [:]

    public init(style: CitationStyle) {
        self.style = style
    }

    /// Registers a citation and returns its inline marker.
    public mutating func marker(for citation: CitedText) -> String {
        let key = citation.workKey
        let number: Int
        if let existing = indexByWork[key] {
            number = existing
        } else {
            works.append(citation.provenance)
            number = works.count
            indexByWork[key] = number
        }
        switch style {
        case .apa:
            return "(\(Self.apaAuthor(citation.provenance)), \(Self.year(citation.provenance)))"
        case .ieee:
            return "[\(number)]"
        case .vancouver:
            return "(\(number))"
        }
    }

    /// Renders a paragraph with its markers in place.
    public mutating func render(_ citations: [CitedText]) -> String {
        citations.map { "\($0.text) \(marker(for: $0))" }.joined(separator: " ")
    }

    /// The list at the end, in this style's order: numbered styles keep order
    /// of appearance, APA sorts by author.
    public func entries() -> [String] {
        let rendered = works.enumerated().map { index, work in
            style.isNumbered
                ? "[\(index + 1)] \(Self.entry(work, style: style))"
                : Self.entry(work, style: style)
        }
        return style == .apa ? rendered.sorted() : rendered
    }

    // MARK: - rendering one work

    static func entry(_ work: Provenance, style: CitationStyle) -> String {
        let authors = work.authors.isEmpty ? work.title : authorList(work.authors, style: style)
        let year = self.year(work)
        var parts: [String]
        switch style {
        case .apa:
            parts = ["\(authors) (\(year)).", work.title + "."]
        case .ieee:
            parts = ["\(authors), \"\(work.title),\"", "\(year)."]
        case .vancouver:
            parts = ["\(authors).", "\(work.title).", "\(year)."]
        }
        parts.append(contentsOf: locator(work))
        return parts.joined(separator: " ")
    }

    /// Where it was read, and when. §11.3 keeps `accessedAt` because the same
    /// URL says something else next month, and a web citation without it is
    /// not checkable.
    private static func locator(_ work: Provenance) -> [String] {
        var parts: [String] = []
        if let section = work.section, !section.isEmpty { parts.append("§\(section).") }
        if let page = work.page { parts.append("น. \(page).") }
        switch work.origin {
        case .web(let url):
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            parts.append("\(url.absoluteString) (เข้าถึง \(formatter.string(from: work.accessedAt))).")
        case .upload(let filename):
            parts.append("[ไฟล์: \(filename)].")
        case .database(let name):
            parts.append("[ฐานข้อมูล: \(name)].")
        case .userAuthored:
            parts.append("[ระบบสร้างเอง].")
        }
        if let tier = work.tier { parts.append("(\(tier.rawValue.uppercased()))") }
        return parts
    }

    static func authorList(_ authors: [String], style: CitationStyle) -> String {
        switch style {
        case .apa:
            // APA's et al. threshold is 3 or more.
            return authors.count >= 3 ? "\(authors[0]) et al." : authors.joined(separator: " & ")
        case .ieee, .vancouver:
            return authors.count > 6
                ? authors.prefix(6).joined(separator: ", ") + ", et al."
                : authors.joined(separator: ", ")
        }
    }

    static func apaAuthor(_ work: Provenance) -> String {
        guard let first = work.authors.first else { return work.title }
        return work.authors.count >= 3 ? "\(first) et al."
            : work.authors.joined(separator: " & ")
    }

    /// "n.d." rather than a guess: §14.1 says a file with no year is flagged
    /// for the user to fill in, and inventing one here would remove the flag.
    static func year(_ work: Provenance) -> String {
        work.year.map(String.init) ?? "n.d."
    }
}

/// What §14.1 says must stop a document being generated: a source with no
/// author and no year cannot be cited properly, and the person has to fill it
/// in rather than have something plausible written for them.
public struct CitationAudit: Sendable, Equatable {
    public struct Missing: Sendable, Equatable, Identifiable {
        public let documentID: String
        public let title: String
        public let fields: [String]
        public var id: String { documentID }
    }

    public let missing: [Missing]
    public var isComplete: Bool { missing.isEmpty }

    public static func audit(_ citations: [CitedText]) -> CitationAudit {
        var found: [String: Missing] = [:]
        for citation in citations {
            let work = citation.provenance
            var fields: [String] = []
            if work.authors.isEmpty, !work.origin.isSelfAuthored { fields.append("ผู้เขียน") }
            if work.year == nil, !work.origin.isSelfAuthored { fields.append("ปี") }
            guard !fields.isEmpty else { continue }
            found[work.documentID] = Missing(documentID: work.documentID,
                                             title: work.title, fields: fields)
        }
        return CitationAudit(missing: found.values.sorted { $0.documentID < $1.documentID })
    }
}

extension Origin {
    /// Work the system wrote itself has no author to be missing.
    var isSelfAuthored: Bool {
        if case .userAuthored = self { return true }
        return false
    }
}
