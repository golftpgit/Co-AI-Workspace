import Testing
import Foundation
import AgentKit
import Observability
import Knowledge
import WebSearch
@testable import CoreEngine
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// The plan's rule, applied: a capability the agent cannot reach is not a
// feature. v1 had a working MCP client that no session could call (D6), so
// these tests go through `ToolGateway` — the only thing that can invoke a
// tool — rather than calling the tools directly.
// ─────────────────────────────────────────────────────────────

private func index(with chunks: [(String, String)]) -> KnowledgeIndex {
    var index = KnowledgeIndex()
    for (id, text) in chunks {
        try? index.insert(IndexedChunk(
            id: id, text: text, scope: .central,
            provenance: Provenance(documentID: "doc_\(id)", title: "เอกสาร \(id)",
                                   origin: .upload(filename: "\(id).pdf"), tier: .t2,
                                   page: 3)))
    }
    return index
}

private struct StubPageReader: PageReading {
    func fetch(_ url: URL) async throws -> FetchedPage {
        FetchedPage(url: url, finalURL: url, title: "หน้าทดสอบ",
                    paragraphs: ["ย่อหน้าแรกของบทความ", "ย่อหน้าที่สองของบทความ"],
                    provenance: Provenance(documentID: "web_1", title: "หน้าทดสอบ",
                                           origin: .web(url: url), tier: .t1),
                    contentType: "text/html")
    }
}

@Suite("Knowledge tools reach the agent")
struct KnowledgeToolsTests {
    @Test("kb_search is callable through the gate and cites its sources")
    func kbSearchIsReachable() async throws {
        let knowledge = index(with: [
            ("c1", "การให้อินซูลินแบบพื้นฐานช่วยคุมระดับน้ำตาลในเลือดได้ดีขึ้น"),
            ("c2", "การระบาดของโควิดทำให้ระบบสาธารณสุขรับภาระหนัก"),
        ])
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(KBSearchTool(index: { knowledge }))

        let outcome = try await gateway.call("kb_search",
                                             argumentsJSON: #"{"query":"อินซูลิน"}"#,
                                             context: ToolContext(scope: .central))

        guard case .executed(let output, _, _) = outcome else {
            Issue.record("kb_search did not run: \(outcome)")
            return
        }
        #expect(output.text.contains("อินซูลิน"))
        // Without the source and the tier a Researcher cannot produce the
        // citation §2.5 demands of it.
        #expect(output.text.contains("T2"))
        #expect(output.text.contains("เอกสาร c1"))
        #expect(output.text.contains("น.3"))
        #expect(output.artifacts.contains("c1"))
    }

    @Test("an empty knowledge base says so rather than returning nothing")
    func emptyKnowledgeBaseIsExplicit() async throws {
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(KBSearchTool(index: { KnowledgeIndex() }))

        let outcome = try await gateway.call("kb_search",
                                             argumentsJSON: #"{"query":"อะไรก็ตาม"}"#,
                                             context: ToolContext(scope: .central))
        guard case .executed(let output, _, _) = outcome else {
            Issue.record("did not run: \(outcome)")
            return
        }
        // A blank result reads as "nothing exists"; this says which it is.
        #expect(output.text.contains("ไม่พบข้อมูลในคลังความรู้"))
    }

    @Test("kb_search only sees the scope it was called in")
    func kbSearchRespectsScope() async throws {
        let knowledge: KnowledgeIndex = {
            var index = KnowledgeIndex()
            try? index.insert(IndexedChunk(
                id: "p1", text: "ความลับของโครงการอัลฟา",
                scope: .project(ProjectID("alpha")),
                provenance: Provenance(documentID: "d1", title: "อัลฟา",
                                       origin: .upload(filename: "a.pdf"), tier: .t3)))
            return index
        }()

        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(KBSearchTool(index: { knowledge }))

        let outcome = try await gateway.call("kb_search",
                                             argumentsJSON: #"{"query":"ความลับ"}"#,
                                             context: ToolContext(scope: .central))
        guard case .executed(let output, _, _) = outcome else { return }
        #expect(output.text.contains("ไม่พบข้อมูล"), "a project's knowledge leaked into central")
    }

