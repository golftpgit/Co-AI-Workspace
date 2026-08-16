import Foundation
import AgentKit
import ProjectKit
import Observability

// ─────────────────────────────────────────────────────────────
// `raise_risk` and `propose_change` (ARCHITECTURE §19.11, P10.8).
//
// The registers have been writable from the screen since P10.8, and the rule
// that matters — **an agent may propose and may not decide** — was only
// testable at the type level, because there was no tool layer to test it
// through. An agent that notices a risk mid-run and cannot file it either
// forgets it or writes it into prose nobody will read as a risk.
//
// The rule is kept by construction rather than by checking:
//
//  • **Origin is taken from the tool context, never from the arguments.**
//    There is no parameter an agent could pass to claim it was a person, which
//    is the only version of this rule that survives a manifest written by
//    somebody else.
//  • **A proposed change is filed as `proposed`, and nothing here can move it
//    on.** `decided(approve:by:)` takes a person's name and lives on the other
//    side of the gate; these tools cannot reach it. A change approved by the
//    thing that asked for it is not a change control.
//  • **A register belongs to a project.** Called outside one, both tools refuse
//    and say which screen it would have gone to — filing a project risk into
//    General would be filing it nowhere.
// ─────────────────────────────────────────────────────────────

/// What both tools need from the project layer. A protocol so the rule that an
/// agent cannot decide is testable without a database.
public protocol RegisterFiling: Sendable {
    func record(_ entry: RegisterEntry) async throws
}

extension ProjectService: RegisterFiling {}

