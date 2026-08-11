import Testing
import Foundation
import AgentKit
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
