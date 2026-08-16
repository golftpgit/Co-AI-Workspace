import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// P10.11 — the order of a plan could only be changed by deleting a package
// and adding it again at the end, so a plan written slightly out of sequence
// stayed that way.
//
// The rules are about what a drop must *not* quietly do: re-parent a package,
// or renumber one row and leave the rest describing a different sequence.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_order")
private let done = [Criterion(text: "ตรวจได้", evidenceRequired: "exit 0")]

private func node(_ id: String, parent: String? = nil, order: Int) -> WorkPackage {
    WorkPackage(id: id, projectID: project, parent: parent, title: id,
                scopeRef: "ขอบเขต", acceptanceCriteria: done,
                raci: RACI(accountable: .teamLead), order: order)
}

/// Three siblings under one root, plus a sibling elsewhere.
private let plan = WorkBreakdown([
    node("root", order: 0),
    node("a", parent: "root", order: 0),
    node("b", parent: "root", order: 1),
    node("c", parent: "root", order: 2),
    node("other", order: 1),
])

@Suite("Reordering a plan (P10.11)")
struct WBSReorderTests {

    @Test("moving a package down puts it where the target was")
    func moveDown() {
        let changed = plan.reordering("a", toPositionOf: "c")
        let orders = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0.order) })
        // b, c shift up; a lands last.
        #expect(orders["b"] == 0)
        #expect(orders["c"] == 1)
        #expect(orders["a"] == 2)
    }

    @Test("moving a package up puts it where the target was")
    func moveUp() {
        let changed = plan.reordering("c", toPositionOf: "a")
        let orders = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0.order) })
        #expect(orders["c"] == 0)
        #expect(orders["a"] == 1)
        #expect(orders["b"] == 2)
    }

    /// Everything whose number changed comes back. Returning only the dragged
    /// row leaves the others describing a sequence that no longer exists, and
    /// the next insert lands in the wrong place.
    @Test("every sibling whose number changed is returned, and no others")
    func wholeRunIsRenumbered() {
        let changed = plan.reordering("a", toPositionOf: "b")
        #expect(Set(changed.map(\.id)) == ["a", "b"])
        // `c` did not move, so it is not rewritten — a write per row on every
        // drag is a change-control entry per row.
        #expect(changed.contains { $0.id == "c" } == false)
    }

    /// Re-parenting changes what the plan says, not the order it says it in.
    /// That is a different act, and a drop must not perform it by accident.
    @Test("a package cannot be dropped onto one with a different parent")
    func crossParentIsRefused() {
        #expect(plan.reordering("a", toPositionOf: "other").isEmpty)
        #expect(plan.reordering("other", toPositionOf: "b").isEmpty)
    }

    @Test("dropping a package on itself changes nothing")
    func selfDropIsNothing() {
        #expect(plan.reordering("a", toPositionOf: "a").isEmpty)
        #expect(plan.reordering("ghost", toPositionOf: "a").isEmpty)
    }

    @Test("the traversal reads back in the new order")
    func orderedReflectsTheMove() {
        var packages = plan.packages
        for changed in plan.reordering("c", toPositionOf: "a") {
            packages.removeAll { $0.id == changed.id }
            packages.append(changed)
        }
        let after = WorkBreakdown(packages)
        #expect(after.children(of: "root").map(\.id) == ["c", "a", "b"])
    }
}
