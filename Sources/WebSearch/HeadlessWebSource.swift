import Foundation
import Knowledge
import Observability

// ─────────────────────────────────────────────────────────────
// T5 search through the app's own browser (ARCHITECTURE §1.4.1, P13.1).
//
// The engine is described by a value: how to build its query URL, and a piece of
// JavaScript that reads its result list out of the DOM. Two consequences worth
// having:
//
//  • **The DOM does the parsing.** v1 scraped DuckDuckGo's HTML with regexes and
//    broke every time the markup moved. `document.querySelectorAll` is the same
//    code the page's own scripts use, and when it does find nothing that is
//    reported as a stale extractor rather than as "no results" (§1.4.1).
//  • **Adding an engine is a value, not a subclass.** Which matters because
//    which engines permit this is a policy decision that will change, and
//    §1.4 already says the default must not be Google.
//
// Everything after extraction is the path that already existed: results carry a
// tier from the source registry, and nothing is citable until `fetch_page` has
// read the page itself (§1.4).
// ─────────────────────────────────────────────────────────────

/// One search engine, as data.
public struct SearchEngine: Sendable, Equatable {
    public let name: String
    /// Where the query goes. A closure would be neater and is not `Equatable`,
    /// so this is a template with `{q}` in it.
    public let template: String
    /// Reads the result list from the loaded page and returns JSON. Must produce
    /// `[{"title": …, "url": …, "snippet": …}]` as a *string*, because that is
    /// what `evaluateJavaScript` can hand back losslessly.
    public let extractor: String
    /// Whether this engine's terms allow automated queries as far as we know, in
    /// its own words. Shown on screen: which engines permit this is the user's
    /// decision to make, not ours to bury (§1.4.1).
    public let automationNote: String

    public init(name: String, template: String, extractor: String, automationNote: String) {
        self.name = name
        self.template = template
        self.extractor = extractor
        self.automationNote = automationNote
    }

    public func url(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: template.replacingOccurrences(of: "{q}", with: encoded))
    }

    /// A shared extractor body: take a container selector, a link selector and a
    /// snippet selector, and return the JSON string the source decodes.
    static func extractor(rows: String, link: String, snippet: String) -> String {
        """
        (function () {
          var out = [];
          var rows = document.querySelectorAll('\(rows)');
          for (var i = 0; i < rows.length; i++) {
            var a = rows[i].querySelector('\(link)');
            if (!a || !a.href) { continue; }
            var s = rows[i].querySelector('\(snippet)');
            out.push({
              title: (a.innerText || a.textContent || '').trim(),
              url: a.href,
              snippet: s ? (s.innerText || s.textContent || '').trim() : ''
            });
          }
          return JSON.stringify(out);
        })();
        """
    }

    /// DuckDuckGo's no-JavaScript endpoint. The default because it is the one
    /// this project already decided was acceptable to read directly (§1.4's
    /// fallback), and because a server-rendered page has no client-side
    /// rendering to wait for.
    public static let duckDuckGoHTML = SearchEngine(
        name: "duckduckgo-html",
        template: "https://html.duckduckgo.com/html/?q={q}",
        extractor: extractor(rows: ".result, .web-result",
                             link: "a.result__a",
                             snippet: ".result__snippet"),
        automationNote: "หน้า html ที่ DDG ทำไว้ให้ไคลเอนต์ไม่มี JS — โปรเจกต์นี้เลือกไว้แต่เดิมเป็นทางสำรอง (§1.4)")

    /// Bing, as a second opinion. Kept because one engine's index is one
    /// engine's opinion, and §1.4's corroboration rule needs more than one.
    public static let bing = SearchEngine(
        name: "bing",
        template: "https://www.bing.com/search?q={q}&setlang=th",
        extractor: extractor(rows: "li.b_algo", link: "h2 a", snippet: ".b_caption p"),
        automationNote: "ต้องดูเงื่อนไขการใช้งานของ Bing เอง — ค่าเริ่มต้นของระบบไม่ได้เปิดไว้")

    /// Deliberately not Google (§1.4.1): its terms are the most restrictive and
    /// it is the fastest to serve a CAPTCHA, which under this design means every
    /// search ends in "a person is needed".
    public static let builtIn: [SearchEngine] = [.duckDuckGoHTML, .bing]
}

/// What the extractor returns, before it becomes a `WebResult`.
struct ExtractedResult: Decodable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

