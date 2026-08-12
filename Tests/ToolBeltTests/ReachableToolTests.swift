import Testing
import Foundation
import AgentKit
import Analysis
import CoreEngine
import DocGen
import Knowledge
import WebSearch
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// The four tools that closed a gap found by reading the plan (2026-08-12).
//
// Every one of them wraps a capability that was already finished and tested and
// reachable from nothing: `URLIngestor` was referenced by exactly one file in
// the repository — its own. This is the sixth instance of one failure in this
// project (v1's D6, then ConflictDetector, then the P4 team, then the MCP
// client, then plugins, then nine tools at once), so each test below calls the
// tool **through the gateway**, by the name a model would use. A test that
// constructed the tool directly would prove the same thing the previous five
// times proved: that the code works and nobody can reach it.
// ─────────────────────────────────────────────────────────────

private struct AlwaysApproves: ApprovalRequesting {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision { .approved }
}

private func context() -> ToolContext { ToolContext(scope: .central, conversationID: "c1") }

private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "coai-tools-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("Tools that had no way in", .serialized)
struct ReachableToolTests {

    // MARK: - analysis_query / analysis_execute

    /// The Analyst's tool list was `kb_search`, `run_shell`, `run_stat_test`.
    /// This is the store it could not reach.
    @Test("analysis_query reads the store through the gateway")
    func analysisQueryRuns() async throws {
        let store = try AnalysisStore()
        _ = try await store.query("CREATE TABLE patients AS SELECT 1 AS id, 'A' AS ward")
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(AnalysisQueryTool(store: { store }))

        let outcome = try await gateway.call("analysis_query",
                                             argumentsJSON: #"{"sql":"SELECT * FROM patients"}"#,
                                             context: context())
        guard case .executed(let output, _, _) = outcome else {
            Issue.record("ไม่ได้รัน: \(outcome)")
            return
        }
        #expect(output.text.contains("ward"))
        #expect(output.text.contains("1 | A") || output.text.contains("1"))
    }

    /// The reason `analysis_query` may be classified low (§5.3). It is
    /// read-only because it is *checked* — by the same `SQLGuard` the notebook
    /// and the DB explorer use — not because it is trusted to be.
    @Test("analysis_query refuses to mutate, and says which tool to use instead")
    func analysisQueryIsStructurallyReadOnly() async throws {
        let store = try AnalysisStore()
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(AnalysisQueryTool(store: { store }))

        for sql in ["DROP TABLE patients",
                    "SELECT 1; DELETE FROM patients",
                    "CREATE TABLE t AS SELECT 1"] {
            let outcome = try await gateway.call(
                "analysis_query",
                argumentsJSON: String(data: try JSONEncoder().encode(["sql": sql]), encoding: .utf8)!,
                context: context())
            guard case .sentBack(let reason) = outcome else {
                Issue.record("ควรถูกส่งกลับ: \(sql) → \(outcome)")
                continue
            }
            #expect(reason.contains("analysis_execute"))
        }
        // And the advert a model reads says low, which is only honest because
        // of the check above.
        let adverts = await gateway.adverts
        #expect(adverts.first?.declaredRisk == .low)
    }

    @Test("analysis_execute mutates, and reports what it changed")
    func analysisExecuteRuns() async throws {
        let store = try AnalysisStore()
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(AnalysisExecuteTool(store: { store }))

        let outcome = try await gateway.call(
            "analysis_execute",
            argumentsJSON: #"{"sql":"CREATE TABLE wards AS SELECT 'ICU' AS name"}"#,
            context: context())
        guard case .executed(let output, _, _) = outcome else {
            Issue.record("ไม่ได้รัน: \(outcome)")
            return
        }
        // What it did, not just that it worked: a span reading "succeeded" is
        // not a record of a CREATE.
        #expect(output.text.uppercased().contains("CREATE"))
        #expect(try await store.tables().contains("wards"))
    }

    /// It is medium risk, so with nobody to ask it does not run — the ordinary
    /// gate behaviour, checked because this tool can drop a table.
    @Test("analysis_execute cannot run with no approval channel")
    func analysisExecuteIsGated() async throws {
        let store = try AnalysisStore()
        let gateway = ToolGateway(approver: nil,
                                  modes: OperatingModes(autonomy: .approvalRequired))
        await gateway.register(AnalysisExecuteTool(store: { store }))

        let outcome = try await gateway.call("analysis_execute",
                                             argumentsJSON: #"{"sql":"DROP TABLE IF EXISTS x"}"#,
                                             context: context())
        if case .denied = outcome {} else { Issue.record("ไม่ได้ถูกปฏิเสธ: \(outcome)") }
    }

