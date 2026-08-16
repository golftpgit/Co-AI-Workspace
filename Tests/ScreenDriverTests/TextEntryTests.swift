import Testing
@testable import ScreenDriver

// ─────────────────────────────────────────────────────────────
// Which way text goes into a field (P17.2).
//
// The rule is small and the reason is not: writing `kAXValueAttribute` succeeds
// on a SwiftUI `TextField` and leaves the binding untouched, so the value is on
// screen and the app has not noticed. Measured on the real app — typing a Thai
// word into the conversation search moved the text and not the results, for
// every word tried, including ones sitting verbatim in a stored message.
//
// Tested here rather than against a live screen because the decision is the
// whole of the fix; the syscall it leads to is not something a test can watch.
// ─────────────────────────────────────────────────────────────

@Suite("How text is put into a field")
struct TextEntryTests {

    @Test("a field that takes focus is typed into")
    func focusableFieldsAreTyped() {
        #expect(TextEntry.plan(canFocus: true) == .keyboard)
    }

    @Test("only a field that cannot be focused gets its value written")
    func unfocusableFieldsAreWritten() {
        #expect(TextEntry.plan(canFocus: false) == .writeValue)
    }

    @Test("writing the value says out loud that the app may not have noticed")
    func writingSaysWhatItCannotPromise() {
        // The evidence line is what a QA reader sees, and "typed the word" for
        // a write that never reached the application is the sentence this whole
        // change exists to stop being printed.
        #expect(TextEntry.writeValue.note.contains("อาจไม่รู้ว่าค่าเปลี่ยน"))
        #expect(!TextEntry.keyboard.note.contains("อาจไม่รู้"))
    }
}
