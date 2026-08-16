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

/// Tools that stop for a person no matter what the autonomy slider says
/// (ARCHITECTURE §5.5, P14.4).
///
/// Not a property on the tool. `RunShellTool`'s header already gives the
/// reason: a tool's own declaration is not what protects anything, because a
/// manifest can declare whatever it likes. This list lives beside the scorer,
/// where the chain reads it and the tool cannot.
///
/// **The principle, so the list can grow honestly.** A high risk level means
/// "this could go badly", and `fullAutonomous` is a considered decision that
/// the person will accept those odds while they are away. That trade needs the
/// damage to be *visible afterwards* — a file overwritten, a command that
/// failed, a row deleted — because seeing it is what makes accepting the odds
/// reasonable. An entry belongs here when it is not: when the action runs code
/// nobody in this system wrote, or changes the machine in a way the result
/// never mentions. "The model was confident" is not an answer to either.
public enum AlwaysAsk {
    /// `install_package` downloads other people's code and runs it — an sdist
    /// executes its own `setup.py` during installation. Whatever it did then
    /// is not in the tool's output, not in the transcript, and not visible in
    /// whatever the package is later used for.
    ///
    /// `r_install_package` is here for the same reason, and `r_eval` refuses
    /// the install calls it could otherwise smuggle: this list is keyed on the
    /// tool name, so an install hidden inside a block of R would be exactly the
    /// hole the list exists to close (P14.4).
    public static let toolNames: Set<String> = ["install_package", "r_install_package"]

    public static func requiresHuman(_ toolName: String) -> Bool {
        toolNames.contains(toolName)
    }
}

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
        // Arbitrary R on the person's machine, with their libraries and their
        // files (§12.7). "It is only statistics" does not lower it.
        "r_eval": .high,
        "r_install_package": .high,
    ]

    /// Names classified above for tools that **do not exist yet**, each with
    /// the task that owes it.
    ///
    /// Declared rather than deleted, and declared rather than left to be
    /// noticed later: `scripts/check.sh` fails if a name in `baseline` has no
    /// `AgentTool` behind it *and* is not listed here, so the set of intended
    /// tools is finite, visible, and cannot grow by accident. That rule exists
    /// because nine names sat in the table above with nothing implementing
    /// them, four of them wrapping capabilities that were finished, tested and
    /// reachable from nothing — found by reading the plan by hand (2026-08-12),
    /// which is not a method anybody should have to rely on.
    static let notBuiltYet: [String: String] = [
        "read_file": "M6 FileTool — ยังไม่มี task ผูก",
        "write_file": "M6 FileTool — ยังไม่มี task ผูก",

        "fetch_docs": "M6 — ต้องมีแหล่งเอกสารก่อน",
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
