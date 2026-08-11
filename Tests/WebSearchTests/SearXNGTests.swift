import Testing
import Foundation
import Knowledge
@testable import WebSearch

// ─────────────────────────────────────────────────────────────
// P3.1: the meta-search sidecar. Live tests need it running —
// `scripts/run-searxng.sh` — and are opt-in like the rest of the network
// suites.
// ─────────────────────────────────────────────────────────────

private let networkTestsEnabled = ProcessInfo.processInfo.environment["COAI_TEST_NETWORK"] == "1"

@Suite("SearXNG")
struct SearXNGTests {
    @Test("an instance that is not there is reported, not treated as no results")
    func missingInstanceIsAnError() async {
        let source = SearXNGSource(baseURL: URL(string: "http://127.0.0.1:9")!, timeout: 3)
        #expect(await source.isAvailable() == false)
        // "Search returned nothing" and "search is down" lead to different
        // decisions, so they must not look alike.
        await #expect(throws: WebSearchError.self) { _ = try await source.search("x") }
    }
}

@Suite("SearXNG against the running sidecar", .serialized,
       .enabled(if: networkTestsEnabled, "set COAI_TEST_NETWORK=1 and run scripts/run-searxng.sh"))
struct LiveSearXNGTests {
    @Test("a search comes back with results that can be opened and rated",
          .timeLimit(.minutes(2)))
    func searchReturnsUsableResults() async throws {
        let source = SearXNGSource()
        guard await source.isAvailable() else {
            Issue.record("skipped: no SearXNG on :18080 — run scripts/run-searxng.sh")
            return
        }

        let results = try await source.search("insulin diabetes treatment", limit: 8)
        #expect(!results.isEmpty)
        for result in results {
            #expect(!result.title.isEmpty)
            #expect(result.url.host() != nil)
            #expect(result.accessedAt.timeIntervalSinceNow > -300)
        }
    }

    @Test("a known publisher keeps its tier when found through meta-search",
          .timeLimit(.minutes(2)))
    func tierComesFromThePublisher() async throws {
        let source = SearXNGSource()
        guard await source.isAvailable() else {
            Issue.record("skipped: no SearXNG on :18080")
            return
        }

        // Whoever found the page does not change what it is worth: a WHO page
        // is T1 whether it arrived from an API or from a meta-search.
        let results = try await source.search("site:who.int diabetes fact sheet", limit: 10)
        let whoResults = results.filter { $0.url.host()?.contains("who.int") == true }
        if whoResults.isEmpty {
            Issue.record("note: no who.int results this run — engines vary by the minute")
        } else {
            #expect(whoResults.allSatisfy { $0.tier == .t1 })
        }
    }

    @Test("Thai queries work, which is most of what this system searches",
          .timeLimit(.minutes(2)))
    func thaiQueryWorks() async throws {
        let source = SearXNGSource()
        guard await source.isAvailable() else {
            Issue.record("skipped: no SearXNG on :18080")
            return
        }
        let results = try await source.search("โรคเบาหวาน การรักษา", limit: 5)
        #expect(!results.isEmpty)
    }
}
