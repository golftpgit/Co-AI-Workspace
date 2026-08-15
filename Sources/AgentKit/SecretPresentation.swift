import Foundation

// ─────────────────────────────────────────────────────────────
// How a secret is described on screen (P9.3).
//
// In the app because the app is where secrets are entered; in a library target
// because it is the part with rules in it, and the app target has no tests.
//
// Two things it exists to get right:
//
//  • **A value is never part of a description.** There is no case here that
//    returns even a prefix of a secret. A key on screen is a key in a
//    screenshot, in a screen recording, and in whatever the user pastes into a
//    chat asking why it does not work.
//  • **"Could not read" is its own tone.** `SecretStore` keeps `.unreadable`
//    apart from `.absent`; if the screen then paints both of them as the same
//    grey "not set", the distinction was for nothing (U21-2's rule, on a
//    different screen).
//
// And one thing worth saying out loud rather than hiding: a secret that came
// from the environment is **not** as well kept as one in the Keychain. A
// `launchctl setenv` value is readable by every process this user runs. It
// still works, and the screen says which one it is.
// ─────────────────────────────────────────────────────────────

public enum SecretPresentation {

    public struct Display: Sendable, Equatable {
        public let text: String
        public let tone: Tone
        /// Whether a "remove" control makes sense — there is something to remove.
        public let canRemove: Bool

        public enum Tone: Sendable, Equatable {
            /// Stored where it should be.
            case ok
            /// Works, with a caveat the person should know about.
            case caution
            /// Nothing is set. Ordinary, not an error.
            case missing
            /// We could not find out. Never the same as `missing`.
            case problem
        }
    }

    public static func display(name: String?, status: SecretStatus) -> Display {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Display(text: "ยังไม่ได้ตั้งชื่อให้ความลับนี้ จึงยังเก็บค่าไม่ได้",
                           tone: .missing, canRemove: false)
        }
        switch status {
        case .present(.keychain):
            return Display(text: "ตั้งไว้แล้ว · เก็บใน Keychain ของเครื่องนี้",
                           tone: .ok, canRemove: true)
        case .present(.environment):
            return Display(text: "มาจาก environment ไม่ใช่ Keychain — "
                           + "ค่าแบบนี้ทุกโปรเซสของผู้ใช้คนนี้อ่านได้ · "
                           + "บันทึกทับที่นี่เพื่อย้ายเข้า Keychain",
                           tone: .caution, canRemove: false)
        case .present(.override):
            return Display(text: "กำลังใช้ค่าทดสอบที่ตั้งไว้ในโปรเซสนี้",
                           tone: .caution, canRemove: false)
        case .absent:
            return Display(text: "ยังไม่ได้ตั้ง", tone: .missing, canRemove: false)
        case .unreadable(let detail):
            return Display(text: "อ่าน Keychain ไม่ได้ (\(detail)) — "
                           + "**ยังไม่ได้แปลว่ายังไม่ได้ตั้ง** อย่าเพิ่งกรอกใหม่ทับ",
                           tone: .problem, canRemove: false)
        }
    }

    public static func display(name: String?) -> Display {
        display(name: name, status: name.map { SecretStore.status($0) } ?? .absent)
    }
}
