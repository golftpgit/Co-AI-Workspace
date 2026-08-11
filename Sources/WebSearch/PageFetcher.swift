import Foundation
import PDFKit
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// `fetch_page` (ARCHITECTURE §1.4, P3.4).
//
// The rule this implements: **search results are not evidence**. A snippet is
// a few words a search engine chose, out of context, and a system that cites
// them is quoting a summary of a summary. Anything worth citing gets read.
//
// What comes back carries its tier from the source registry and its text as
// paragraphs, so a citation can point at the paragraph it came from rather
// than at a URL.
// ─────────────────────────────────────────────────────────────

public struct FetchedPage: Sendable {
    public let url: URL
    /// After redirects — what was actually read, which is what a citation has
    /// to name.
    public let finalURL: URL
    public let title: String?
    public let paragraphs: [String]
    public let provenance: Provenance
    public let contentType: String
    public var text: String { paragraphs.joined(separator: "\n\n") }

    /// Public so a cached page, an archived one, or a stub can stand in for a
    /// live fetch — the `PageReading` seam is worth nothing if only this file
    /// can produce its result type.
    public init(url: URL, finalURL: URL, title: String?, paragraphs: [String],
                provenance: Provenance, contentType: String) {
        self.url = url
        self.finalURL = finalURL
        self.title = title
        self.paragraphs = paragraphs
        self.provenance = provenance
        self.contentType = contentType
    }
}

public enum FetchError: Error, CustomStringConvertible, Equatable {
    case invalidURL(String)
    case blockedScheme(String)
    case http(status: Int, url: String)
    case tooLarge(bytes: Int, limit: Int)
    case unsupportedContent(String)
    case empty(url: String)
    /// The page's text is not in the HTML the server sent. Named separately
    /// from `empty` because the answer is different: nothing is wrong with the
    /// fetch, and retrying will not help.
    case needsJavaScript(url: String)
    case transport(String)

    public var description: String {
        switch self {
        case .invalidURL(let url): "ที่อยู่ไม่ถูกต้อง: \(url)"
        case .blockedScheme(let scheme): "ไม่รองรับ scheme: \(scheme)"
        case .http(let status, let url): "http \(status): \(url)"
        case .tooLarge(let bytes, let limit): "หน้าใหญ่เกินไป (\(bytes) > \(limit) ไบต์)"
        case .unsupportedContent(let type): "อ่านเนื้อหาแบบนี้ไม่ได้: \(type)"
        case .empty(let url): "อ่านหน้าแล้วไม่พบข้อความ: \(url)"
        case .needsJavaScript(let url):
            "หน้านี้สร้างเนื้อหาด้วย JavaScript — HTML ที่เซิร์ฟเวอร์ส่งมาไม่มีข้อความ: \(url)"
        case .transport(let message): "ต่อไม่ได้: \(message.prefix(120))"
        }
    }
}

public struct PageFetcher: Sendable {
    private let registry: SourceRegistry
    private let readability: Readability
    private let byteLimit: Int
    private let timeout: TimeInterval

    public init(registry: SourceRegistry = SourceRegistry(),
                readability: Readability = Readability(),
                byteLimit: Int = 8 * 1_024 * 1_024,
                timeout: TimeInterval = 30) {
        self.registry = registry
        self.readability = readability
        self.byteLimit = byteLimit
        self.timeout = timeout
    }

    public func fetch(_ address: String) async throws -> FetchedPage {
        guard let url = URL(string: address), url.host() != nil else {
            throw FetchError.invalidURL(address)
        }
        return try await fetch(url)
    }

    public func fetch(_ url: URL) async throws -> FetchedPage {
        // http(s) only. `file:` would turn a tool that reads the web into one
        // that reads the disk, which is a different permission entirely.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw FetchError.blockedScheme(url.scheme ?? "none")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh) CoAIWorkspace/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.transport("\(error)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.http(status: http.statusCode, url: url.absoluteString)
        }
        guard data.count <= byteLimit else {
            throw FetchError.tooLarge(bytes: data.count, limit: byteLimit)
        }