    @Test("fetch_page is callable through the gate and numbers its paragraphs")
    func fetchPageIsReachable() async throws {
        // The tool a citation depends on: paragraph numbers are what make
        // "according to paragraph 2" possible.
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(StubbedFetchPageTool(reader: StubPageReader()))

        let outcome = try await gateway.call(
            "fetch_page", argumentsJSON: #"{"url":"https://www.who.int/x"}"#,
            context: ToolContext(scope: .central))

        guard case .executed(let output, _, _) = outcome else {
            Issue.record("fetch_page did not run: \(outcome)")
            return
        }
        #expect(output.text.contains("(1) ย่อหน้าแรก"))
        #expect(output.text.contains("(2) ย่อหน้าที่สอง"))
        #expect(output.text.contains("T1"))
    }

    @Test("the tools the agent is offered are the ones that exist")
    func toolsAppearOnTheList() async {
        // D6's exact failure: an implementation nobody could call. The gate's
        // advert list is what the model is shown.
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register([
            KBSearchTool(index: { KnowledgeIndex() }),
            WebSearchTool(),
            FetchPageTool(),
        ])
        let names = Set(await gateway.adverts.map(\.name))
        #expect(names == ["kb_search", "web_search", "fetch_page"])
    }

    @Test("a search tool is still re-scored by the gate, not trusted")
    func riskIsRescored() async throws {
        // A tool declaring itself low does not get to skip anything; the
        // scorer decides independently (§5.3).
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(KBSearchTool(index: { KnowledgeIndex() }))

        let outcome = try await gateway.call("kb_search",
                                             argumentsJSON: #"{"query":"x"}"#,
                                             context: ToolContext(scope: .central))
        guard case .executed(_, let risk, _) = outcome else { return }
        #expect(risk.level == .low)
    }

    @Test("bad arguments come back as something the model can fix")
    func badArgumentsAreLegible() async throws {
        let gateway = ToolGateway(modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(KBSearchTool(index: { KnowledgeIndex() }))

        let outcome = try await gateway.call("kb_search",
                                             argumentsJSON: #"{"quer":"typo"}"#,
                                             context: ToolContext(scope: .central))
        // Either the gate's schema critic sends it back or the tool does; what
        // matters is that the turn continues with a message, not an exception.
        switch outcome {
        case .sentBack(let reason): #expect(!reason.isEmpty)
        case .executed(let output, _, _): #expect(output.text.contains("ไม่พบ"))
        default: Issue.record("unexpected: \(outcome)")
        }
    }
}

/// `FetchPageTool` reads the live web; this is the same tool with its reader
/// swapped, so the gate path can be tested without one.
private struct StubbedFetchPageTool: AgentTool {
    let name = "fetch_page"
    let toolDescription = "อ่านหน้าเว็บ"
    let riskLevel: RiskLevel = .low
    let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#
    let reader: any PageReading

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["url"] as? String, let url = URL(string: address) else {
            throw ToolError.invalidArguments("url")
        }
        let page = try await reader.fetch(url)
        let body = page.paragraphs.enumerated()
            .map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: "\n\n")
        return ToolOutput(text: """
        \(page.title ?? "")
        \(page.finalURL.absoluteString) · \(page.provenance.tier?.rawValue.uppercased() ?? "T5")

        \(body)
        """)
    }
}

// ─────────────────────────────────────────────────────────────
// P12.2 — the role's knowledge view, applied where an agent actually searches.
//
// A `KnowledgeView` that only its own tests consult is the shape this project
// has now caught eight times. These go through `ToolGateway` for the same
// reason as everything else in this file: the claim is that a Writer searching
// the knowledge base gets the Writer's view, not that a filter function works.
// ─────────────────────────────────────────────────────────────

