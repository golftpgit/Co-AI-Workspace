import Testing
import Foundation
import Knowledge
@testable import WebSearch

// ─────────────────────────────────────────────────────────────
// P3.4's Done-when: "อ่านหน้าจริงได้ ≥5 เว็บที่โครงสร้างต่างกัน" — which can
// only be checked against the real web.
//
// Opt-in, because a suite that reaches the network fails on a train:
//
//     COAI_TEST_NETWORK=1 swift test
//
// The offline half — what the extractor does with the pages real sites serve —
// is in ReadabilityTests and always runs.
// ─────────────────────────────────────────────────────────────

private let networkTestsEnabled = ProcessInfo.processInfo.environment["COAI_TEST_NETWORK"] == "1"

@Suite("Page fetcher", .serialized)
struct PageFetcherTests {
    @Test("only http(s) — this reads the web, not the disk")
    func fileURLsAreRefused() async {
        // A web-reading tool that will open file:// is a different permission
        // than the one the user granted.
        await #expect(throws: FetchError.self) {
            _ = try await PageFetcher().fetch("file:///etc/passwd")
        }
        await #expect(throws: FetchError.self) {
            _ = try await PageFetcher().fetch("not a url")
        }
    }

    @Test("an empty single-page-app shell is named, not reported as thin")
    func javaScriptShellIsDetected() {
        // Deterministic, because asserting this against a live site means
        // re-testing someone else's deploy every run.
        let shell = "<html><head><title>App</title></head><body><div id=\"root\"></div>"
            + String(repeating: "<script src=/bundle.js></script>", count: 40) + "</body></html>"
        #expect(PageFetcher.looksJavaScriptRendered(shell))

        // A short but real page is not a broken one.
        let thin = "<html><body><p>" + String(repeating: "ก", count: 60) + "</p></body></html>"
        #expect(PageFetcher.looksJavaScriptRendered(thin) == false)
    }

    @Test("a dead host fails with something readable")
    func deadHostFails() async {
        await #expect(throws: FetchError.self) {
            _ = try await PageFetcher(timeout: 3).fetch("http://127.0.0.1:9/page")
        }
    }
}

@Suite("Page fetcher over the real web", .serialized,
       .enabled(if: networkTestsEnabled, "set COAI_TEST_NETWORK=1"))
struct LivePageFetcherTests {
    /// Five sites built nothing like each other: a plain-text RFC, a wiki, a
    /// preprint server, a documentation site, and a health authority.
    ///
    /// `swift.org` was in this list and was removed rather than accommodated:
    /// its pages are rendered by JavaScript, so the HTML a server sends
    /// contains no article at all. That is a limitation of reading the web
    /// without a browser, not a page worth tuning an extractor against — the
    /// fetcher now reports it as such (`needsJavaScript`).
    private static let pages: [(name: String, url: String, expectedTier: SourceTier)] = [
        ("IETF RFC (text/plain)", "https://www.ietf.org/rfc/rfc2616.txt", .t1),
        ("Wikipedia", "https://en.wikipedia.org/wiki/Insulin", .t4),
        ("arXiv abstract", "https://arxiv.org/abs/1706.03762", .t3),
        ("MDN", "https://developer.mozilla.org/en-US/docs/Web/HTTP", .t5),
        ("WHO", "https://www.who.int/news-room/fact-sheets/detail/diabetes", .t1),
    ]

    @Test("five differently-built pages all come back as readable text",
          .timeLimit(.minutes(5)))
    func readsFiveRealSites() async throws {
        let fetcher = PageFetcher()
        var succeeded: [String] = []
        var failed: [String] = []

        for page in Self.pages {
            do {
                let fetched = try await fetcher.fetch(page.url)
                guard fetched.paragraphs.count >= 3, fetched.text.count >= 400 else {
                    failed.append("\(page.name): only \(fetched.paragraphs.count) paragraphs")
                    continue
                }
                // The tier travels with the page, from the registry — that is
                // what makes a citation say how much it is worth.
                guard fetched.provenance.tier == page.expectedTier else {
                    failed.append("\(page.name): tier \(String(describing: fetched.provenance.tier))")
                    continue
                }
                succeeded.append("\(page.name) (\(fetched.paragraphs.count) ย่อหน้า)")
            } catch {
                failed.append("\(page.name): \(error)")
            }
        }

        #expect(failed.isEmpty, "failed: \(failed.joined(separator: " | "))")
        #expect(succeeded.count == 5, "read: \(succeeded.joined(separator: " | "))")
    }

    @Test("a PDF link is read as text, not refused", .timeLimit(.minutes(3)))
    func readsAPDF() async throws {
        // Linked PDFs are most of the primary literature; a fetcher that only
        // does HTML cannot cite a paper.
        let fetched = try await PageFetcher().fetch("https://arxiv.org/pdf/1706.03762")
        #expect(fetched.paragraphs.count >= 1)
        #expect(fetched.text.count > 1_000)
        #expect(fetched.provenance.tier == .t3)
    }

    @Test("what gets cited is the page that was actually read",
          .timeLimit(.minutes(3)))
    func redirectsAreFollowedAndRecorded() async throws {
        // http → https and bare-domain → www are redirects; a citation naming
        // the URL we asked for rather than the one we got is wrong.
        let fetched = try await PageFetcher().fetch("http://who.int/")
        #expect(fetched.finalURL.absoluteString != fetched.url.absoluteString)
        #expect(fetched.provenance.origin == .web(url: fetched.finalURL))
    }
}