        let finalURL = http.url ?? url
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()

        let extracted: ExtractedPage
        if contentType.contains("pdf") || finalURL.pathExtension.lowercased() == "pdf" {
            extracted = try Self.readPDF(data, url: finalURL)
        } else if contentType.contains("text/plain") {
            // RFCs, changelogs, robots.txt, raw source. Running these through
            // an HTML extractor finds no tags and returns nothing at all.
            extracted = Self.readPlainText(Self.decode(data, contentType: contentType),
                                           url: finalURL)
        } else if contentType.isEmpty || contentType.contains("html")
                    || contentType.contains("xml") || contentType.contains("text") {
            let html = Self.decode(data, contentType: contentType)
            extracted = readability.extract(html: html)
            if extracted.isEmpty, Self.looksJavaScriptRendered(html) {
                throw FetchError.needsJavaScript(url: finalURL.absoluteString)
            }
        } else {
            throw FetchError.unsupportedContent(contentType)
        }

        guard !extracted.isEmpty else { throw FetchError.empty(url: finalURL.absoluteString) }

        // Tier comes from the registry, and from the URL that was actually
        // read: a redirect off a T1 domain onto someone's blog is a T5 page.
        let provenance = Provenance(
            documentID: "web_" + IngestionPipeline.contentHash(finalURL.absoluteString).prefix(16),
            title: extracted.title ?? finalURL.host() ?? finalURL.absoluteString,
            origin: .web(url: finalURL),
            tier: registry.tier(for: finalURL),
            accessedAt: Date())

        return FetchedPage(url: url, finalURL: finalURL, title: extracted.title,
                           paragraphs: extracted.paragraphs, provenance: provenance,
                           contentType: contentType)
    }

    // MARK: -

    /// Blank lines are the paragraph breaks in a plain-text document; single
    /// newlines are wrapping, and splitting on them would shred every sentence.
    private static func readPlainText(_ text: String, url: URL) -> ExtractedPage {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { block in
                block.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { $0.count >= 40 }
        return ExtractedPage(title: url.lastPathComponent, paragraphs: paragraphs)
    }

    /// A page whose HTML is mostly an empty root element and a bundle. Worth
    /// naming: the fetch worked, the server simply did not send any text, and
    /// the caller needs to know that rather than treating it as a thin page.
    ///
    /// Only fires when extraction found *nothing*. A page that renders a menu
    /// server-side and its article in JavaScript comes back thin instead —
    /// swift.org does exactly this. Widening the check to catch it would mean
    /// guessing that a short page is broken, which is worse.
    static func looksJavaScriptRendered(_ html: String) -> Bool {
        guard html.count > 1_000 else { return false }
        let markers = ["<div id=\"root\"", "<div id=\"app\"", "__NEXT_DATA__",
                       "data-reactroot", "ng-app", "<astro-island", "window.__NUXT__"]
        return markers.contains { html.contains($0) }
    }

    private static func readPDF(_ data: Data, url: URL) throws -> ExtractedPage {
        guard let document = PDFDocument(data: data) else {
            throw FetchError.unsupportedContent("pdf (unreadable)")
        }
        // One paragraph per page rather than per blank line: a PDF's line
        // breaks are layout, and splitting on them shreds sentences.
        var pages: [String] = []
        for number in 0..<document.pageCount {
            let text = (document.page(at: number)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pages.append(text) }
        }
        return ExtractedPage(title: document.documentAttributes?[PDFDocumentAttribute.titleAttribute]
                                as? String ?? url.lastPathComponent,
                             paragraphs: pages)
    }

    /// Honours the charset the server declared before falling back to UTF-8.
    /// Thai pages served as TIS-620 are mojibake otherwise, and mojibake is
    /// worse than a failure because it gets indexed.
    private static func decode(_ data: Data, contentType: String) -> String {
        if let range = contentType.range(of: "charset=") {
            let name = contentType[range.upperBound...]
                .prefix { !" ;\"".contains($0) }
            let encoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding(String(name) as CFString))
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