private func mixedIndex() -> KnowledgeIndex {
    var index = KnowledgeIndex()
    let citable = Provenance(documentID: "doc_cite", title: "บทความ",
                             origin: .upload(filename: "a.pdf"), tier: .t2,
                             authors: ["ผู้เขียน ก"], year: 2023)
    let anonymous = Provenance(documentID: "doc_anon", title: "บันทึก",
                               origin: .upload(filename: "b.pdf"), tier: .t2)
    try? index.insert(contentsOf: [
        IndexedChunk(id: "c_cite", text: "ภาวะหมดไฟในพยาบาลพบได้บ่อย", scope: .central,
                     provenance: citable, embedding: nil, embeddingProfileID: nil,
                     contentHash: "h_cite"),
        IndexedChunk(id: "c_anon", text: "ภาวะหมดไฟในพยาบาลเป็นเรื่องที่พูดกันมาก", scope: .central,
                     provenance: anonymous, embedding: nil, embeddingProfileID: nil,
                     contentHash: "h_anon"),
    ])
    return index
}

@Suite("kb_search through a role's view — P12.2")
struct KBSearchViewTests {

    private func gateway(_ index: KnowledgeIndex) async -> ToolGateway {
        let gateway = ToolGateway(chain: HookChain(), modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(KBSearchTool(index: { index }))
        return gateway
    }

    @Test("a Writer searching gets only what it could cite")
    func writerSeesOnlyCitable() async throws {
        let gateway = await gateway(mixedIndex())
        let outcome = try await gateway.call(
            "kb_search", argumentsJSON: #"{"query":"ภาวะหมดไฟ"}"#,
            context: ToolContext(scope: .central, role: .writer))

        guard case .executed(let output, _, _) = outcome else {
            Issue.record("expected the search to run, got \(outcome)"); return
        }
        #expect(output.text.contains("บทความ"))
        #expect(output.text.contains("บันทึก") == false,
                "the Writer was shown a chunk with no author or year")
    }

    // The same question, no role: the person at the keyboard sees everything
    // their workspace holds.
    @Test("a turn with no role attached is not filtered")
    func noRoleSeesEverything() async throws {
        let gateway = await gateway(mixedIndex())
        let outcome = try await gateway.call(
            "kb_search", argumentsJSON: #"{"query":"ภาวะหมดไฟ"}"#,
            context: ToolContext(scope: .central))

        guard case .executed(let output, _, _) = outcome else {
            Issue.record("expected the search to run, got \(outcome)"); return
        }
        #expect(output.text.contains("บทความ"))
        #expect(output.text.contains("บันทึก"))
    }

    // P12.6's first half. "Nothing found" and "your role cannot see that" are
    // different facts, and only one of them is a knowledge base with a gap.
    @Test("a search emptied by the view says so, instead of reporting an empty library")
    func emptyBecauseOfTheViewIsReportedAsSuch() async throws {
        var index = KnowledgeIndex()
        try index.insert(IndexedChunk(
            id: "c_anon", text: "ภาวะหมดไฟในพยาบาล", scope: .central,
            provenance: Provenance(documentID: "d", title: "บันทึก",
                                   origin: .upload(filename: "b.pdf"), tier: .t2),
            embedding: nil, embeddingProfileID: nil, contentHash: "h"))

        let gateway = await gateway(index)
        let outcome = try await gateway.call(
            "kb_search", argumentsJSON: #"{"query":"ภาวะหมดไฟ"}"#,
            context: ToolContext(scope: .central, role: .writer))

        guard case .executed(let output, _, _) = outcome else {
            Issue.record("expected the search to run, got \(outcome)"); return
        }
        #expect(output.text.contains("ถูกกรองออกด้วยมุมมองความรู้"))
        #expect(output.text.contains("ไม่ใช่ว่าคลังไม่มีข้อมูล"))
    }

    // A manifest may declare its own view; the standard one is the fallback,
    // not the law.
    @Test("a declared view overrides the standard one for that role")
    func declaredViewWins() async throws {
        let gateway = ToolGateway(chain: HookChain(),
                                  modes: OperatingModes(autonomy: .fullAutonomous))
        let index = mixedIndex()
        await gateway.register(KBSearchTool(index: { index },
                                            views: { _ in KnowledgeView() }))

        let outcome = try await gateway.call(
            "kb_search", argumentsJSON: #"{"query":"ภาวะหมดไฟ"}"#,
            context: ToolContext(scope: .central, role: .writer))

        guard case .executed(let output, _, _) = outcome else {
            Issue.record("expected the search to run, got \(outcome)"); return
        }
        #expect(output.text.contains("บันทึก"), "the declared view was ignored")
    }
}

