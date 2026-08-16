import Foundation

// ─────────────────────────────────────────────────────────────
// How text gets into a field (§23.1, P17.2).
//
// The driver used to write `kAXValueAttribute` first and fall back to
// keystrokes only when that was refused, on the reasoning that a field which
// accepts a written value is cheaper and less disruptive to write to. Measured
// on the real app, that reasoning has a hole in it:
//
//   ค้นข้อความในบทสนทนาเก่า → typed "หมดไฟ" → the field showed หมดไฟ
//   → the result list did not move, for any word, including words sitting
//     verbatim in a stored message
//
// The word search was fine — the same query over the same 42 messages pulled
// out of the live database scores 4.168 offline. What had not happened was the
// *search*. `AXUIElementSetAttributeValue` writes the control's presentation
// and returns `.success`; it does not travel the responder chain, so SwiftUI's
// binding never changed, and a view that re-runs on `.task(id: query)` had
// nothing to re-run on.
//
// **A write the control accepts is not a write the app noticed** — and the
// driver cannot tell the two apart, because from the outside they look
// identical: the value is on screen either way. The only version of this that
// is safe by construction is to put text in the way a person does, so the
// ordering is inverted: **keystrokes are the path, and writing the value is the
// fallback** for a field that will not take focus.
//
// This costs a keystroke per character on a field that would have accepted one
// assignment. That is the correct trade: the expensive failure is not a slow
// test, it is a driver that reports success while the app under it did nothing
// — which is the same class of silent lie as clicking at a coordinate.
// ─────────────────────────────────────────────────────────────

public enum TextEntry: Sendable, Equatable {
    /// Synthesised key events, through the same path a keyboard uses. The
    /// default, because it is the only one the application layer is guaranteed
    /// to see.
    case keyboard
    /// Writing `kAXValueAttribute` directly. Reaches the control without
    /// reaching whatever is watching it, so it is used only where keystrokes
    /// cannot land at all.
    case writeValue

    /// - Parameter canFocus: whether the field took keyboard focus. A field
    ///   that cannot be focused cannot be typed into, and for that one case
    ///   writing the value is better than doing nothing.
    public static func plan(canFocus: Bool) -> TextEntry {
        canFocus ? .keyboard : .writeValue
    }

    /// What the evidence line says, so a QA reader can tell which happened
    /// without reading this file (§23.3).
    public var note: String {
        switch self {
        case .keyboard: "พิมพ์ผ่านคีย์บอร์ด"
        case .writeValue: "เขียนค่าลงช่องโดยตรง (ช่องรับโฟกัสไม่ได้) — แอปอาจไม่รู้ว่าค่าเปลี่ยน"
        }
    }
}
