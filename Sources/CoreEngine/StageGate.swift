import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Stage Gate (ARCHITECTURE §19.4, P10.2) — the fifth link in the chain, and
// the first one that asks about the *project* rather than the call.
//
// It sits before the Risk Scorer for the same reason the Critic does: a tool
// the current stage forbids should never reach a human's attention, and never
// cost a policy query. Whether the arguments are dangerous is irrelevant when
// the project has not agreed on what it is doing yet.
//
// The classification lives here rather than on `AgentTool` for the same reason
// the risk table does (§5.3): a tool that could declare its own effect could
// declare its way past the gate. A manifest saying `run_shell` is "read-only"
// must not be able to run it during Initiation.
// ─────────────────────────────────────────────────────────────

/// What a tool does to the world — a coarser axis than risk, and a different
/// one. `ingest_url` is medium risk and harmless to a plan; `analysis_execute`
/// is the same risk and changes data the plan is about.
public enum ToolEffect: String, Sendable, Equatable, CaseIterable {
    /// Reads. Allowed in every stage, including after closing — a closed
    /// project must stay readable or it is not an audit trail.
    case read
    /// Produces something inside the workspace: a document, a chunk in the
    /// knowledge base, a skill. Reversible, and it is what Planning is for.
    case authoring
    /// Changes data, files or the machine. Only while the project is executing.
    case mutating
}

public struct StageGate: Sendable {
    /// Keyed by the same names as `DefaultRiskScorer.baseline`, and
    /// `scripts/check.sh` fails if the two ever disagree: a tool classified for
    /// risk but not for effect would silently get the most permissive stage
    /// treatment, which is the quiet-default failure this project keeps
    /// finding the expensive way.
    static let effects: [String: ToolEffect] = [
        "kb_search": .read,
        "web_search": .read,
        "fetch_page": .read,
        "fetch_docs": .read,
        "read_file": .read,
        "analysis_query": .read,

        "ingest_url": .authoring,
        "save_document": .authoring,
        "write_skill": .authoring,

        "write_file": .mutating,
        "analysis_execute": .mutating,
        "pull_db_table": .mutating,
        "run_shell": .mutating,
        "r_eval": .mutating,
        "r_install_package": .mutating,
        "install_package": .mutating,
    ]

    /// What each stage allows (§19.4).
    ///
    /// Closing allows authoring because that is when the reports are written,
    /// and forbids mutating because the numbers they report must not still be
    /// moving.
    static func allows(_ effect: ToolEffect, in stage: ProjectStage) -> Bool {
        switch stage {
        case .initiation: return effect == .read
        case .planning: return effect != .mutating
        case .execution: return true
        case .closing: return effect != .mutating
        case .closed: return effect == .read
        }
    }

    private let reader: (any ProjectStageReading)?

    /// A gate with no way to read a stage. Named rather than defaulted to
    /// silence: in General there is no project and nothing to gate, which is
    /// legitimate — but a *project-scoped* call still gets refused below,
    /// because "we cannot check" is not "it is fine".
    public static let disabled = StageGate(reader: nil)

    public init(reader: (any ProjectStageReading)?) {
        self.reader = reader
    }

    /// An unknown tool returns `.mutating`: the strictest reading, so a tool
    /// added without a row in the table is blocked outside Execution rather
    /// than waved through everywhere.
    static func effect(of toolName: String) -> ToolEffect {
        effects[toolName] ?? .mutating
    }

    /// `nil` to allow; a reason, in the user's words, to block.
    func refusal(for call: PendingToolCall) async -> String? {
        guard case .project(let id) = call.context.scope else { return nil }

        let effect = Self.effect(of: call.toolName)
        guard let reader else {
            return "เรียก '\(call.toolName)' ในขอบเขตของโปรเจกต์ไม่ได้ — ระบบอ่านขั้นของโครงการไม่ได้"
        }
        guard let stage = await reader.stage(of: id) else {
            return "ไม่พบโปรเจกต์ '\(id.rawValue)' — จึงตรวจไม่ได้ว่าอยู่ขั้นไหน"
        }
        guard Self.allows(effect, in: stage) else {
            return Self.reason(tool: call.toolName, effect: effect, stage: stage)
        }
        // §19.10 — an open exception stops new work, and reading is what a
        // person needs in order to decide. Checked after the stage so the more
        // specific reason wins when both apply.
        if effect != .read, await reader.hasOpenException(id) {
            return "โครงการทะลุกรอบที่ตกลงไว้และกำลังรอคำตัดสิน — '\(call.toolName)' จึงยังไม่ทำงาน (อ่านข้อมูลได้ตามปกติ)"
        }
        return nil
    }

    private static func reason(tool: String, effect: ToolEffect, stage: ProjectStage) -> String {
        let what = switch effect {
        case .read: "อ่านข้อมูล"
        case .authoring: "สร้างเอกสาร/ความรู้"
        case .mutating: "เปลี่ยนข้อมูล ไฟล์ หรือรันคำสั่ง"
        }
        let next = switch stage {
        case .initiation: "ต้องผ่าน G1 (ขอบเขต ทำ/ไม่ทำ + เหตุผลที่ทำ) ก่อน"
        case .planning: "ต้องผ่าน G2 (เกณฑ์รับงาน) ก่อนถึงจะลงมือได้"
        case .closing: "ขั้นปิดโครงการเขียนรายงานได้ แต่ตัวเลขที่รายงานต้องไม่ขยับแล้ว"
        case .closed: "โครงการปิดแล้ว เปิดใหม่หรือสร้างโครงการใหม่ก่อน"
        case .execution: ""
        }
        return "'\(tool)' \(what) ซึ่งขั้น\(stage.label)ไม่อนุญาต — \(next)"
    }
}
