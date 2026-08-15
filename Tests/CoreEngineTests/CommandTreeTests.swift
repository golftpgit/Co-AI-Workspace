import Testing
import Foundation
import AgentKit
import Observability
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// P16.5 — the board that shows who is working, and the one thing it must
// never do: say a team is working when it has finished.
// ─────────────────────────────────────────────────────────────

private let base = Date(timeIntervalSince1970: 1_770_000_000)

private func span(_ id: String, parent: String? = nil, name: String,
                  role: Role? = nil, status: SpanStatus = .running,
                  started: TimeInterval = 0, ended: TimeInterval? = nil) -> Span {
    var span = Span(id: SpanID(id), parent: parent.map(SpanID.init),
                    name: name, role: role, scope: .central, status: status,
                    startedAt: base.addingTimeInterval(started))
    span.endedAt = ended.map { base.addingTimeInterval($0) }
    return span
}

@Suite("The command tree (P16.5)")
struct CommandTreeTests {

    @Test("the chain of command comes out of the spans, not out of a second record")
    func treeFollowsParents() {
        let tree = CommandTree.build(from: [
            span("ic", name: "ic", started: 0),
            span("research", parent: "ic", name: "team.research", started: 1),
            span("a1", parent: "research", name: "researcher: หาเอกสาร",
                 role: .researcher, started: 2),
            span("engineering", parent: "ic", name: "team.engineering", started: 3),
        ])

        #expect(tree.count == 1)
        #expect(tree[0].name == "ic")
        #expect(tree[0].children.map(\.name) == ["team.research", "team.engineering"])
        #expect(tree[0].children[0].children.first?.role == .researcher)
    }

    /// The Done-when, and the failure that would make the whole board
    /// untrustworthy the first time somebody noticed it.
    @Test("a team whose span has closed is not shown as working")
    func closedSpansAreNotWorking() {
        let tree = CommandTree.build(from: [
            span("ic", name: "ic"),
            span("done", parent: "ic", name: "team.research",
                 status: .succeeded, started: 1, ended: 9),
            span("busy", parent: "ic", name: "team.engineering", started: 2),
        ])

        let nodes = tree[0].children
        #expect(nodes[0].isWorking == false)
        #expect(nodes[1].isWorking)
        #expect(CommandTree.working(in: tree) == 2)   // the IC itself is still open
    }

    /// The half a status field alone gets wrong: a process that died between
    /// finishing the work and writing the result leaves `running` behind.
    @Test("a span with an end time is finished even if its status still says running")
    func endedIsFinishedWhateverTheStatusSays() {
        let tree = CommandTree.build(from: [
            span("crashed", name: "team.research", status: .running, ended: 5),
        ])
        #expect(tree[0].isWorking == false)
        #expect(CommandTree.spoken(tree[0], depth: 0).contains("จบไปแล้วโดยไม่มีการปิดสถานะ"))
    }

    @Test("waiting for a person looks different from working")
    func waitingIsItsOwnState() {
        // One needs patience and the other needs somebody: a board that draws
        // them the same way costs the second one its urgency.
        let tree = CommandTree.build(from: [
            span("ask", name: "อนุมัติ run_shell", status: .awaitingApproval),
        ])
        #expect(tree[0].needsAPerson)
        #expect(tree[0].isWorking == false)
        #expect(CommandTree.spoken(tree[0], depth: 0).contains("รอคนตัดสินใจ"))
    }

    @Test("a branch whose top is outside the window is shown, not dropped")
    func orphansBecomeRoots() {
        // The usual reason is a query window that starts after the parent did.
        // Losing the branch would make the board quietly wrong; showing it at
        // the root makes it visibly partial.
        let tree = CommandTree.build(from: [
            span("child", parent: "not-in-this-window", name: "team.research"),
        ])
        #expect(tree.count == 1)
        #expect(tree[0].name == "team.research")
    }

    /// §14.4: everything reachable by eye is reachable by ear. Indentation says
    /// nothing to somebody listening, so depth, state and duration are words.
    @Test("every row says its depth, its state and how long it took, out loud")
    func rowsAreSpoken() {
        let tree = CommandTree.build(from: [
            span("ic", name: "ic"),
            span("t", parent: "ic", name: "team.research", role: .researcher,
                 status: .succeeded, started: 1, ended: 61),
        ])
        let spoken = CommandTree.spoken(tree[0].children[0], depth: 1)
        #expect(spoken.contains("ชั้นที่ 2"))
        #expect(spoken.contains("บทบาท researcher"))
        #expect(spoken.contains("เสร็จแล้ว"))
        #expect(spoken.contains("60 วินาที"))

        let parent = CommandTree.spoken(tree[0], depth: 0)
        #expect(parent.contains("มีงานย่อย 1 รายการ"),
                "a listener cannot see that this row has children")
    }

    @Test("a loop in the stored parents does not hang the screen")
    func cyclesAreBounded() {
        // Nothing writes a cycle today. A dashboard that hangs the app if
        // anything ever does is not a trade worth making.
        var a = span("a", parent: "b", name: "a")
        let b = span("b", parent: "a", name: "b")
        a.status = .running
        let tree = CommandTree.build(from: [a, b])
        #expect(tree.isEmpty == false || tree.isEmpty)   // it returns, which is the point
    }
}
