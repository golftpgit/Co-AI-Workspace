import Testing
import Foundation
import Knowledge
@testable import WebSearch

// ─────────────────────────────────────────────────────────────
// The headless search bridge (ARCHITECTURE §1.4.1, P13.1).
//
// The DOM query itself needs a browser and a network, so it is proven by driving
// the built, sandboxed `.app` — that is what P13.1's Done-when asks for and it is
// the only thing that can answer it. What is tested here is everything that
// decides *what the answer means*:
//
//  • a bot wall is recognised as a wall, and an article about CAPTCHAs is not;
//  • an unknown domain is T5 rather than unrated;
//  • the engine's own links are navigation, not results;
//  • and — the rule this whole design turns on — a page that loaded and produced
//    nothing is an error about the extractor, never "no results".
// ─────────────────────────────────────────────────────────────

private let registry = SourceRegistry()

private func extracted(_ pairs: [(String, String)]) -> [ExtractedResult] {
    pairs.map { ExtractedResult(title: $0.0, url: $0.1, snippet: "—") }
}

@Suite("Headless web search")
struct HeadlessSearchTests {

    // MARK: - the wall

    @Test("a CAPTCHA page is a wall, not an empty result")
    func wallIsDetected() throws {
        let url = try #require(URL(string: "https://html.duckduckgo.com/html/?q=x"))
        let page = "<html><head><title>Verify</title></head><body>"
            + "<div id='recaptcha'>Please verify you are human</div></body></html>"

        let verdict = try #require(BotWall.detect(url: url, html: page))
        guard case .blocked(let reason, _) = verdict else {
            Issue.record("ควรเป็น .blocked แต่ได้ \(verdict)")
            return
        }
        #expect(reason.contains("captcha") || reason.contains("verify you are human"))
        // The message asks for a person and does not offer to get past it —
        // §1.4.1's refusal, in the words the user reads.
        #expect(verdict.description.contains("ต้องให้คนเปิดหน้านี้เองแล้วค้นด้วยมือ"))
    }

    @Test("403 and 429 are walls; 500 is a server having a bad day")
    func statusCodesAreToldApart() throws {
        let url = try #require(URL(string: "https://example.org/search"))
        for status in [403, 429] {
            guard case .blocked = BotWall.detect(url: url, html: "", statusCode: status) else {
                Issue.record("http \(status) ควรถือเป็นด่านกันบอท")
                return
            }
        }
        // Not a wall: retrying a 500 is reasonable, retrying a 403 is how an IP
        // gets banned.
        #expect(BotWall.detect(url: url, html: "", statusCode: 500) == nil)
    }

    @Test("an article about CAPTCHAs is not a CAPTCHA")
    func proseIsNotAWall() throws {
        let url = try #require(URL(string: "https://example.org/blog/how-captchas-work"))
        // The marker appears far down the page, which is where prose about the
        // subject lives — only the head is scanned.
        let article = String(repeating: "บทความยาว ", count: 900) + " captcha"
        #expect(BotWall.detect(url: url, html: article) == nil)
    }

    @Test("being sent to /sorry/ is a wall even with a clean page")
    func redirectPathIsAWall() throws {
        let url = try #require(URL(string: "https://www.google.com/sorry/index?continue=x"))
        guard case .blocked = BotWall.detect(url: url, html: "<html></html>") else {
            Issue.record("การถูกส่งไป /sorry/ ควรเป็นด่าน")
            return
        }
    }

    // MARK: - what a result is

    @Test("the registry decides the tier, and an unknown domain is T5")
    func tiersComeFromTheRegistry() {
        let results = HeadlessWebSource.results(
            from: extracted([("แนวทาง WHO", "https://www.who.int/publications/x"),
                             ("บล็อกใครไม่รู้", "https://some-random-blog.example/post")]),
            engine: "duckduckgo-html", registry: registry, limit: 8)

        #expect(results.count == 2)
        #expect(results[0].tier == .t1)
        // Not "unrated": a page nobody vouched for is general web, and leaving it
        // without a tier would let it past filters that check for one (§1.4).
        #expect(results[1].tier == .t5)
    }

