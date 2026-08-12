import Foundation
import AgentKit
import Analysis
import Observability

// ─────────────────────────────────────────────────────────────
// `pull_db_table` (ARCHITECTURE §M6, §12.2, P6.3).
//
// The connectors, the attach, the copy and the read-only guarantee all exist
// and are tested. What existed only as a button on one screen was the way to
// use them, so an agent asked to analyse a table in somebody's Postgres had no
// route to it at all.
//
// **Only saved connectors.** The tool takes an alias, never a connection
// string: a tool that accepted a DSN would be a tool a model could point at any
// host, with credentials it composed itself. What it can reach is what a person
// already saved and scoped (§12.2) — and the secret is still read from the
// environment at attach time, never passed through here.
// ─────────────────────────────────────────────────────────────

public struct PullDBTableTool: AgentTool {
    public let name = "pull_db_table"
    public let toolDescription = """
    คัดลอกตารางจากฐานข้อมูลภายนอกที่บันทึกไว้แล้ว เข้ามาเป็นตารางในคลังข้อมูลวิเคราะห์ \
    ใช้เมื่อจะวิเคราะห์ข้อมูลนั้นซ้ำหลายรอบ (สำเนาไม่ช้าและไม่กวนฐานข้อมูลต้นทาง) \
    ระบุแหล่งด้วย 'alias' ของแหล่งที่ผู้ใช้บันทึกไว้เท่านั้น — ไม่รับ connection string \
    ดูรายชื่อแหล่งและตารางได้จากผลลัพธ์เมื่อเรียกโดยไม่ระบุ 'table'
    """
    /// §5.3's table. It writes a table into the store and touches somebody
    /// else's database, even if only to read it.
    public let riskLevel: RiskLevel = .medium
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "alias": { "type": "string", "description": "ชื่อย่อของแหล่งข้อมูลที่บันทึกไว้" },
        "table": { "type": "string",
          "description": "ตารางที่จะดึง (ไม่ระบุ = คืนรายชื่อตารางที่มีในแหล่งนั้น)" },
        "as": { "type": "string", "description": "ชื่อตารางในคลัง (ไม่ระบุ = ชื่อเดิม)" }
      },
      "required": ["alias"]
    }
    """

    private let store: @Sendable () async -> AnalysisStore?
    /// Synchronous on purpose: reading the saved list costs a file read, and
    /// having it available in `precheck` is what lets a wrong alias go back to
    /// the model as a correctable mistake instead of spending somebody's
    /// approval on a call that cannot work (§5.3).
    private let connectors: @Sendable () -> [DBConnector]
    private let log = AppLog.logger("analysis")

    public init(store: @escaping @Sendable () async -> AnalysisStore?,
                connectors: @escaping @Sendable () -> [DBConnector]) {
        self.store = store
        self.connectors = connectors
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try resolve(try Request(argumentsJSON), context: context)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let request = try Request(argumentsJSON)
        let connector = try resolve(request, context: context)
        guard let store = await store() else {
            throw ToolError.executionFailed("คลังข้อมูลวิเคราะห์เปิดไม่ได้ตอนเริ่มแอป")
        }

        let available: [String]
        do {
            _ = try await store.attach(connector)
            available = try await store.tables(in: connector.alias)
        } catch {
            throw ToolError.executionFailed("ต่อกับ '\(request.alias)' ไม่ได้: \(error)")
        }

        guard let table = request.table else {
            // Asked without a table: answer with what is there rather than an
            // error. A model that has to guess a table name will guess.
            return ToolOutput(text: available.isEmpty
                              ? "แหล่ง '\(request.alias)' ต่อได้แล้วแต่ไม่มีตาราง"
                              : "ตารางใน '\(request.alias)': "
                                + available.sorted().joined(separator: ", "))
        }
        guard available.contains(table) else {
            throw ToolError.invalidArguments(
                "ไม่มีตาราง '\(table)' ใน '\(request.alias)' — ที่มีคือ: "
                + available.sorted().joined(separator: ", "))
        }

        do {
            _ = try await store.pull(table, from: request.alias, into: request.localName)
            let local = request.localName ?? table
            let count = try await store.query("SELECT count(*) FROM \(AnalysisStore.quoted(local))")
            let rows = count.rows.first?.first.flatMap { $0 } ?? "?"
            log.info("pulled \(table, privacy: .public) from \(request.alias, privacy: .public)")
            return ToolOutput(
                text: "ดึงตาราง '\(table)' จาก '\(request.alias)' เข้ามาเป็น '\(local)' แล้ว "
                    + "(\(rows) แถว) — ใช้ `analysis_query` อ่านต่อได้เลย",
                artifacts: [local])
        } catch {
            throw ToolError.executionFailed("ดึงตารางไม่สำเร็จ: \(error)")
        }
    }

    /// Everything about this call that can be decided from the saved list.
    private func resolve(_ request: Request, context: ToolContext) throws -> DBConnector {
        let saved = connectors()
        guard let connector = saved.first(where: { $0.alias == request.alias }) else {
            let names = saved.map(\.alias).sorted()
            throw ToolError.invalidArguments(
                "ไม่มีแหล่งข้อมูลชื่อ '\(request.alias)'"
                + (names.isEmpty ? " — ยังไม่มีแหล่งที่บันทึกไว้เลย"
                                 : " — ที่มีคือ: \(names.joined(separator: ", "))"))
        }
        // §12.2 — a connector belongs to a scope, and a project's data is not a
        // thing another project's turn may reach into.
        guard connector.scope == context.scope || connector.scope == .central else {
            throw ToolError.notPermitted(
                "แหล่ง '\(request.alias)' อยู่ในขอบเขตอื่น จึงเข้าถึงจากงานนี้ไม่ได้")
        }
        guard connector.secretIsAvailable || connector.secretVariable == nil else {
            throw ToolError.notPermitted(
                "แหล่ง '\(request.alias)' ยังไม่ได้ตั้งตัวแปร \(connector.secretVariable ?? "") ที่เก็บรหัสผ่าน")
        }
        return connector
    }

    private struct Request {
        let alias: String
        let table: String?
        let localName: String?

        init(_ json: String) throws {
            struct Payload: Decodable {
                let alias: String
                let table: String?
                let `as`: String?
            }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)),
                  !payload.alias.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ToolError.invalidArguments("ต้องระบุ 'alias' ของแหล่งข้อมูลที่บันทึกไว้")
            }
            alias = payload.alias
            table = payload.table?.isEmpty == true ? nil : payload.table
            localName = payload.as?.isEmpty == true ? nil : payload.as
        }
    }
}