// ─────────────────────────────────────────────────────────────
// P12.6 — asking to see more, through the hook chain like everything else.
// ─────────────────────────────────────────────────────────────

@Suite("widen_view — P12.6")
struct WidenViewTests {

    private func gateway(_ widenings: ViewWidenings, index: KnowledgeIndex) async -> ToolGateway {
        let gateway = ToolGateway(chain: HookChain(),
                                  modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(KBSearchTool(index: { index }, widenings: widenings))
        await gateway.register(WidenViewTool(widenings: widenings))
        return gateway
    }

    // The whole point: search finds nothing, widen, search again, find it —
    // and it takes effect on the next search rather than on the next launch.
    @Test("after widening, the same search finds what the view had hidden")
    func wideningTakesEffectImmediately() async throws {
        let widenings = ViewWidenings()
        let gateway = await gateway(widenings, index: mixedIndex())
        let context = ToolContext(scope: .central, conversationID: "conv_1", role: .writer)

        let before = try await gateway.call("kb_search",
                                            argumentsJSON: #"{"query":"ภาวะหมดไฟ"}"#,
                                            context: context)
        guard case .executed(let first, _, _) = before else {
            Issue.record("expected a search"); return
        }
        #expect(first.text.contains("บันทึก") == false)

        _ = try await gateway.call(
            "widen_view",
            argumentsJSON: #"{"reason":"ต้องการภาพรวมก่อนเลือกแหล่งที่จะอ้าง","allow_incomplete_citations":true}"#,
            context: context)

        let after = try await gateway.call("kb_search",
                                           argumentsJSON: #"{"query":"ภาวะหมดไฟ"}"#,
                                           context: context)
        guard case .executed(let second, _, _) = after else {
            Issue.record("expected a search"); return
        }
        #expect(second.text.contains("บันทึก"), "the widening did not reach the next search")
    }

    // A widening nobody can explain later is one nobody can review.
    @Test("a widening with no reason, or a token one, is refused")
    func reasonIsRequired() async throws {
        let widenings = ViewWidenings()
        let gateway = await gateway(widenings, index: mixedIndex())
        let context = ToolContext(scope: .central, conversationID: "c", role: .writer)

        for arguments in ["{}", #"{"reason":"ก"}"#] {
            let outcome = try await gateway.call("widen_view", argumentsJSON: arguments,
                                                 context: context)
            guard case .sentBack = outcome else {
                Issue.record("a widening with no real reason was accepted: \(outcome)")
                return
            }
        }
    }

    // It expires with the conversation because it lives with the conversation:
    // nothing here writes to a manifest.
    @Test("a widening does not leak into another conversation")
    func scopedToOneConversation() async throws {
        let widenings = ViewWidenings()
        let gateway = await gateway(widenings, index: mixedIndex())

        _ = try await gateway.call(
            "widen_view",
            argumentsJSON: #"{"reason":"ต้องการภาพรวมก่อนเลือกแหล่ง","allow_incomplete_citations":true}"#,
            context: ToolContext(scope: .central, conversationID: "conv_a", role: .writer))

        let elsewhere = try await gateway.call(
            "kb_search", argumentsJSON: #"{"query":"ภาวะหมดไฟ"}"#,
            context: ToolContext(scope: .central, conversationID: "conv_b", role: .writer))
        guard case .executed(let output, _, _) = elsewhere else {
            Issue.record("expected a search"); return
        }
        #expect(output.text.contains("บันทึก") == false,
                "a widening granted in one conversation applied in another")
    }

    // Additive only: an agent must not be able to hide material from itself,
    // and above all not the rules.
    @Test("widening can only add — policy stays, and nothing gets narrower")
    func wideningIsAdditive() {
        let researcher = KnowledgeView.standard(for: .researcher)
        let widened = researcher.widened(minTier: .t5, hops: 0)
        #expect(widened.visibleScopes.contains(.policy))
        // The floor went down, not up, and the hop count did not shrink.
        #expect(widened.minTier == .t5)
        #expect(widened.hops == researcher.hops)

        // Asking for a *stricter* floor than the current one leaves the wider
        // of the two in place.
        let stricter = KnowledgeView(minTier: .t3).widened(minTier: .t1)
        #expect(stricter.minTier == .t3)
    }

