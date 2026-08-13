import Testing
import Foundation
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P3.2's Done-when: "เพิ่มแหล่งใหม่ 1 แถว → agent ใช้ทันทีโดยไม่ recompile".
// ─────────────────────────────────────────────────────────────

@Suite("Source registry")
struct SourceRegistryTests {
    @Test("a URL gets the tier of whoever published it")
    func tierComesFromTheDomain() {
        let registry = SourceRegistry()

        #expect(registry.tier(for: URL(string: "https://www.who.int/news/item/x")!) == .t1)
        #expect(registry.tier(for: URL(string: "https://arxiv.org/abs/2401.00001")!) == .t3)
        #expect(registry.tier(for: URL(string: "https://en.wikipedia.org/wiki/Insulin")!) == .t4)
    }

    @Test("an unknown domain is general web, not unrated")
    func unknownDomainsAreT5() {
        // Not `nil`: a page nobody vouched for is T5, and leaving it unrated
        // would let it past a filter that checks a tier exists.
        #expect(SourceRegistry().tier(for: URL(string: "https://some-blog.example/post")!) == .t5)
    }

    @Test("a lookalike domain does not inherit a tier")
    func lookalikeDomainsDoNotMatch() {
        let registry = SourceRegistry()
        // Suffix matching on the raw string would hand this T1.
        #expect(registry.tier(for: URL(string: "https://notwho.int/page")!) == .t5)
        #expect(registry.tier(for: URL(string: "https://who.int.evil.example/x")!) == .t5)
    }

    @Test("a more specific rule wins over its parent domain")
    func longestDomainWins() {
        var registry = SourceRegistry()
        registry.upsert(Source(domain: "blogs.who.int", name: "WHO blogs", tier: .t4,
                               disciplines: [.medicine]))

        #expect(registry.tier(for: URL(string: "https://blogs.who.int/post")!) == .t4)
        #expect(registry.tier(for: URL(string: "https://www.who.int/news")!) == .t1)
    }

    @Test("sources are chosen by subject, most credible first")
    func sourcesAreChosenBySubject() {
        let registry = SourceRegistry()

        let medical = registry.sources(for: .medicine)
        #expect(medical.first?.tier == .t1)
        #expect(medical.contains { $0.name == "PubMed" })
        // A coding question has somewhere credible to go — the thing v1 could
        // not do, because its sources were hardcoded to medicine.
        let computing = registry.sources(for: .computing)
        #expect(computing.contains { $0.name == "Swift" })
        #expect(!computing.contains { $0.name == "PubMed" })
    }

    @Test("general sources are offered for any subject")
    func generalSourcesAlwaysApply() {
        // An encyclopedia can answer a question about anything; it is just
        // worth less, which the tier already says.
        #expect(SourceRegistry().sources(for: .law).contains { $0.name == "Wikipedia" })
    }

    @Test("a tier ceiling excludes weaker sources")
    func tierCeilingIsRespected() {
        let strict = SourceRegistry().sources(for: .medicine, upTo: .t2)
        #expect(!strict.isEmpty)
        #expect(strict.allSatisfy { $0.tier <= .t2 })
    }

    @Test("adding a source is adding a row")
    func addingASourceNeedsNoCode() {
        var registry = SourceRegistry()
        let url = URL(string: "https://data.go.th/dataset/x")!
        #expect(registry.tier(for: url) == .t5)

        registry.upsert(Source(domain: "data.go.th", name: "Open Government Data",
                               tier: .t1, disciplines: [.statistics, .policy]))

        #expect(registry.tier(for: url) == .t1)
        #expect(registry.sources(for: .statistics).contains { $0.domain == "data.go.th" })
    }

    @Test("editing a source replaces it rather than adding a second rule")
    func upsertReplaces() {
        var registry = SourceRegistry()
        let before = registry.sources.count
        registry.upsert(Source(domain: "who.int", name: "WHO", tier: .t2,
                               disciplines: [.medicine]))

        #expect(registry.sources.count == before, "a second rule for one host")
        #expect(registry.tier(for: URL(string: "https://who.int/x")!) == .t2)
    }

    @Test("disabling a source keeps the row but stops using it")
    func disablingKeepsTheRow() {
        var registry = SourceRegistry()
        registry.setEnabled(false, domain: "wikipedia.org")

        #expect(!registry.sources(for: .general).contains { $0.domain == "wikipedia.org" })
        // Still there, so re-enabling does not mean retyping it.
        #expect(registry.sources.contains { $0.domain == "wikipedia.org" })
        #expect(registry.tier(for: URL(string: "https://en.wikipedia.org/wiki/X")!) == .t5)
    }

    @Test("the registry round-trips through JSON so a user can keep their own")
    func registryIsCodable() throws {
        var registry = SourceRegistry()
        registry.upsert(Source(domain: "data.go.th", name: "Open Data", tier: .t1,
                               disciplines: [.statistics], access: .api(name: "ckan")))

        let restored = try JSONDecoder().decode(
            SourceRegistry.self, from: try JSONEncoder().encode(registry))

        #expect(restored.tier(for: URL(string: "https://data.go.th/x")!) == .t1)
        #expect(restored.source(for: URL(string: "https://data.go.th/x")!)?.access
                == .api(name: "ckan"))
    }
}

// ─────────────────────────────────────────────────────────────
// Thai sources (found by driving P13.1, 2026-08-14).
// ─────────────────────────────────────────────────────────────

@Suite("Thai sources are tiered")
struct ThaiSourceTests {

    @Test("Thai research is not all T5")
    func thaiSourcesAreRated() throws {
        let registry = SourceRegistry()
        // The exact hosts a real Thai-language search returned. Before this,
        // every one of them was T5 — which under §14.1 means a Thai literature
        // review can never be corroborated, and that is a property of the
        // registry rather than of the sources.
        let peerReviewed = try [#require(URL(string: "https://he01.tci-thaijo.org/index.php/JCCPH/article/view/280176")),
                                #require(URL(string: "https://he03.tci-thaijo.org/index.php/PBRI/article/view/3054"))]
        for url in peerReviewed {
            #expect(registry.tier(for: url) == .t2, "\(url.host() ?? "") ควรเป็น T2")
        }
        // A university repository is T3: identifiable author and institution,
        // no peer review.
        let repository = try #require(URL(string: "https://digital.car.chula.ac.th/chulaetd/74647/"))
        #expect(registry.tier(for: repository) == .t3)

        // And the rule that has not changed: a domain nobody vouched for is T5,
        // not unrated (§1.4).
        let unknown = try #require(URL(string: "https://some-blog.example/post"))
        #expect(registry.tier(for: unknown) == .t5)
    }

    @Test("subdomains inherit, and a lookalike domain does not")
    func subdomainsAreMatchedProperly() throws {
        let registry = SourceRegistry()
        let subdomain = try #require(URL(string: "https://he01.tci-thaijo.org/x"))
        #expect(registry.tier(for: subdomain) == .t2)
        // `nottci-thaijo.org` must not inherit: suffix matching without the dot
        // is how a lookalike domain borrows somebody else's credibility.
        let lookalike = try #require(URL(string: "https://nottci-thaijo.org/x"))
        #expect(registry.tier(for: lookalike) == .t5)
    }
}
