import Foundation
import AgentKit
import Analysis
import Observability

// ─────────────────────────────────────────────────────────────
// `analysis_query` and `analysis_execute` (ARCHITECTURE §M6, §12, P6.1/P6.2).
//
// The store worked and was tested against real DuckDB. The Analyst's tool list
// was `kb_search`, `run_shell`, `run_stat_test` — so the specialist whose whole
// job is analysis could not reach the analysis store, and would have had to
// shell out to get at it. Same gap as `ingest_url`, found the same way.
//
// **Why there are two tools rather than one with a flag.** §5.3 grades
// `analysis_query` low and `analysis_execute` medium, and a low-risk tool that
// *could* mutate would make that grading a lie. So the read-only one is
// structurally read-only: it puts every statement through `SQLGuard` — the same
// one the notebook and the DB explorer use (§12.5) — and refuses anything above
// a read, in `precheck`, before a human is asked about anything. It is low risk
// because it is checked, not because it is trusted.
// ─────────────────────────────────────────────────────────────

/// Shared rendering: a result table an LLM can read without a viewer.
enum AnalysisResultFormatter {
    /// Capped, and the cap is stated in the output. A model that receives 5,000
    /// rows spends its whole context on them and answers worse; a model told
    /// "first 50 of 5,000" can ask for an aggregate instead.
    static func text(_ result: QueryResult, limit: Int = 50) -> String {
        guard !result.columns.isEmpty else { return "(คำสั่งสำเร็จ ไม่มีผลลัพธ์เป็นตาราง)" }
        let header = result.columns.map(\.name).joined(separator: " | ")
        let types = result.columns.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        let shown = result.rows.prefix(limit).map { row in
            row.map { $0 ?? "NULL" }.joined(separator: " | ")
        }
        var text = "\(types)\n\(header)\n" + shown.joined(separator: "\n")
        if result.rows.count > limit {
            text += "\n… แสดง \(limit) จาก \(result.rows.count) แถว"
        } else {
            text += "\n(\(result.rows.count) แถว)"
        }
        return text
    }
}

public struct AnalysisQueryTool: AgentTool {
    public let name = "analysis_query"
    public let toolDescription = """
    รันคำสั่ง SQL แบบอ่านอย่างเดียวบนคลังข้อมูลวิเคราะห์ (DuckDB) แล้วคืนผลเป็นตาราง \
    ใช้สำรวจข้อมูลก่อนวิเคราะห์: `SHOW TABLES`, `DESCRIBE`, `SELECT` \
    คำสั่งที่เปลี่ยนข้อมูลจะถูกปฏิเสธที่นี่ — ใช้ `analysis_execute` สำหรับงานนั้น
    """
    public let riskLevel: RiskLevel = .low
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "sql": { "type": "string", "description": "คำสั่ง SELECT / SHOW / DESCRIBE" }
      },
      "required": ["sql"]
    }
    """

    private let store: @Sendable () async -> AnalysisStore?

    public init(store: @escaping @Sendable () async -> AnalysisStore?) {
        self.store = store
    }

    /// The whole reason this tool may be low risk. Refused here, so a mutating
    /// statement never even becomes an approval prompt.
    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        let sql = try Self.sql(argumentsJSON)
        let assessment = SQLGuard.assess(sql)
        guard assessment.effect == .read else {
            let verbs = assessment.mutating.map(\.verb).joined(separator: ", ")
            throw ToolError.notPermitted("""
                'analysis_query' อ่านได้อย่างเดียว แต่คำสั่งนี้มี \(verbs) — \
                ถ้าตั้งใจจะเปลี่ยนข้อมูลให้ใช้ 'analysis_execute' ซึ่งจะขออนุมัติก่อน
                """)
        }
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let sql = try Self.sql(argumentsJSON)
        try precheck(argumentsJSON: argumentsJSON, context: context)
        guard let store = await store() else {
            throw ToolError.executionFailed(
                "คลังข้อมูลวิเคราะห์เปิดไม่ได้ตอนเริ่มแอป — ดูรายละเอียดที่หน้าสถานะระบบ")
        }
        do {
            return ToolOutput(text: AnalysisResultFormatter.text(try await store.query(sql)))
        } catch {
            // The SQL comes back with the error on purpose: a model that is not
            // shown what it ran cannot fix it.
            throw ToolError.executionFailed("\(error)\nคำสั่งที่รัน: \(sql)")
        }
    }

    static func sql(_ json: String) throws -> String {
        struct Payload: Decodable { let sql: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)),
              !payload.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidArguments("ต้องระบุ 'sql'")
        }
        return payload.sql
    }
}

public struct AnalysisExecuteTool: AgentTool {
    public let name = "analysis_execute"
    public let toolDescription = """
    รันคำสั่ง SQL ที่เปลี่ยนข้อมูลบนคลังข้อมูลวิเคราะห์ (CREATE / INSERT / UPDATE / DELETE / DROP) \
    ใช้เตรียมตารางสำหรับการวิเคราะห์ — จะขออนุมัติก่อนรันเพราะเปลี่ยนข้อมูลจริง \
    ถ้าเพียงต้องการอ่าน ให้ใช้ `analysis_query`
    """
    public let riskLevel: RiskLevel = .medium
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "sql": { "type": "string", "description": "คำสั่งที่จะรัน" }
      },
      "required": ["sql"]
    }
    """

    private let store: @Sendable () async -> AnalysisStore?

    public init(store: @escaping @Sendable () async -> AnalysisStore?) {
        self.store = store
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try AnalysisQueryTool.sql(argumentsJSON)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let sql = try AnalysisQueryTool.sql(argumentsJSON)
        guard let store = await store() else {
            throw ToolError.executionFailed("คลังข้อมูลวิเคราะห์เปิดไม่ได้ตอนเริ่มแอป")
        }
        let assessment = SQLGuard.assess(sql)
        do {
            let result = try await store.query(sql)
            // What it did, in the words the confirmation sheet uses for a
            // person (§12.5) — a span that says "succeeded" and nothing else is
            // not a record of a DROP.
            let effects = assessment.statements
                .map { "\($0.verb) \($0.target ?? "")".trimmingCharacters(in: .whitespaces) }
                .joined(separator: " · ")
            return ToolOutput(text: "\(effects)\n" + AnalysisResultFormatter.text(result))
        } catch {
            throw ToolError.executionFailed("\(error)\nคำสั่งที่รัน: \(sql)")
        }
    }
}
