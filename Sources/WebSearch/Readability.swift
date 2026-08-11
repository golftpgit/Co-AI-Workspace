import Foundation

// ─────────────────────────────────────────────────────────────
// Turning a web page into the text that was actually written on it
// (ARCHITECTURE §1.4, P3.4).
//
// Why this exists rather than "strip the tags": a page is mostly not its
// article. Navigation, cookie banners, related-links rails and footers are all
// text, and a naive extraction hands the model a paragraph of menu items as
// though it were evidence.
//
// Output is paragraphs, not one blob, because §11.3 wants provenance at
// paragraph level — a citation that says "somewhere on this page" is not one.
// ─────────────────────────────────────────────────────────────

public struct ExtractedPage: Sendable, Equatable {
    public let title: String?
    /// In document order. The index is part of a citation.
    public let paragraphs: [String]
    public var text: String { paragraphs.joined(separator: "\n\n") }
    public var isEmpty: Bool { paragraphs.isEmpty }
}

public struct Readability: Sendable {
    /// Blocks shorter than this are furniture — buttons, labels, breadcrumbs.
    /// Low enough to keep a one-line heading that introduces a section.
    private let minimumBlockLength: Int
    /// A block more than half links is a navigation rail no matter which tag
    /// it happens to use.
    private let maximumLinkDensity: Double

    public init(minimumBlockLength: Int = 40, maximumLinkDensity: Double = 0.5) {
        self.minimumBlockLength = minimumBlockLength
        self.maximumLinkDensity = maximumLinkDensity
    }

    public func extract(html: String) -> ExtractedPage {
        let title = Self.firstMatch(in: html, pattern: "<title[^>]*>(.*?)</title>")
            .map(Self.decodeEntities)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var body = html
        // Order matters: comments can contain anything, and a stripped-out
        // <script> can otherwise leave its contents behind as "text".
        body = Self.remove(pattern: "<!--.*?-->", from: body)
        for tag in ["script", "style", "noscript", "svg", "template",
                    "nav", "header", "footer", "aside", "form"] {
            body = Self.remove(pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>", from: body)
        }

        let blocks = Self.blocks(in: body)
        let paragraphs = blocks.compactMap { block -> String? in
            let text = Self.decodeEntities(Self.stripTags(block.inner))
                .replacingOccurrences(of: "[ \\t\\u{00a0}]+", with: " ",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard text.count >= minimumBlockLength else { return nil }
            guard Self.linkDensity(of: block.inner, textLength: text.count) <= maximumLinkDensity
            else { return nil }
            return text
        }

        // Consecutive duplicates are the same sentence appearing in a summary
        // box and again in the body; keeping both doubles it in every quote.
        var deduplicated: [String] = []
        for paragraph in paragraphs where deduplicated.last != paragraph {
            deduplicated.append(paragraph)
        }
        return ExtractedPage(title: title, paragraphs: deduplicated)
    }

    // MARK: - blocks

    private struct Block { let inner: String }

    /// The tags that carry prose. Everything else is layout, and a <div> that
    /// holds real text almost always holds it inside one of these.
    private static let blockTags = ["p", "h1", "h2", "h3", "h4", "h5", "h6",
                                    "li", "blockquote", "pre", "dd", "figcaption"]

    private static func blocks(in html: String) -> [Block] {
        let pattern = "<(" + blockTags.joined(separator: "|") + ")\\b[^>]*>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators,
                                                             .caseInsensitive])
        else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let inner = Range(match.range(at: 2), in: html) else { return nil }
            return Block(inner: String(html[inner]))
        }
    }

    private static func linkDensity(of html: String, textLength: Int) -> Double {
        guard textLength > 0 else { return 1 }
        let anchors = matches(in: html, pattern: "<a\\b[^>]*>(.*?)</a>")
        let linked = anchors.reduce(0) { $0 + decodeEntities(stripTags($1)).count }
        return Double(linked) / Double(textLength)
    }

    // MARK: - text

    static func stripTags(_ html: String) -> String {
        // <br> and </p> are line breaks, not nothing: without this two
        // sentences run together into one unreadable string.
        html
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func decodeEntities(_ text: String) -> String {
        var output = text
        let named = ["&nbsp;": "\u{00a0}", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                     "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—",
                     "&ndash;": "–", "&hellip;": "…", "&laquo;": "«", "&raquo;": "»"]
        for (entity, replacement) in named {
            output = output.replacingOccurrences(of: entity, with: replacement,
                                                 options: .caseInsensitive)
        }
        // Numeric entities — Thai pages encoded this way are otherwise
        // unreadable rather than merely ugly.
        output = replaceNumericEntities(in: output, pattern: "&#([0-9]+);", radix: 10)
        output = replaceNumericEntities(in: output, pattern: "&#[xX]([0-9a-fA-F]+);", radix: 16)
        return output
    }

    private static func replaceNumericEntities(in text: String, pattern: String,
                                               radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var output = text
        let matches = regex.matches(in: text,
                                    range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: output),
                  let digits = Range(match.range(at: 1), in: text),
                  let value = UInt32(text[digits], radix: radix),
                  let scalar = Unicode.Scalar(value) else { continue }
            output.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return output
    }

    // MARK: - regex helpers

    private static func remove(pattern: String, from html: String) -> String {
        html.replacingOccurrences(of: pattern, with: " ",
                                  options: [.regularExpression, .caseInsensitive])
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        matches(in: text, pattern: pattern).first
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators,
                                                             .caseInsensitive])
        else { return [] }
        return regex
            .matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            .compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
    }
}
