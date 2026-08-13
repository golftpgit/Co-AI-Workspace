import Foundation
import AgentKit
import Knowledge
import WebSearch

// ─────────────────────────────────────────────────────────────
// The knowledge base and the web, as things the agent can actually use
// (ARCHITECTURE §1.4, §11).
//
// This file exists because of v1's D6: an MCP client was implemented, worked,
// and was never connected to any session's tool list — a capability nobody
// could reach. P2 and P3 built retrieval, ingestion, source tiering and page
// reading; until they are `AgentTool`s registered on the gateway, none of it
// is a feature.
//
// Every result carries its tier and where it came from, so the model is given
// what it needs to cite rather than a wall of text (§2.5 requires citations
// from the Researcher, and it cannot produce one from text with no source).
// ─────────────────────────────────────────────────────────────

/// Retrieval over what the system already knows. Read-only, so it declares
/// low risk — the gate still re-scores it, and that is the point (§5.3).
public struct KBSearchTool: AgentTool {
    public let name = "kb_search"
    public let toolDescription = """
    ค้นคลังความรู้ของระบบ (เอกสารที่ ingest ไว้แล้ว) แบบ hybrid — ได้ทั้งข้อความที่ตรงคำและความหมายใกล้เคียง \
    ผลลัพธ์ทุกแถวมีที่มาและระดับความน่าเชื่อถือ (tier) ให้อ้างอิงได้
    """
    public let riskLevel: RiskLevel = .low
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "คำค้น" },
        "limit": { "type": "integer", "description": "จำนวนผลลัพธ์สูงสุด (ค่าเริ่มต้น 5)" }
      },
      "required": ["query"]
    }
    """

    /// The index is read through a closure rather than held: the app owns it,
    /// it changes as documents are added, and a tool holding a stale copy
    /// would answer from a knowledge base that no longer exists.
    private let index: @Sendable () async -> KnowledgeIndex
    private let embedder: (any Embedder)?

    public init(index: @escaping @Sendable () async -> KnowledgeIndex,
                embedder: (any Embedder)? = nil) {
        self.index = index
        self.embedder = embedder
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let arguments = try Arguments(argumentsJSON)
        let query = try arguments.string("query")
        let limit = arguments.int("limit") ?? 5

        let index = await index()
        var results: [SearchResult] = []
        if let embedder, index.profile?.id == embedder.profile.id {
            results = (try? await index.search(query, scope: context.scope,
                                               embedder: embedder, limit: limit)) ?? []
        }
        if results.isEmpty {
            // Lexical is a real answer, not a fallback that hides a failure —
            // and the caller is told which half answered.
            results = index.search(query, scope: context.scope, limit: limit)
        }

        guard !results.isEmpty else {
            return ToolOutput(text: "ไม่พบข้อมูลในคลังความรู้สำหรับ: \(query)")
        }

        let rendered = results.enumerated().map { position, result in
            let source = result.provenance
            let tier = source.tier?.rawValue.uppercased() ?? "ระบบเขียนเอง"
            let page = source.page.map { " น.\($0)" } ?? ""
            return """
            [\(position + 1)] \(result.chunk.text)
                — \(source.title)\(page) · \(tier) · \(source.documentID)
            """
        }.joined(separator: "\n\n")

        return ToolOutput(text: rendered, artifacts: results.map(\.chunk.id))
    }
}

/// Meta-search over the open web. Returns places to look — §1.4 requires
/// `fetch_page` before any of it is cited, and the description says so, because
/// a model told only "here are results" will quote the snippets.
public struct WebSearchTool: AgentTool {
    public let name = "web_search"
    public let toolDescription = """
    ค้นเว็บทั่วไปแล้วคืน **รายการลิงก์พร้อม tier** เท่านั้น \
    ห้ามอ้างอิงจาก snippet — ต้องเรียก fetch_page อ่านหน้านั้นจริงก่อนเสมอ
    """
    public let riskLevel: RiskLevel = .low
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "คำค้น" },
        "limit": { "type": "integer", "description": "จำนวนผลลัพธ์ (ค่าเริ่มต้น 8)" }
      },
      "required": ["query"]
    }
    """

    private let source: any WebSearching

    /// The backend is a protocol so P13.1 can swap SearXNG for the app's own
    /// headless browser without the agent's contract moving (§1.4.1).
    public init(source: any WebSearching = SearXNGSource()) {
        self.source = source
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let arguments = try Arguments(argumentsJSON)
        let query = try arguments.string("query")
        let limit = arguments.int("limit") ?? 8

        let results: [WebResult]
        do {
            results = try await source.search(query, limit: limit)
        } catch {
            // "Search is down" and "nothing matched" lead to different next
            // moves, so the model is told which happened.
            throw ToolError.executionFailed("ค้นเว็บไม่ได้: \(error)")
        }
        guard !results.isEmpty else {
            return ToolOutput(text: "ไม่พบผลลัพธ์บนเว็บสำหรับ: \(query)")
        }

        let rendered = results.enumerated().map { position, result in
            """
            [\(position + 1)] \(result.title)
                \(result.url.absoluteString) · \(result.tier.rawValue.uppercased()) · \(result.engine)
                \(result.snippet.prefix(200))
            """
        }.joined(separator: "\n\n")

        return ToolOutput(text: rendered + "\n\nอ่านหน้าจริงด้วย fetch_page ก่อนอ้างอิง",
                          artifacts: results.map(\.url.absoluteString))
    }
}

