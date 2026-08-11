import Testing
import Foundation
import AgentKit
import Knowledge
@testable import WebSearch

// ─────────────────────────────────────────────────────────────
// P3.5's Done-when: "หน้าที่ ingest แล้วค้นเจอใน KB พร้อม tier ที่ถูกต้อง".
//
// Driven through a stub reader so the pipeline is what is under test rather
// than someone else's website; the live fetch has its own tests in
// PageFetcherTests.
// ─────────────────────────────────────────────────────────────

private struct StubReader: PageReading {
    let page: FetchedPage
    func fetch(_ url: URL) async throws -> FetchedPage { page }
}

private func page(url: String, tier: SourceTier, title: String,
                  paragraphs: [String]) -> FetchedPage {
    let final = URL(string: url)!
    return FetchedPage(
        url: final, finalURL: final, title: title, paragraphs: paragraphs,
        provenance: Provenance(
            documentID: "web_" + IngestionPipeline.contentHash(url).prefix(16),
            title: title, origin: .web(url: final), tier: tier),
        contentType: "text/html")
}

private let whoPage = page(
    url: "https://www.who.int/news-room/fact-sheets/detail/diabetes",
    tier: .t1, title: "Diabetes — WHO",
    paragraphs: [
        "โรคเบาหวานเป็นภาวะเรื้อรังที่เกิดขึ้นเมื่อตับอ่อนผลิตอินซูลินได้ไม่เพียงพอ",
        "การให้อินซูลินและการควบคุมอาหารช่วยลดภาวะแทรกซ้อนในผู้ป่วยเบาหวานชนิดที่ 2 ได้",
        "การตรวจคัดกรองสม่ำเสมอช่วยให้พบภาวะแทรกซ้อนทางไตและตาได้ตั้งแต่ระยะแรก",
    ])

@Suite("Ingesting a URL")
struct URLIngestorTests {
    @Test("an ingested page is findable, with the tier its source has")
    func ingestedPageIsSearchable() async throws {
        var index = KnowledgeIndex()
        let report = try await URLIngestor(reader: StubReader(page: whoPage))
            .ingest(whoPage.url, into: &index, scope: .central)

        #expect(report.chunksAdded == 3)

        let hits = index.search("อินซูลิน", scope: .central)
        #expect(!hits.isEmpty)
        // The Done-when: the tier comes from the registry via the page, not
        // from whoever called this.
        #expect(hits.first?.provenance.tier == .t1)
        #expect(hits.first?.provenance.origin == .web(url: whoPage.finalURL))
    }

    @Test("a citation can point at the paragraph, not just the page")
    func paragraphProvenanceSurvives() async throws {
        var index = KnowledgeIndex()
        try await URLIngestor(reader: StubReader(page: whoPage))
            .ingest(whoPage.url, into: &index, scope: .central)

        let hit = try #require(index.search("ตรวจคัดกรอง", scope: .central).first)
        #expect(hit.provenance.page == 3)
        #expect(hit.provenance.section == "ย่อหน้า 3")
    }

    @Test("ingesting the same page twice adds nothing")
    func reingestingIsANoOp() async throws {
        var index = KnowledgeIndex()
        let ingestor = URLIngestor(reader: StubReader(page: whoPage))

        let first = try await ingestor.ingest(whoPage.url, into: &index, scope: .central)
        let second = try await ingestor.ingest(whoPage.url, into: &index, scope: .central)

        #expect(first.chunksAdded == 3)
        #expect(second.chunksAdded == 0)
        #expect(second.duplicatesSkipped == 3)
        #expect(index.count == 3)
    }

    @Test("a blog and an authority do not end up looking alike")
    func tierTravelsWithTheSource() async throws {
        var index = KnowledgeIndex()
        let blog = page(url: "https://some-blog.example/insulin", tier: .t5,
                        title: "ประสบการณ์ส่วนตัว",
                        paragraphs: ["ผมลองหยุดอินซูลินเองแล้วรู้สึกดีขึ้นมากในสองสัปดาห์แรก"])

        try await URLIngestor(reader: StubReader(page: whoPage))
            .ingest(whoPage.url, into: &index, scope: .central)
        try await URLIngestor(reader: StubReader(page: blog))
            .ingest(blog.url, into: &index, scope: .central)

        let tiers = Dictionary(
            uniqueKeysWithValues: index.documents().map { ($0.title, $0.tier) })
        #expect(tiers["Diabetes — WHO"] == .t1)
        #expect(tiers["ประสบการณ์ส่วนตัว"] == .t5)
    }

    @Test("an ingested page lands in the scope it was asked for")
    func scopeIsRespected() async throws {
        var index = KnowledgeIndex()
        try await URLIngestor(reader: StubReader(page: whoPage))
            .ingest(whoPage.url, into: &index, scope: .project(ProjectID("diabetes")))

        #expect(index.search("อินซูลิน", scope: .central).isEmpty)
        #expect(!index.search("อินซูลิน", scope: .project(ProjectID("diabetes"))).isEmpty)
    }

    @Test("a page that cannot be read does not half-ingest")
    func failedFetchLeavesNothing() async throws {
        struct FailingReader: PageReading {
            func fetch(_ url: URL) async throws -> FetchedPage {
                throw FetchError.needsJavaScript(url: url.absoluteString)
            }
        }
        var index = KnowledgeIndex()
        await #expect(throws: FetchError.self) {
            try await URLIngestor(reader: FailingReader())
                .ingest("https://example.com/app", into: &index, scope: .central)
        }
        #expect(index.count == 0)
    }
}
