import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Risk Scorer (ARCHITECTURE §5.3).
//
// The scorer takes three inputs — the tool, its arguments and the context —
// and it never takes the tool's word for it. `AgentTool.riskLevel` is a floor
// the tool may raise, never a ceiling it may lower: a custom manifest that
// declares `run_shell` as "low" must not be able to walk past the gate.
// ─────────────────────────────────────────────────────────────

public struct RiskAssessment: Sendable, Equatable {
    public let level: RiskLevel
    /// Why, in the user's words — this is what the approval sheet shows when
    /// it asks. "Risky" with no reason is not an explanation.
    public let reasons: [String]

    public init(level: RiskLevel, reasons: [String]) {
        self.level = level
        self.reasons = reasons
    }
}

public protocol RiskScoring: Sendable {
    func score(toolName: String,
               declared: RiskLevel,
               argumentsJSON: String,
               context: ToolContext) -> RiskAssessment
}

public struct DefaultRiskScorer: RiskScoring {
    /// Carried over from v1 (§5.3). Kept as a table rather than a per-tool
    /// property so the classification lives on this side of the gate.
    static let baseline: [String: RiskLevel] = [
        "kb_search": .low,
        "web_search": .low,
        "fetch_page": .low,
        "fetch_docs": .low,
        "read_file": .low,
        "analysis_query": .low,

        "write_file": .medium,
        "analysis_execute": .medium,
        "save_document": .medium,
        "pull_db_table": .medium,
        "ingest_url": .medium,
        "write_skill": .medium,

        "run_shell": .high,
        "install_package": .high,
    ]

    /// Substrings that turn an ordinary command into a destructive one. Crude
    /// on purpose: this decides whether to *ask*, and a false alarm costs one
    /// click while a miss costs a home directory.
    static let destructivePatterns: [(needle: String, why: String)] = [
        ("rm -rf", "ลบไฟล์แบบ recursive"),
        ("rm -fr", "ลบไฟล์แบบ recursive"),
        ("sudo ", "ยกระดับสิทธิ์"),
        ("mkfs", "ฟอร์แมตดิสก์"),
        ("dd if=", "เขียนดิสก์ระดับ block"),
        ("diskutil ", "จัดการดิสก์"),
        ("shutdown", "สั่งปิด/รีสตาร์ตเครื่อง"),
        ("reboot", "สั่งปิด/รีสตาร์ตเครื่อง"),
        ("killall", "ฆ่าโปรเซสเป็นชุด"),
        ("chmod 777", "เปิดสิทธิ์ทั้งหมดให้ไฟล์"),
        ("git push --force", "เขียนทับประวัติ remote"),
        ("git push -f", "เขียนทับประวัติ remote"),
        ("git reset --hard", "ทิ้งงานที่ยังไม่ commit"),
        ("git clean -", "ลบไฟล์ที่ยังไม่ track"),
        ("curl", "ดาวน์โหลดจากเน็ต"),
        ("wget", "ดาวน์โหลดจากเน็ต"),
        ("launchctl", "แก้บริการระบบ"),
        ("defaults write", "แก้ค่าตั้งระบบ"),
        ("> /dev/", "เขียนลง device node"),
        ("/etc/", "แตะไฟล์ระบบ"),
        ("~/.ssh", "แตะคีย์ SSH"),
        ("keychain", "แตะ Keychain"),
    ]

    /// A downloaded script piped straight into a shell is the one pattern that
    /// is high risk even when every word in it looks harmless.
    static let pipeToShell = ["| sh", "| bash", "| zsh", "|sh", "|bash"]

    public init() {}

    public func score(toolName: String,
                      declared: RiskLevel,
                      argumentsJSON: String,
                      context: ToolContext) -> RiskAssessment {
        var reasons: [String] = []

        // An unknown tool — an MCP server we have never classified, say — is
        // high until someone classifies it (§10). Unknown is not low.
        let base = Self.baseline[toolName] ?? {
            reasons.append("เครื่องมือ '\(toolName)' ยังไม่ถูกจัดระดับความเสี่ยง")
            return RiskLevel.high
        }()

        var level = max(base, declared)
        if declared > base {
            reasons.append("เครื่องมือประกาศความเสี่ยงสูงกว่าค่าเริ่มต้นเอง")
        }

        let haystack = argumentsJSON.lowercased()
        for pattern in Self.destructivePatterns where haystack.contains(pattern.needle) {
            reasons.append("อาร์กิวเมนต์มี '\(pattern.needle)' — \(pattern.why)")
            level = .high
        }
        for pipe in Self.pipeToShell where haystack.contains(pipe) {
            reasons.append("ดาวน์โหลดแล้วส่งเข้า shell ทันที")
            level = .high
        }

        // Policy scope is the workspace's own rulebook; nothing writes to it
        // without a human (§11.2).
        if context.scope.isPolicy && level > .low {
            reasons.append("แตะข้อมูลใน scope 'policy'")
            level = .high
        }

        if reasons.isEmpty {
            reasons.append("ระดับเริ่มต้นของเครื่องมือ '\(toolName)'")
        }
        return RiskAssessment(level: level, reasons: reasons)
    }
}
