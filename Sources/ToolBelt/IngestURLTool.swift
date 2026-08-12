import Foundation
import AgentKit
import Knowledge
import WebSearch
import Observability

// ─────────────────────────────────────────────────────────────
// `ingest_url` (ARCHITECTURE §M6, P3.5) — the tool the task was named after.
//
// P3.5 was marked done because `URLIngestor` worked and had tests. It did. What
// nobody noticed is that `grep -rl URLIngestor Sources` returned exactly one
// file: its own. No tool, no screen, no caller — a capability reachable from
// nothing, which is D6 for the sixth time in this project, and this time in a
// task whose *name is the name of a tool that did not exist*.
//
// The parts of the machinery this cannot own, it takes as closures — the same
// shape `KBSearchTool` already uses. Reading the index at call time matters for
// the same reason it does there: documents arrive while the app runs. Writing
// through matters more: an ingest that only reached memory is one the person
// loses without being told, so persistence is not optional here and not a
// detail the caller may forget — it is a parameter.
// ─────────────────────────────────────────────────────────────

public struct IngestURLTool: AgentTool {
    public let name = "ingest_url"
    public let toolDescription = """
    ดึงหน้าเว็บเข้าคลังความรู้ผ่าน pipeline เดียวกับการอัปโหลดไฟล์ แล้วคืนจำนวน chunk ที่เพิ่ม \
    ใช้เมื่อพบหน้าที่ควรอ้างอิงได้ในภายหลัง — หลังจากนี้ `kb_search` จะค้นเจอพร้อม provenance และ tier ของแหล่ง \
    ไม่ใช่เครื่องมืออ่านหน้าเว็บครั้งเดียว (นั่นคือ `fetch_page`)
    """
    /// Matches §5.3's table. Writing into the knowledge base is not read-only:
    /// what goes in here is what later gets cited.
    public let riskLevel: RiskLevel = .medium
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "url": { "type": "string", "description": "ที่อยู่ของหน้าที่จะดึงเข้าคลัง" },
        "tier": { "type": "integer",
          "description": "ระดับความน่าเชื่อถือ 1–5 (ไม่ระบุ = ให้ระบบตัดสินจากโดเมน)" }
      },
      "required": ["url"]
    }
    """

    private let ingestor: URLIngestor
    private let index: @Sendable () async -> KnowledgeIndex
    private let persist: @Sendable ([IndexedChunk]) async throws -> Void
    private let embedder: (any Embedder)?
    private let log = AppLog.logger("ingest")

    public init(ingestor: URLIngestor = URLIngestor(),
                index: @escaping @Sendable () async -> KnowledgeIndex,
                persist: @escaping @Sendable ([IndexedChunk]) async throws -> Void,
                embedder: (any Embedder)? = nil) {
        self.ingestor = ingestor
        self.index = index
        self.persist = persist
        self.embedder = embedder
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Self.arguments(argumentsJSON)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let (address, tier) = try Self.arguments(argumentsJSON)
        var working = await index()
        let report: IngestionReport
        do {
            report = try await ingestor.ingest(address, into: &working,
                                              scope: context.scope, embedder: embedder)
        } catch {
            throw ToolError.executionFailed("ดึงหน้านี้เข้าคลังไม่ได้: \(error)")
        }

        // Written through before the tool answers. An ingest reported as
        // successful and held only in memory is the worst of both.
        let added = working.allChunks.filter { $0.provenance.documentID == report.documentID }
        do {
            try await persist(added)
        } catch {
            throw ToolError.executionFailed(
                "ดึงเข้ามาได้ \(added.count) chunk แต่บันทึกลงคลังไม่สำเร็จ: \(error)")
        }
        log.info("ingested \(address, privacy: .public): \(report.chunksAdded) chunks")

        var text = "เพิ่ม \(report.chunksAdded) chunk จาก \(address) เข้าคลังความรู้แล้ว"
        if report.duplicatesSkipped > 0 {
            text += " · ข้ามที่ซ้ำ \(report.duplicatesSkipped) chunk"
        }
        if let tier { text += " · ระบุ tier \(tier)" }
        if report.chunksAdded == 0 {
            text += "\n(ไม่มีอะไรใหม่เข้าไป — หน้านี้อาจเคยดึงเข้ามาแล้ว)"
        }
        return ToolOutput(text: text, artifacts: [report.documentID])
    }

    static func arguments(_ json: String) throws -> (url: String, tier: Int?) {
        struct Payload: Decodable {
            let url: String
            let tier: Int?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)),
              !payload.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidArguments("ต้องระบุ 'url'")
        }
        guard let parsed = URL(string: payload.url), parsed.scheme != nil, parsed.host() != nil else {
            throw ToolError.invalidArguments("'\(payload.url)' ไม่ใช่ URL ที่ใช้ได้")
        }
        if let tier = payload.tier, !(1...5).contains(tier) {
            throw ToolError.invalidArguments("tier ต้องอยู่ระหว่าง 1 ถึง 5")
        }
        return (payload.url, payload.tier)
    }
}
