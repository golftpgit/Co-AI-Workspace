import Foundation
import ApplicationServices
import CoreGraphics

// ─────────────────────────────────────────────────────────────
// Permission this process cannot give itself (ARCHITECTURE §23.2, P17.3).
//
// Accessibility, Input Monitoring and Screen Recording are granted by a person
// in System Settings. Nothing here can ask for them convincingly, and trying to
// make that smooth is how an app ends up nagging. What this file does instead
// is make the *state* legible: which of the three are on, which are missing,
// and — the case that costs the most time — **that a permission granted
// yesterday is gone today because the binary was signed again**.
//
// That last one is not hypothetical. This app is ad-hoc signed (R11), TCC keys
// on the signature, and the symptom is a driver that worked last week doing
// nothing at all with no error anywhere. It is one of the concrete reasons to
// notarise, and until then it is at least detectable: the last known state is
// remembered, and a permission that went from granted to missing is reported as
// *revoked* rather than as *never granted*.
// ─────────────────────────────────────────────────────────────

public struct ScreenPermission: Sendable, Equatable {
    public enum Capability: String, Sendable, Codable, CaseIterable {
        case accessibility
        case screenRecording

        /// Where the person has to go. Named exactly as the pane is, because
        /// "grant accessibility permission" is not an instruction anybody can
        /// follow on a machine they have not configured before.
        public var settingsPane: String {
            switch self {
            case .accessibility: "การตั้งค่าระบบ → ความเป็นส่วนตัวและความปลอดภัย → การช่วยการเข้าถึง"
            case .screenRecording: "การตั้งค่าระบบ → ความเป็นส่วนตัวและความปลอดภัย → การบันทึกหน้าจอ"
            }
        }

        public var neededFor: String {
            switch self {
            case .accessibility: "หาและกดปุ่มบนหน้าจอ (ชั้นหลักของตัวขับ)"
            case .screenRecording: "เก็บภาพก่อน/หลังไว้เป็นหลักฐาน"
            }
        }
    }

    public let granted: Set<Capability>
    /// Granted before and not now — the ad-hoc signing case (§23.2 rule 2).
    public let revoked: Set<Capability>

    public init(granted: Set<Capability>, revoked: Set<Capability> = []) {
        self.granted = granted
        self.revoked = revoked
    }

    /// The one capability the driver cannot work at all without.
    public var canDrive: Bool { granted.contains(.accessibility) }
    /// Evidence can still be an accessibility snapshot without this; a picture
    /// is better and not required (§23.3).
    public var canCapture: Bool { granted.contains(.screenRecording) }

    /// What to tell the person, in the order they have to do it.
    ///
    /// Never "permission denied": that sentence has stopped meaning anything.
    /// A revoked permission says so and says why, because "turn it on" is
    /// useless advice to somebody looking at a switch that is already on — the
    /// entry has to be removed and re-added after a rebuild.
    public var instructions: [String] {
        var lines: [String] = []
        for capability in Capability.allCases where revoked.contains(capability) {
            lines.append("""
                \(capability.rawValue): **เคยอนุญาตไว้แล้วแต่ตอนนี้ใช้ไม่ได้** — \
                แอปถูก build ใหม่และลายเซ็นเปลี่ยน สิทธิ์ TCC ผูกกับลายเซ็น \
                ต้องเอารายการเดิมออกจาก\(capability.settingsPane) แล้วเพิ่มกลับเข้าไปใหม่ \
                (สวิตช์ที่เปิดค้างอยู่ไม่ได้แปลว่าใช้ได้)
                """)
        }
        for capability in Capability.allCases
        where !granted.contains(capability) && !revoked.contains(capability) {
            lines.append("\(capability.rawValue): ยังไม่ได้อนุญาต — เปิดที่\(capability.settingsPane) "
                         + "· ต้องใช้เพื่อ\(capability.neededFor)")
        }
        return lines
    }
}

/// Reads the live state, and remembers it so a revocation is tellable from a
/// permission that was never given.
public struct ScreenPermissionReader: Sendable {
    /// Where the last known state is kept. A file rather than `UserDefaults`
    /// because the question is about *this binary on this machine*, and a
    /// person debugging it has to be able to look.
    private let memory: URL?

    public init(rememberingIn memory: URL? = nil) {
        self.memory = memory
    }

    public func read() -> ScreenPermission {
        var granted: Set<ScreenPermission.Capability> = []
        // `AXIsProcessTrusted` asks without prompting. The prompting variant
        // exists and is not used: a dialog raised by a background check is a
        // dialog nobody can connect to anything they did.
        if AXIsProcessTrusted() { granted.insert(.accessibility) }
        if CGPreflightScreenCaptureAccess() { granted.insert(.screenRecording) }

        let remembered = lastKnown()
        let revoked = remembered.subtracting(granted)
        remember(granted)
        return ScreenPermission(granted: granted, revoked: revoked)
    }

    // MARK: - what was true last time

    func lastKnown() -> Set<ScreenPermission.Capability> {
        guard let memory, let data = try? Data(contentsOf: memory),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names.compactMap(ScreenPermission.Capability.init(rawValue:)))
    }

    func remember(_ granted: Set<ScreenPermission.Capability>) {
        guard let memory else { return }
        // Only ever *adds*: forgetting that a permission was once granted is
        // what would make a revocation look like a first run, which is the one
        // thing this file exists to prevent.
        let merged = lastKnown().union(granted)
        guard let data = try? JSONEncoder().encode(merged.map(\.rawValue).sorted()) else { return }
        try? FileManager.default.createDirectory(
            at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: memory, options: .atomic)
    }
}