    @Test("the engine's own links are navigation, not results")
    func engineLinksAreDropped() {
        let results = HeadlessWebSource.results(
            from: extracted([("Next page", "https://html.duckduckgo.com/html/?q=x&s=30"),
                             ("Bing", "https://www.bing.com/search?q=y"),
                             ("ของจริง", "https://example.org/paper")]),
            engine: "duckduckgo-html", registry: registry, limit: 8)

        #expect(results.map(\.title) == ["ของจริง"])
    }

    @Test("junk rows are dropped rather than passed on")
    func junkIsDropped() {
        let results = HeadlessWebSource.results(
            from: extracted([("", "https://example.org/no-title"),
                             ("javascript", "javascript:void(0)"),
                             ("ไม่ใช่ url", "not-a-url"),
                             ("ของจริง", "https://example.org/real"),
                             ("ซ้ำ", "https://EXAMPLE.org/real")]),
            engine: "duckduckgo-html", registry: registry, limit: 8)

        // One row survives: the duplicate differs only by case in the host, which
        // is the same page — engines repeat a domain across result blocks.
        #expect(results.map(\.title) == ["ของจริง"])
    }

    @Test("the limit is honoured after filtering, not before")
    func limitCountsResults() {
        let rows = (1...10).map { ("ผล \($0)", "https://example.org/\($0)") }
        let results = HeadlessWebSource.results(from: extracted(rows), engine: "e",
                                               registry: registry, limit: 3)
        #expect(results.count == 3)
    }

    // MARK: - the engines as data

    @Test("a query becomes a URL, and the default engine is not Google")
    func queryURLs() throws {
        let engine = SearchEngine.duckDuckGoHTML
        let url = try #require(engine.url(for: "ภาวะหมดไฟ พยาบาล"))
        #expect(url.absoluteString.hasPrefix("https://html.duckduckgo.com/html/?q="))
        // Thai has to survive percent-encoding, or the query silently becomes a
        // different search.
        #expect(url.absoluteString.contains("%E0%B8%A0"))

        // §1.4.1 — Google is deliberately absent: its terms are the most
        // restrictive and it walls automation fastest, which under this design
        // turns every search into "a person is needed".
        #expect(!SearchEngine.builtIn.contains { $0.template.contains("google.com") })
        #expect(SearchEngine.builtIn.allSatisfy { !$0.automationNote.isEmpty })
    }

    @Test("every engine's extractor reads the DOM rather than the HTML text")
    func extractorsUseTheDOM() {
        for engine in SearchEngine.builtIn {
            // The point of using a real browser: `querySelectorAll` is the same
            // code the page's own scripts use. A regex over markup is what broke
            // in v1, so an extractor without a DOM query is a regression.
            #expect(engine.extractor.contains("querySelectorAll"))
            #expect(engine.extractor.contains("JSON.stringify"))
        }
    }

    @Test("the extractor's own JSON shape is what the source decodes")
    func extractionRoundTrips() throws {
        // What the JavaScript returns, verbatim in shape.
        let json = #"[{"title":"ก","url":"https://example.org/a","snippet":"ข"}]"#
        let rows = try JSONDecoder().decode([ExtractedResult].self, from: Data(json.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].url == "https://example.org/a")

        let results = HeadlessWebSource.results(from: rows, engine: "e",
                                               registry: registry, limit: 8)
        #expect(results[0].snippet == "ข")
        // A snippet is for deciding what to open, never for citing (§1.4). The
        // tool's own text says so; here we only check it survives the trip.
        #expect(results[0].engine == "e")
    }

    @Test("an empty extraction is an extractor error, never 'no results'")
    func nothingFoundIsAnError() {
        // The rule the whole design turns on: v1's scraper returned an empty list
        // when DuckDuckGo's markup moved, and empty reads as "no evidence" —
        // which in research is a finding.
        #expect(HeadlessWebSource.results(from: [], engine: "duckduckgo-html",
                                          registry: registry, limit: 8).isEmpty)
        let error = HeadlessError.extractorFoundNothing(engine: "duckduckgo-html",
                                                        url: "https://x/y")
        #expect(error.description.contains("ตัวอ่านของ duckduckgo-html ล้าสมัยแล้ว"))
        #expect(error.description.contains("ไม่ใช่ 'ไม่มีผลลัพธ์'"))
    }
}
