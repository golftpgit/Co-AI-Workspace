import Foundation
import Testing

// ─────────────────────────────────────────────────────────────
// The regression net for decisions the system makes on its own (P9.1).
//
// The row this closes was blocked on "there has to be real finished work first",
// which was true of the shape it was first imagined in — replaying whole agent
// runs — and led nowhere, because replaying a run needs a model and a model is
// the one thing a check on a laptop cannot have.
//
// The part worth pinning does not involve a model at all. Before anything is
// asked of an LLM, this system has already decided **which tier will answer and
// why**, **how dangerous a tool call is and why**, and **which statistical test
// a question means**. Those three are pure functions of the request. They are
// also where a quiet regression is most expensive: nothing crashes, nothing
// fails, the answers just start coming from a smaller model, or a shell command
// stops asking, and the first sign is in somebody's results weeks later.
//
// So: a fixed set of tasks, and the decisions written down in a file next to
// this one. The file is the point. An assertion inside a test says "this should
// be high risk"; a golden file says **what the whole set of decisions looks
// like today**, and a diff against it is reviewable by somebody who was not
// here when it was written. Changing behaviour is allowed — it takes a visible
// edit to a checked-in file, in the same commit that changes the behaviour,
// which is the only thing this is trying to force.
//
// Rewrite the file deliberately with:
//
//     COAI_GOLDEN_UPDATE=1 swift test --filter GoldenTaskTests
//
// and read the diff before committing it. A golden test that is easier to
// regenerate than to think about is a golden test that will be regenerated
// without thinking.
// ─────────────────────────────────────────────────────────────

enum Golden {
    /// Next to this source file, so it travels with the tests and shows up in
    /// review as an ordinary text diff.
    static func url(_ name: String) -> URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: name)
    }

    static var isUpdating: Bool {
        ProcessInfo.processInfo.environment["COAI_GOLDEN_UPDATE"] == "1"
    }

    /// Compares `actual` against the recorded file, or rewrites it when asked.
    ///
    /// The failure names the first line that differs rather than printing both
    /// documents: a 60-line diff in test output is a wall nobody reads, and the
    /// first differing line is almost always the whole story.
    static func check(_ actual: String, against name: String,
                      sourceLocation: SourceLocation = #_sourceLocation) throws {
        let file = url(name)
        if isUpdating {
            try actual.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        guard let expected = try? String(contentsOf: file, encoding: .utf8) else {
            Issue.record("ยังไม่มีไฟล์อ้างอิง \(name) — สร้างด้วย COAI_GOLDEN_UPDATE=1",
                         sourceLocation: sourceLocation)
            return
        }
        guard expected != actual else { return }

        let old = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let new = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let first = zip(old, new).enumerated().first { $0.element.0 != $0.element.1 }
        let detail: String
        if let first {
            detail = "บรรทัดที่ \(first.offset + 1)\n  เดิม: \(first.element.0)\n  ใหม่: \(first.element.1)"
        } else {
            detail = "จำนวนบรรทัดต่างกัน: เดิม \(old.count) ใหม่ \(new.count)"
        }
        Issue.record("""
        การตัดสินใจเปลี่ยนไปจากที่บันทึกไว้ใน \(name) — \(detail)

        ถ้าตั้งใจเปลี่ยน ให้รัน COAI_GOLDEN_UPDATE=1 swift test --filter GoldenTaskTests
        แล้ว**อ่าน diff ก่อน commit** — ไฟล์นี้มีไว้ให้คนอ่าน ไม่ใช่ให้เครื่องเขียนทับเงียบ ๆ
        """, sourceLocation: sourceLocation)
    }
}
