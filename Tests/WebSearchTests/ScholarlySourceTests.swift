import Testing
import Foundation
import Knowledge
@testable import WebSearch

// ─────────────────────────────────────────────────────────────
// P3.3's Done-when: "คืนผลพร้อม {tier, url, accessedAt} ครบทุกแถว".
//
// The live half is opt-in (COAI_TEST_NETWORK=1) — these APIs are somebody
// else's service and a suite that needs them fails offline.
// ─────────────────────────────────────────────────────────────

private let networkTestsEnabled = ProcessInfo.processInfo.environment["COAI_TEST_NETWORK"] == "1"

@Suite("Scholarly sources")
struct ScholarlySourceTests {
    @Test("a record carries everything a citation needs")
    func recordIsCitable() {
        let url = URL(string: "https://doi.org/10.1056/nejm199309303291401")!
        let record = ScholarlyRecord(
            title: "The Effect of Intensive Treatment of Diabetes",
            authors: ["DCCT Research Group"], year: 1993,
            doi: "10.1056/nejm199309303291401", url: url, abstract: nil,
            foundVia: "OpenAlex", tier: .t2, accessedAt: Date())

        let provenance = record.provenance
        #expect(provenance.tier == .t2)
        #expect(provenance.origin == .web(url: url))
        #expect(provenance.year == 1993)
        #expect(provenance.authors == ["DCCT Research Group"])
    }

    @Test("medRxiv refuses a keyword search instead of returning noise")
    func medRxivHasNoKeywordSearch() async {
        // Checked against the live service: the bioRxiv/medRxiv API answers by
        // DOI or date only. Returning the newest preprints for any question
        // would look like a search and be noise.
        await #expect(throws: ScholarlyError.self) {
            _ = try await MedRxivSource().search("insulin", limit: 5)
        }
    }
}

@Suite("Scholarly sources over the real APIs", .serialized,
       .enabled(if: networkTestsEnabled, "set COAI_TEST_NETWORK=1"))
struct LiveScholarlySourceTests {
    private func check(_ records: [ScholarlyRecord], api: String) {
        #expect(!records.isEmpty, "\(api) returned nothing")
        for record in records {
            #expect(!record.title.isEmpty, "\(api): a record with no title")
            #expect(record.url.host() != nil, "\(api): a record with no usable URL")
            #expect(record.accessedAt.timeIntervalSinceNow > -300,
                    "\(api): accessedAt was not set")
            #expect(record.foundVia == api)
        }
    }

    @Test("OpenAlex", .timeLimit(.minutes(2)))
    func openAlex() async throws {
        let records = try await OpenAlexSource().search("insulin diabetes", limit: 5)
        check(records, api: "OpenAlex")
        // Resolving to a DOI is what makes the result citable rather than a
        // pointer at an API record.
        #expect(records.contains { $0.doi != nil })
        // A doi.org link is a redirector with no editorial identity; without
        // handling that, a peer-reviewed paper is rated the same as a blog.
        #expect(records.allSatisfy { $0.tier <= .t2 },
                "tiers: \(records.map(\.tier))")
    }

    @Test("Crossref", .timeLimit(.minutes(2)))
    func crossref() async throws {
        let records = try await CrossrefSource().search("insulin therapy", limit: 5)
        check(records, api: "Crossref")
        #expect(records.allSatisfy { $0.doi != nil })
        #expect(records.allSatisfy { $0.tier <= .t2 }, "tiers: \(records.map(\.tier))")
    }

    @Test("PubMed", .timeLimit(.minutes(3)))
    func pubMed() async throws {
        let records = try await PubMedSource().search("insulin resistance", limit: 5)
        check(records, api: "PubMed")
        // PubMed is in the registry as T2; a paper found there should say so.
        #expect(records.allSatisfy { $0.tier == .t2 })
        #expect(records.contains { !$0.authors.isEmpty })
        #expect(records.contains { $0.year != nil })
    }

    @Test("medRxiv by DOI", .timeLimit(.minutes(2)))
    func medRxivByDOI() async throws {
        let record = try await MedRxivSource().record(doi: "10.1101/2020.09.09.20191205")
        let found = try #require(record)
        #expect(!found.title.isEmpty)
        // A preprint stays T3 wherever it was found: being listed by an index
        // is not review.
        #expect(found.tier == .t3, "a preprint is not peer reviewed")
        #expect(found.year == 2020)
    }

    @Test("Semantic Scholar, when it lets us in", .timeLimit(.minutes(2)))
    func semanticScholar() async throws {
        // Rate limited for anonymous callers — 429 on the first request from
        // this machine. That is the service's answer, not a failure of ours,
        // and it has to be distinguishable from "no results".
        do {
            check(try await SemanticScholarSource().search("insulin", limit: 5),
                  api: "Semantic Scholar")
        } catch ScholarlyError.rateLimited {
            #expect(Bool(true), "rate limited, as expected without a key")
        }
    }
}
