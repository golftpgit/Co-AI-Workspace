import Foundation
import AgentKit
import Observability
import Knowledge

// ─────────────────────────────────────────────────────────────
// `widen_view` (ARCHITECTURE §21.2, P12.6) — how an agent asks to see more.
//
// The alternative designs are both worse. Letting an agent search without a
// view when it finds nothing makes the whole of §21.2 advisory. Making the
// person edit a manifest mid-conversation makes the answer to "I cannot see
// enough" a five-minute detour into a text file.
//
// So it is a tool, and being a tool means it goes through the hook chain like
// everything else: scored, possibly approved, always recorded. Four properties
// hold whatever the arguments say:
//
//  • **Additive only.** `KnowledgeView.widened` cannot narrow anything, so
//    this cannot be used to hide material from a role — including hiding the
//    rules from itself, which `policy` being unremovable already prevents.
//  • **It expires with the conversation.** Nothing here writes to a manifest.
//    An agent that could edit its own manifest would be granting itself
//    permanent access to material somebody deliberately kept out of its view.
//  • **A reason is required.** A widening nobody can explain later is one
//    nobody can review, and the review is the point — §21.2 gives the Reviewer
//    a narrow view precisely so that what the maker saw is a question with an
//    answer.
//  • **It needs a role.** A turn with no role attached is the person at the
//    keyboard, who is not filtered and has nothing to widen.
// ─────────────────────────────────────────────────────────────

public struct WidenViewTool: AgentTool {
    public let name = "widen_view"
    public let toolDescription = """
    ขอขยายมุมมองความรู้ของบทบาทนี้ชั่วคราวในบทสนทนานี้ เมื่อค้นแล้วไม่พบเพราะถูกกรองออก \
    — ขยายได้อย่างเดียว แคบลงไม่ได้ · ต้องบอกเหตุผล และเหตุผลจะถูกบันทึกไว้ให้ผู้ตรวจอ่าน
    """
    /// Not high: it changes what one agent can read for the rest of one
    /// conversation, and it is written down. Not low either — it is an agent
    /// expanding its own reach, which the cautious setting should stop to ask
    /// about even though the balanced one need not.
    public let riskLevel: RiskLevel = .medium
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "reason": { "type": "string",
                    "description": "ทำไมมุมมองปัจจุบันถึงไม่พอ — จะถูกบันทึกไว้" },
        "min_tier": { "type": "string", "enum": ["t1","t2","t3","t4","t5"],
                      "description": "ลดพื้นความน่าเชื่อถือลงถึงระดับนี้" },
        "any_tier": { "type": "boolean", "description": "รับทุกแหล่ง รวมข้อมูลปฐมภูมิที่ไม่มี tier" },
        "allow_incomplete_citations": { "type": "boolean",
                                        "description": "รับ chunk ที่อ้างอิงไม่ครบ (เฉพาะ Writer)" },
        "hops": { "type": "integer", "description": "เดินกราฟลึกขึ้นเป็นกี่ชั้น" }
      },
      "required": ["reason"]
    }
    """

    private let widenings: ViewWidenings
    /// Where the record of a widening goes. Optional like every other sink in
    /// this project: the tool works without observability, it just cannot be
    /// asked afterwards what anybody was allowed to see.
    private let spans: (any SpanSink)?
    private let baseView: @Sendable (Role) -> KnowledgeView

    public init(widenings: ViewWidenings,
                spans: (any SpanSink)? = nil,
                baseView: @escaping @Sendable (Role) -> KnowledgeView = KnowledgeView.standard(for:)) {
        self.widenings = widenings
        self.spans = spans
        self.baseView = baseView
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Self.reason(from: argumentsJSON)
        guard context.role != nil else {
            throw ToolError.invalidArguments(
                "เทิร์นนี้ไม่ได้ผูกกับบทบาทไหน จึงไม่มีมุมมองให้ขยาย — "
                    + "คำถามจากคนที่หน้าจอไม่ได้ถูกกรองอยู่แล้ว")
        }
        guard context.conversationID != nil else {
            throw ToolError.invalidArguments(
                "การขยายมุมมองผูกกับบทสนทนา และเทิร์นนี้ไม่มีบทสนทนาให้ผูก")
        }
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let reason = try Self.reason(from: argumentsJSON)
        guard let role = context.role, let conversation = context.conversationID else {
            throw ToolError.invalidArguments("ต้องมีบทบาทและบทสนทนา")
        }
        let object = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]

        let current = await widenings.view(for: role, conversation: conversation)
            ?? baseView(role)
        let anyTier = object["any_tier"] as? Bool ?? false
        let floor = anyTier ? nil : (object["min_tier"] as? String).flatMap(SourceTier.init(rawValue:))

        let widened = current.widened(
            minTier: floor,
            dropProvenanceRequirement: object["allow_incomplete_citations"] as? Bool ?? false,
            dropEvidenceOnly: false,   // the Reviewer's narrow view is not negotiable by the Reviewer
            hops: object["hops"] as? Int)

        await widenings.grant(ViewWidenings.Grant(role: role, reason: reason, view: widened),
                              conversation: conversation)

        // §21.2 / P12.6 — the record a reviewer reads. It goes on a span
        // rather than into `Evidence`, which is where it was heading and where
        // it does not fit: `Evidence` requires `passed: Bool`, and "what this
        // role could see" is not a pass or a fail. Forcing it into one would
        // produce a flag nobody can read the meaning of.
        if let spans {
            var span = Span(name: "view:widened", role: role, scope: context.scope,
                            status: .succeeded)
            span.endedAt = Date()
            span.detail = "\(reason) · \(widened.describedForReview)"
            await spans.record(span)
        }

        return ToolOutput(text: """
            ขยายมุมมองของบทบาท \(role.rawValue) แล้วสำหรับบทสนทนานี้เท่านั้น
            เดิม: \(current.describedForReview)
            ตอนนี้: \(widened.describedForReview)
            เหตุผลที่บันทึกไว้: \(reason)

            มุมมองนี้หมดอายุพร้อมบทสนทนา ไม่ได้แก้ไฟล์ manifest — \
            และผู้ตรวจจะเห็นว่างานชิ้นนี้ทำขึ้นตอนที่มุมมองถูกขยายไว้
            """)
    }

    private static func reason(from argumentsJSON: String) throws -> String {
        let object = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8))) as? [String: Any]
        let reason = (object?["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard reason.count >= 10 else {
            throw ToolError.invalidArguments(
                "ต้องบอกเหตุผลที่ต้องขยายมุมมอง — การขยายที่อธิบายทีหลังไม่ได้ คือการขยายที่ตรวจไม่ได้")
        }
        return reason
    }
}