/// Reads one page properly. The tool the citation rule depends on.
public struct FetchPageTool: AgentTool {
    public let name = "fetch_page"
    public let toolDescription = """
    เปิดอ่านหน้าเว็บหรือ PDF หนึ่งหน้าแล้วสกัดเป็นข้อความจริง (ตัดเมนู/โฆษณา/ท้ายหน้าออก) \
    คืนเป็นย่อหน้าพร้อมเลขย่อหน้าและ tier ของแหล่ง เพื่อให้อ้างอิงได้ระดับย่อหน้า
    """
    public let riskLevel: RiskLevel = .low
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "url": { "type": "string", "description": "URL ที่จะอ่าน (http/https เท่านั้น)" },
        "max_paragraphs": { "type": "integer", "description": "จำนวนย่อหน้าสูงสุด (ค่าเริ่มต้น 40)" }
      },
      "required": ["url"]
    }
    """

    private let fetcher: any PageReading

    /// A protocol, so P13.1's browser-backed reader can be dropped in and the
    /// citation rules do not move (§1.4.1). `PageFetcher` remains the default:
    /// nothing that does not need a DOM should start a web view.
    public init(fetcher: any PageReading = PageFetcher()) {
        self.fetcher = fetcher
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let arguments = try Arguments(argumentsJSON)
        let address = try arguments.string("url")
        let maximum = arguments.int("max_paragraphs") ?? 40

        let page: FetchedPage
        do {
            page = try await fetcher.fetch(address)
        } catch {
            throw ToolError.executionFailed("\(error)")
        }

        let body = page.paragraphs.prefix(maximum).enumerated()
            .map { "(\($0.offset + 1)) \($0.element)" }
            .joined(separator: "\n\n")
        let truncated = page.paragraphs.count > maximum
            ? "\n\n… เหลืออีก \(page.paragraphs.count - maximum) ย่อหน้า"
            : ""

        return ToolOutput(text: """
        \(page.title ?? page.finalURL.absoluteString)
        \(page.finalURL.absoluteString) · \(page.provenance.tier?.rawValue.uppercased() ?? "T5")

        \(body)\(truncated)
        """, artifacts: [page.finalURL.absoluteString])
    }
}

// MARK: - arguments

/// Shared JSON argument reading. The gate's schema critic has already checked
/// the shape by the time a tool runs; this is the second line, and it fails
/// with a message the model can act on rather than a decoding error.
struct Arguments {
    private let values: [String: Any]

    init(_ json: String) throws {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ToolError.invalidArguments("อ่าน arguments ไม่ได้: \(json.prefix(120))") }
        values = object
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.invalidArguments("ต้องมี \(key) เป็นข้อความที่ไม่ว่าง")
        }
        return value
    }

    func int(_ key: String) -> Int? {
        values[key] as? Int ?? (values[key] as? String).flatMap(Int.init)
    }

    func strings(_ key: String) -> [String] {
        values[key] as? [String] ?? []
    }

    /// A list of numbers. JSON gives back `NSNumber`, so integers and doubles
    /// arrive indistinguishably and both have to be accepted.
    func numbers(_ key: String) throws -> [Double] {
        guard let raw = values[key] as? [Any] else {
            throw ToolError.invalidArguments("ต้องมี \(key) เป็นรายการตัวเลข")
        }
        return try raw.map {
            guard let number = $0 as? NSNumber else {
                throw ToolError.invalidArguments("\(key) มีค่าที่ไม่ใช่ตัวเลข: \($0)")
            }
            return number.doubleValue
        }
    }

    /// A list of lists of numbers — groups, or a contingency table.
    func matrix(_ key: String) throws -> [[Double]] {
        guard let raw = values[key] as? [[Any]] else {
            throw ToolError.invalidArguments("ต้องมี \(key) เป็นรายการของรายการตัวเลข")
        }
        return try raw.map { row in
            try row.map {
                guard let number = $0 as? NSNumber else {
                    throw ToolError.invalidArguments("\(key) มีค่าที่ไม่ใช่ตัวเลข: \($0)")
                }
                return number.doubleValue
            }
        }
    }
}
