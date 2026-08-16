import Testing
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// Each tab remembers its own area (P21.1's Done-when).
//
// The first test is the one measured failing on the real app: three tabs, three
// different areas, and all three read back as the last one set (E.34). It is
// written the way the driving went, because that is the shape of the failure —
// not one switch, but a third tab proving the value was global rather than
// merely misfiled.
// ─────────────────────────────────────────────────────────────

private enum Area: String, Hashable, Sendable { case chat, plan, workbench, knowledge, system }

@Suite("Per-tab area memory")
struct TabAreaMemoryTests {

    @Test("three tabs keep three areas")
    func threeTabsThreeAreas() {
        var memory = TabAreaMemory<Area>()

        // tab1 on the workbench → general → knowledge → tab2 → system
        #expect(memory.moved(leaving: "tab1", showing: .workbench, arriving: "general") == .fresh)
        #expect(memory.moved(leaving: "general", showing: .knowledge, arriving: "tab2") == .fresh)

        // …and back around. Each one lands where it was left, which is the
        // sentence the plan row promises.
        #expect(memory.moved(leaving: "tab2", showing: .system, arriving: "tab1")
                == .restore(.workbench))
        #expect(memory.moved(leaving: "tab1", showing: .workbench, arriving: "general")
                == .restore(.knowledge))
        #expect(memory.moved(leaving: "general", showing: .knowledge, arriving: "tab2")
                == .restore(.system))
    }

    @Test("the tab being left is filed under its own name, not the one arrived at")
    func theLeftTabIsFiledUnderItself() {
        var memory = TabAreaMemory<Area>()
        _ = memory.moved(leaving: "tab1", showing: .workbench, arriving: "tab2")
        // The exact misfiling that made every tab agree: banking the outgoing
        // area under the incoming id.
        #expect(memory.recorded(for: "tab1") == .workbench)
        #expect(memory.recorded(for: "tab2") == nil)
    }

    @Test("a tab that has never been opened is fresh, and says so rather than guessing")
    func unvisitedTabIsFresh() {
        var memory = TabAreaMemory<Area>()
        #expect(memory.moved(leaving: "general", showing: .plan, arriving: "new") == .fresh)
    }

    @Test("closing a tab forgets it, so reopening starts fresh")
    func closingForgets() {
        var memory = TabAreaMemory<Area>()
        _ = memory.moved(leaving: "tab1", showing: .workbench, arriving: "general")
        memory.closed("tab1")
        #expect(memory.moved(leaving: "general", showing: .plan, arriving: "tab1") == .fresh)
    }

    @Test("switching a tab to itself leaves it where it is")
    func selfSwitchIsNotAReset() {
        // Reconciliation and a redraw can both re-announce the same tab. If
        // that read as a switch to an unvisited tab, looking at a workspace
        // long enough would move you to Chat on its own.
        var memory = TabAreaMemory<Area>()
        #expect(memory.moved(leaving: "tab1", showing: .workbench, arriving: "tab1")
                == .restore(.workbench))
    }
}