    // MARK: - save_document

    /// The Writer's tool list was `["kb_search"]`: the role whose whole job is
    /// producing documents could not produce a file.
    @Test("save_document writes a real .docx that macOS can read the text out of")
    func saveDocumentWritesAFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(SaveDocumentTool(directory: directory))

        let outcome = try await gateway.call("save_document", argumentsJSON: """
        {"title": "บันทึกการประชุม",
         "filename": "meeting",
         "authors": ["ผู้วิจัย ก."],
         "sections": [
           {"heading": "สรุป", "paragraphs": ["ที่ประชุมเห็นชอบตามที่เสนอ"]},
           {"heading": "งานที่ต้องทำ", "bullets": ["ตรวจข้อมูลซ้ำ", "ส่งร่างวันศุกร์"]}
         ]}
        """, context: context())

        guard case .executed(let output, _, _) = outcome else {
            Issue.record("ไม่ได้รัน: \(outcome)")
            return
        }
        let file = directory.appending(path: "meeting.docx")
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(output.artifacts.first?.hasSuffix("meeting.docx") == true)

        // Read back with Apple's own reader, the same standard P7.6 was held to.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", file.path(percentEncoded: false)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(text.contains("บันทึกการประชุม"))
        #expect(text.contains("ที่ประชุมเห็นชอบตามที่เสนอ"))
        #expect(text.contains("ส่งร่างวันศุกร์"))
    }

    @Test("save_document makes slides when asked for pptx")
    func saveDocumentWritesSlides() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(SaveDocumentTool(directory: directory))

        _ = try await gateway.call("save_document", argumentsJSON: """
        {"title": "ผลการศึกษา", "filename": "deck", "format": "pptx",
         "sections": [{"heading": "วิธีการ", "bullets": ["เก็บย้อนหลัง"]}]}
        """, context: context())

        let file = directory.appending(path: "deck.pptx")
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        // P7.6's master chain, still there when the writer is driven from a tool.
        let listed = Process()
        listed.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listed.arguments = ["-l", file.path(percentEncoded: false)]
        let pipe = Pipe()
        listed.standardOutput = pipe
        try listed.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        listed.waitUntilExit()
        #expect(text.contains("ppt/slideMasters/slideMaster1.xml"))
    }

    /// A filename is refused rather than sanitised — the rule `write_skill`
    /// settled on, for the same reason: a writer that renames things quietly
    /// cannot be predicted from its input.
    @Test("save_document refuses a filename that is not one")
    func saveDocumentRefusesBadNames() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(SaveDocumentTool(directory: directory))

        for name in ["../escape", "sub/dir", ".."] {
            let outcome = try await gateway.call("save_document", argumentsJSON: """
            {"title": "t", "filename": "\(name)",
             "sections": [{"heading": "h", "paragraphs": ["p"]}]}
            """, context: context())
            if case .sentBack = outcome {} else {
                Issue.record("ควรปฏิเสธ '\(name)': \(outcome)")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)).isEmpty)
    }

    @Test("save_document refuses a document with nothing in it")
    func saveDocumentRefusesEmpty() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(SaveDocumentTool(directory: directory))

        let outcome = try await gateway.call("save_document", argumentsJSON: """
        {"title": "ว่าง", "sections": [{"heading": "หัวข้อ"}]}
        """, context: context())
        if case .sentBack = outcome {} else { Issue.record("ควรถูกส่งกลับ: \(outcome)") }
    }

    // MARK: - ingest_url

    /// P3.5 was marked done with `URLIngestor` finished and tested. This is the
    /// tool the task was named after, which did not exist.
    @Test("ingest_url puts a page into the knowledge base and writes it through")
    func ingestURLReachesTheKnowledgeBase() async throws {
        let address = URL(string: "https://example.invalid/guideline")!
        let page = FetchedPage(
            url: address,
            finalURL: address,
            title: "แนวทางการรักษา",
            paragraphs: ["ผู้ป่วยเบาหวานควรตรวจ HbA1c ทุกสามถึงหกเดือนตามแนวทางล่าสุด",
                         "การควบคุมอาหารร่วมกับยาให้ผลดีกว่าการใช้ยาอย่างเดียว"],
            provenance: Provenance(documentID: "web-guideline",
                                   title: "แนวทางการรักษา",
                                   origin: .web(url: address),
                                   tier: .t2,
                                   authors: ["กรมการแพทย์"],
                                   year: 2026),
            contentType: "text/html")
        let persisted = Persisted()
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(IngestURLTool(
            ingestor: URLIngestor(reader: StubReader(page: page)),
            index: { KnowledgeIndex(profile: .none) },
            persist: { await persisted.record($0) }))

        let outcome = try await gateway.call(
            "ingest_url",
            argumentsJSON: #"{"url":"https://example.invalid/guideline"}"#,
            context: context())
        guard case .executed(let output, _, _) = outcome else {
            Issue.record("ไม่ได้รัน: \(outcome)")
            return
        }
        #expect(output.text.contains("เข้าคลังความรู้"))

        // Written through, not just held in memory — the whole reason the tool
        // takes a `persist` closure rather than being optional about it.
        let chunks = await persisted.chunks
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.provenance.tier == .t2 })
        #expect(chunks.contains { $0.text.contains("HbA1c") })
    }

    @Test("ingest_url refuses something that is not a URL, before fetching anything")
    func ingestURLValidates() async throws {
        let persisted = Persisted()
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(IngestURLTool(
            ingestor: URLIngestor(reader: FailingReader()),
            index: { KnowledgeIndex(profile: .none) },
            persist: { await persisted.record($0) }))

        for bad in ["ไม่ใช่ยูอาร์แอล", "", "/etc/passwd"] {
            let outcome = try await gateway.call(
                "ingest_url",
                argumentsJSON: String(data: try JSONEncoder().encode(["url": bad]),
                                      encoding: .utf8)!,
                context: context())
            if case .sentBack = outcome {} else { Issue.record("ควรปฏิเสธ '\(bad)': \(outcome)") }
        }
        #expect(await persisted.chunks.isEmpty)
    }

    // MARK: - the rule that would have caught all of this

    /// Not a test of behaviour — a test of reachability. Every tool §5.3
    /// classifies has to exist, because a name in that table is somebody
    /// intending a tool, and the six previous instances of this bug were all
    /// "the code is there and nothing can call it".
    @Test("every tool the risk table classifies can be registered and advertised")
    func classifiedToolsAreReachable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AnalysisStore()
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register([
            AnalysisQueryTool(store: { store }),
            AnalysisExecuteTool(store: { store }),
            SaveDocumentTool(directory: directory),
            PullDBTableTool(store: { store }, connectors: { [] }),
            IngestURLTool(ingestor: URLIngestor(reader: FailingReader()),
                          index: { KnowledgeIndex(profile: .none) },
                          persist: { _ in }),
        ])
        let names = Set(await gateway.registeredNames)
        for expected in ["analysis_query", "analysis_execute", "save_document",
                         "pull_db_table", "ingest_url"] {
            #expect(names.contains(expected), "ไม่มี \(expected) บน tool list")
        }
    }

    /// A saved connector is the only thing this tool can point at. A tool that
    /// took a connection string would be a tool a model could aim anywhere.
    @Test("pull_db_table only reaches connectors somebody saved")
    func pullOnlyUsesSavedConnectors() async throws {
        let store = try AnalysisStore()
        let gateway = ToolGateway(approver: AlwaysApproves())
        await gateway.register(PullDBTableTool(store: { store }, connectors: { [] }))

        let outcome = try await gateway.call("pull_db_table",
                                             argumentsJSON: #"{"alias":"prod","table":"patients"}"#,
                                             context: context())
        guard case .sentBack(let reason) = outcome else {
            Issue.record("ควรถูกส่งกลับ: \(outcome)")
            return
        }
        #expect(reason.contains("prod"))
        #expect(reason.contains("ยังไม่มีแหล่ง"))
    }
}

// MARK: - doubles

private actor Persisted {
    private(set) var chunks: [IndexedChunk] = []
    func record(_ new: [IndexedChunk]) { chunks.append(contentsOf: new) }
}

private struct StubReader: PageReading {
    let page: FetchedPage
    func fetch(_ url: URL) async throws -> FetchedPage { page }
}

private struct FailingReader: PageReading {
    func fetch(_ url: URL) async throws -> FetchedPage {
        throw FetchError.invalidURL("ไม่ควรถูกเรียก")
    }
}