/// Search over the open web, through the app's own web view.
public actor HeadlessWebSource: WebSearching {
    public let name: String
    private let engine: SearchEngine
    private let browser: HeadlessBrowser
    private let registry: SourceRegistry
    private let log = AppLog.logger("headless-search")
    /// One search per query per session. Repeating a search inside a minute is
    /// almost always the app asking twice, and the engines count it as traffic.
    private var cache: [String: [WebResult]] = [:]

    public init(engine: SearchEngine = .duckDuckGoHTML,
                browser: HeadlessBrowser,
                registry: SourceRegistry = SourceRegistry()) {
        self.engine = engine
        self.browser = browser
        self.registry = registry
        name = engine.name
    }

    public func search(_ query: String, limit: Int = 8) async throws -> [WebResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let cached = cache[trimmed] { return Array(cached.prefix(limit)) }
        guard let url = engine.url(for: trimmed) else {
            throw HeadlessError.notAvailable("สร้าง URL ค้นหาไม่ได้")
        }

        await browser.clearSession()
        let page = try await browser.page(url)
        let json = try await browser.evaluateJSON(engine.extractor)
        let extracted = (try? JSONDecoder().decode([ExtractedResult].self, from: json)) ?? []

        let results = Self.results(from: extracted, engine: engine.name,
                                   registry: registry, limit: limit)
        guard !results.isEmpty else {
            // Loaded fine and produced nothing: the markup moved. Never reported
            // as "no results" — that is the failure §1.4.1 is most emphatic about.
            throw HeadlessError.extractorFoundNothing(engine: engine.name,
                                                      url: page.finalURL.absoluteString)
        }
        log.info("\(results.count, privacy: .public) results from \(self.engine.name, privacy: .public)")
        cache[trimmed] = results
        return results
    }

    /// Extraction output → results. Pure and internal so the whole of the
    /// interesting behaviour — tiering, deduplication, rejecting junk — is
    /// testable without a browser.
    static func results(from extracted: [ExtractedResult], engine: String,
                        registry: SourceRegistry, limit: Int,
                        now: Date = Date()) -> [WebResult] {
        var seen = Set<String>()
        var out: [WebResult] = []
        for row in extracted {
            guard let url = URL(string: row.url),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = url.host()?.lowercased() else { continue }
            // The engine's own pages are navigation, not results.
            if host.contains("duckduckgo.com") || host.contains("bing.com") { continue }
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            // Same page twice — engines repeat a domain across result blocks.
            let key = url.absoluteString.lowercased()
            guard seen.insert(key).inserted else { continue }

            out.append(WebResult(title: title,
                                 url: url,
                                 snippet: row.snippet,
                                 engine: engine,
                                 // The registry decides the tier, and an unknown
                                 // domain is T5 rather than "unrated" — an
                                 // unrated page would slip past filters that
                                 // check for a tier (§1.4).
                                 tier: registry.tier(for: url),
                                 accessedAt: now))
            if out.count == limit { break }
        }
        return out
    }
}

/// Reading one page with the browser, as `fetch_page` and `ingest_url` already
/// know how to (§1.4.1).
///
/// This is the half of the idea that pays for itself: `PageFetcher` reads what
/// the server sent, and the most common failure it reports — `FetchError.empty` —
/// is a page whose text is produced by JavaScript. Because the reader is a
/// protocol, the whole citation and ingestion path gets a browser without any of
/// it changing. Falls back to the plain fetcher on anything that is not HTML: a
/// PDF does not need a DOM, and `PageFetcher` already reads those properly.
public struct HeadlessPageReader: PageReading {
    private let browser: HeadlessBrowser
    private let readability: Readability
    private let registry: SourceRegistry
    private let plain: PageFetcher

    public init(browser: HeadlessBrowser,
                readability: Readability = Readability(),
                registry: SourceRegistry = SourceRegistry(),
                plain: PageFetcher = PageFetcher()) {
        self.browser = browser
        self.readability = readability
        self.registry = registry
        self.plain = plain
    }

    public func fetch(_ url: URL) async throws -> FetchedPage {
        // PDFs and other non-HTML: the browser would render a viewer, and there
        // is no DOM worth reading in it.
        if url.pathExtension.lowercased() == "pdf" {
            return try await plain.fetch(url)
        }
        let page = try await browser.page(url)
        let extracted = readability.extract(html: page.html)
        guard !extracted.isEmpty else {
            // Rendered and still nothing: that is a real empty page, and saying
            // so is different from saying the fetch failed.
            throw FetchError.empty(url: page.finalURL.absoluteString)
        }
        // The same provenance `PageFetcher` writes, including the document id
        // derived from the final URL — so a page read through the browser and one
        // read through URLSession are the same row to the knowledge base.
        let provenance = Provenance(
            documentID: "web_" + IngestionPipeline.contentHash(page.finalURL.absoluteString).prefix(16),
            title: extracted.title ?? page.finalURL.host() ?? page.finalURL.absoluteString,
            origin: .web(url: page.finalURL),
            tier: registry.tier(for: page.finalURL),
            accessedAt: Date())
        return FetchedPage(url: url,
                           finalURL: page.finalURL,
                           title: extracted.title,
                           paragraphs: extracted.paragraphs,
                           provenance: provenance,
                           contentType: "text/html")
    }
}