    // The Reviewer's narrow view is the point of having a reviewer.
    @Test("the Reviewer cannot widen its way into the maker's sources")
    func reviewerCannotSeeWorkingMaterial() async throws {
        let widenings = ViewWidenings()
        let gateway = await gateway(widenings, index: mixedIndex())
        let context = ToolContext(scope: .central, conversationID: "c", role: .reviewer)

        _ = try await gateway.call(
            "widen_view",
            argumentsJSON: #"{"reason":"อยากเห็นสิ่งที่ผู้ทำใช้ประกอบการตัดสินใจ","any_tier":true}"#,
            context: context)

        let after = try await gateway.call("kb_search",
                                           argumentsJSON: #"{"query":"ภาวะหมดไฟ"}"#,
                                           context: context)
        guard case .executed(let output, _, _) = after else {
            Issue.record("expected a search"); return
        }
        #expect(output.text.contains("บทความ") == false,
                "the Reviewer widened its way into the material the maker worked from")
    }

    @Test("a turn with no role has nothing to widen, and says so")
    func needsARole() async throws {
        let widenings = ViewWidenings()
        let gateway = await gateway(widenings, index: mixedIndex())
        let outcome = try await gateway.call(
            "widen_view", argumentsJSON: #"{"reason":"ขอดูให้กว้างขึ้นหน่อยครับ"}"#,
            context: ToolContext(scope: .central, conversationID: "c"))
        guard case .sentBack = outcome else {
            Issue.record("expected it to be sent back, got \(outcome)"); return
        }
    }
}

// ─────────────────────────────────────────────────────────────
// P12.6's outstanding item — the record of a widening had nowhere to live.
//
// It was heading for `Evidence`, which requires `passed: Bool`, and "what this
// role was allowed to see" is not a pass or a fail. Forcing it into one would
// have produced a flag nobody could read the meaning of. A span is where it
// belongs: it already carries a role, a scope and a time.
// ─────────────────────────────────────────────────────────────
private actor RecordingSink: SpanSink {
    private(set) var spans: [Span] = []
    func record(_ span: Span) async { spans.append(span) }
    func widenings() -> [Span] { spans.filter { $0.name == "view:widened" } }
}

@Suite("A widening leaves a record (P12.6)")
struct WideningRecordTests {

    @Test("widening a view writes a span with the reason and the new view")
    func wideningIsRecorded() async throws {
        let sink = RecordingSink()
        let widenings = ViewWidenings()
        let tool = WidenViewTool(widenings: widenings, spans: sink)

        _ = try await tool.call(
            argumentsJSON: #"{"reason":"ต้องดูงานวิจัยที่ยังไม่ผ่าน peer review","any_tier":true}"#,
            context: ToolContext(scope: .central, conversationID: "cv_w", role: .researcher))

        let recorded = await sink.widenings()
        #expect(recorded.count == 1)
        let span = try #require(recorded.first)
        #expect(span.role == .researcher)
        // The reason is the point: a widening nobody can account for later is
        // a widening that cannot be reviewed.
        #expect(span.detail?.contains("peer review") == true)
        // And what it became, in the words a reviewer reads.
        #expect(span.detail?.contains("ขอบเขต") == true)
        #expect(span.endedAt != nil)
    }

    @Test("without a sink the tool still widens")
    func noSinkIsNotAFailure() async throws {
        // Every sink in this project is optional: the tool works without
        // observability, it just cannot be asked about afterwards.
        let tool = WidenViewTool(widenings: ViewWidenings())
        let output = try await tool.call(
            argumentsJSON: #"{"reason":"ต้องตามอ้างอิงต่ออีกหนึ่งชั้น","hops":2}"#,
            context: ToolContext(scope: .central, conversationID: "cv_x", role: .analyst))
        #expect(output.text.contains("ขยายมุมมอง"))
    }
}