public struct RaiseRiskTool: AgentTool {
    public let name = "raise_risk"
    public let toolDescription = """
    บันทึกความเสี่ยงที่พบระหว่างทำงานลงทะเบียนความเสี่ยงของโปรเจกต์ \
    ใช้เมื่อเจอสิ่งที่ *ยังไม่เกิด* แต่ถ้าเกิดจะกระทบงาน — ถ้ามันเกิดขึ้นแล้วให้ใช้คำว่าปัญหาในรายงานแทน \
    ระบุความน่าจะเป็นและผลกระทบ 1–5 ตามที่ประเมินจริง ไม่ใช่ให้ดูน่ากลัวหรือดูปลอดภัย
    """
    /// Writes to the project's permanent record. Not high — nothing is
    /// destroyed and a wrong entry is editable — but not low either: a risk
    /// register full of noise is a register nobody reads.
    public let riskLevel: RiskLevel = .medium
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "title": { "type": "string", "description": "ความเสี่ยงในหนึ่งประโยค" },
        "probability": { "type": "integer", "minimum": 1, "maximum": 5 },
        "impact": { "type": "integer", "minimum": 1, "maximum": 5 },
        "response": { "type": "string", "enum": ["avoid", "reduce", "transfer", "accept"] },
        "note": { "type": "string", "description": "รายละเอียดหรือสิ่งที่สังเกตเห็น" }
      },
      "required": ["title", "probability", "impact", "response"]
    }
    """

    private let service: @Sendable () async -> (any RegisterFiling)?

    public init(service: @escaping @Sendable () async -> (any RegisterFiling)?) {
        self.service = service
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Self.arguments(argumentsJSON)
        _ = try RegisterTools.project(in: context)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let (title, probability, impact, response, note) = try Self.arguments(argumentsJSON)
        let projectID = try RegisterTools.project(in: context)
        guard let service = await service() else {
            throw ToolError.executionFailed("ยังต่อกับทะเบียนของโปรเจกต์ไม่ได้")
        }

        let entry = RegisterEntry(
            projectID: projectID,
            title: title,
            detail: .risk(probability: probability, impact: impact, response: response),
            origin: RegisterTools.origin(for: context),
            note: note)
        try await service.record(entry)

        return ToolOutput(text: "บันทึกความเสี่ยงแล้ว: \(title) "
                          + "(โอกาส \(probability)/5 · ผลกระทบ \(impact)/5 · \(response.label)) "
                          + "— อยู่ในทะเบียนความเสี่ยงของโปรเจกต์ รอเจ้าของงานพิจารณา")
    }

    static func arguments(_ json: String) throws
        -> (title: String, probability: Int, impact: Int, response: RiskResponse, note: String) {
        struct Payload: Decodable {
            let title: String
            let probability: Int
            let impact: Int
            let response: String
            let note: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)),
              !payload.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.invalidArguments("ต้องมี 'title' ที่ไม่ว่าง")
        }
        guard (1...5).contains(payload.probability), (1...5).contains(payload.impact) else {
            // Clamping would file a made-up number under a name that says it
            // was assessed.
            throw ToolError.invalidArguments("โอกาสและผลกระทบต้องอยู่ระหว่าง 1 ถึง 5")
        }
        guard let response = RiskResponse(rawValue: payload.response) else {
            throw ToolError.invalidArguments(
                "response ต้องเป็นหนึ่งใน \(RiskResponse.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return (payload.title, payload.probability, payload.impact, response, payload.note ?? "")
    }
}

public struct ProposeChangeTool: AgentTool {
    public let name = "propose_change"
    public let toolDescription = """
    เสนอคำขอเปลี่ยนแปลงต่อสิ่งที่ตกลงกันไว้ (ขอบเขต เวลา หรือค่าใช้จ่าย) \
    **เสนอได้อย่างเดียว — คนเท่านั้นที่อนุมัติหรือปฏิเสธ** และการอนุมัติคือสิ่งที่สร้าง baseline เวอร์ชันถัดไป \
    ใช้เมื่อสิ่งที่ตกลงไว้ทำไม่ได้ตามเดิม ไม่ใช่ใช้แทนการทำงานให้เสร็จ
    """
    public let riskLevel: RiskLevel = .medium
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "title": { "type": "string", "description": "สิ่งที่ขอเปลี่ยน ในหนึ่งประโยค" },
        "scope_impact": { "type": "string", "description": "กระทบขอบเขตอย่างไร ('ไม่กระทบ' ได้)" },
        "time_impact": { "type": "string", "description": "กระทบเวลาอย่างไร" },
        "cost_impact": { "type": "string", "description": "กระทบค่าใช้จ่ายอย่างไร" },
        "note": { "type": "string", "description": "เหตุผลและสิ่งที่ทำให้ต้องขอเปลี่ยน" }
      },
      "required": ["title", "scope_impact", "time_impact", "cost_impact"]
    }
    """

    private let service: @Sendable () async -> (any RegisterFiling)?

    public init(service: @escaping @Sendable () async -> (any RegisterFiling)?) {
        self.service = service
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Self.arguments(argumentsJSON)
        _ = try RegisterTools.project(in: context)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let (title, scope, time, cost, note) = try Self.arguments(argumentsJSON)
        let projectID = try RegisterTools.project(in: context)
        guard let service = await service() else {
            throw ToolError.executionFailed("ยังต่อกับทะเบียนของโปรเจกต์ไม่ได้")
        }

        let entry = RegisterEntry(
            projectID: projectID,
            title: title,
            detail: .change(scopeImpact: scope, timeImpact: time, costImpact: cost),
            // `proposed`, and there is no argument here that could make it
            // anything else. Approval happens on the change screen, by a person
            // with a name (§19.11).
            status: .proposed,
            origin: RegisterTools.origin(for: context),
            note: note)
        try await service.record(entry)

        return ToolOutput(text: "ยื่นคำขอเปลี่ยนแปลงแล้ว: \(title) — สถานะ 'รอตัดสิน' "
                          + "· คนเป็นผู้อนุมัติหรือปฏิเสธที่หน้าทะเบียน และการอนุมัติจะสร้าง baseline ใหม่")
    }

    static func arguments(_ json: String) throws
        -> (title: String, scope: String, time: String, cost: String, note: String) {
        struct Payload: Decodable {
            let title: String
            let scope_impact: String
            let time_impact: String
            let cost_impact: String
            let note: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)),
              !payload.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.invalidArguments("ต้องมี 'title' ที่ไม่ว่าง")
        }
        // All three, always. A change request that leaves a column blank is one
        // whose cost is decided by whoever reads it most optimistically —
        // "ไม่กระทบ" is a real answer and takes one word.
        for (field, value) in [("scope_impact", payload.scope_impact),
                               ("time_impact", payload.time_impact),
                               ("cost_impact", payload.cost_impact)]
        where value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ToolError.invalidArguments(
                "'\(field)' ว่างไม่ได้ — ถ้าไม่กระทบให้เขียนว่า 'ไม่กระทบ'")
        }
        return (payload.title, payload.scope_impact, payload.time_impact,
                payload.cost_impact, payload.note ?? "")
    }
}

enum RegisterTools {
    /// The project this call is inside. A register entry outside a project has
    /// nowhere to be read from, so the refusal names where it would have gone.
    static func project(in context: ToolContext) throws -> ProjectID {
        guard case .project(let id) = context.scope else {
            throw ToolError.invalidArguments(
                "ทะเบียนเป็นของโปรเจกต์ — เปิดโปรเจกต์ก่อนแล้วค่อยบันทึก "
                    + "(ตอนนี้อยู่ในพื้นที่ทั่วไป ซึ่งไม่มีทะเบียนให้บันทึกลง)")
        }
        return id
    }

    /// Taken from the context, never from the arguments. This is the whole of
    /// "an agent cannot claim to be a person": there is no parameter to lie in.
    static func origin(for context: ToolContext) -> RegisterOrigin {
        .agent(context.role ?? .researcher)
    }
}
