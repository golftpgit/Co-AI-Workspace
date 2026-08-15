import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// Projects as tabs (ARCHITECTURE §19.1.1, P21.1).
//
// The app has treated General and Project as two modes that swap: `selection`
// was one value and every screen was rebuilt on each change. These tests are
// about the four ways that assumption bites once there is more than one.
// ─────────────────────────────────────────────────────────────

private func project(_ id: String, _ name: String,
                     stage: ProjectStage = .execution) -> Project {
    Project(id: ProjectID(id), name: name, stage: stage)
}

@Suite("Projects as tabs — P21.1")
struct OpenWorkspacesTests {

    @Test("General is there from the start and cannot be closed")
    func generalIsPermanent() {
        var open = OpenWorkspaces()
        #expect(open.active == .general)
        #expect(open.entries.count == 1)

        open.close(.general)
        #expect(open.entries.count == 1, "General was closed")
        #expect(open.active == .general)
    }

    @Test("several projects are open at once, each its own tab")
    func manyAtOnce() {
        var open = OpenWorkspaces()
        open.open(project("pj_a", "ภาวะหมดไฟ"))
        open.open(project("pj_b", "คุณภาพการนอน"))

        #expect(open.entries.count == 3)
        #expect(open.openProjectIDs.map(\.rawValue) == ["pj_a", "pj_b"])
        #expect(open.active == .project(ProjectID("pj_b")))
        // The first one is still there — which is the entire point.
        #expect(open.isOpen(ProjectID("pj_a")))
    }

    // Two tabs on one project would be two views of one scope that disagree
    // about which of them saved last.
    @Test("opening something already open moves to it rather than duplicating")
    func openingTwiceFocuses() {
        var open = OpenWorkspaces()
        open.open(project("pj_a", "ภาวะหมดไฟ"))
        open.open(project("pj_b", "คุณภาพการนอน"))
        open.open(project("pj_a", "ภาวะหมดไฟ"))

        #expect(open.entries.count == 3)
        #expect(open.active == .project(ProjectID("pj_a")))
    }

    @Test("closing the tab you are on lands you on the neighbour, not General")
    func closingLandsOnTheNeighbour() {
        var open = OpenWorkspaces()
        open.open(project("pj_a", "ก"))
        open.open(project("pj_b", "ข"))
        open.open(project("pj_c", "ค"))
        open.focus(.project(ProjectID("pj_b")))

        open.close(.project(ProjectID("pj_b")))
        // Being thrown back to General is how you lose your place.
        #expect(open.active == .project(ProjectID("pj_c")))
    }

    @Test("closing the last tab falls back to the one before it")
    func closingTheLastTab() {
        var open = OpenWorkspaces()
        open.open(project("pj_a", "ก"))
        open.open(project("pj_b", "ข"))

        open.close(.project(ProjectID("pj_b")))
        #expect(open.active == .project(ProjectID("pj_a")))
        open.close(.project(ProjectID("pj_a")))
        #expect(open.active == .general)
    }

    @Test("closing a tab in the background does not move you")
    func closingABackgroundTab() {
        var open = OpenWorkspaces()
        open.open(project("pj_a", "ก"))
        open.open(project("pj_b", "ข"))

        open.close(.project(ProjectID("pj_a")))
        #expect(open.active == .project(ProjectID("pj_b")))
    }

    // Closing a window is not closing a project. Conflating them would let
    // somebody end a project by tidying their screen.
    @Test("closing a tab is not closing the project")
    func closingATabIsNotClosingAProject() {
        var open = OpenWorkspaces()
        let alive = project("pj_a", "ก")
        open.open(alive)
        open.close(.project(ProjectID("pj_a")))

        // Nothing here can say a project ended; reopening it is writable again.
        open.open(alive)
        #expect(open.activeIsWritable)
    }

    // §19.1.1: an archive opens to read and never to write, or the closing
    // report describes something that changed afterwards.
    @Test("an archived project opens read-only")
    func archiveIsReadOnly() {
        var open = OpenWorkspaces()
        open.open(project("pj_done", "ปิดแล้ว", stage: .closed))

        #expect(open.activeEntry.isArchived)
        #expect(open.activeIsWritable == false)
    }

    @Test("a project closed elsewhere stops being writable in a tab left open")
    func closedElsewhereBecomesReadOnly() {
        var open = OpenWorkspaces()
        open.open(project("pj_a", "ก"))
        #expect(open.activeIsWritable)

        // The list reloads and the project has since been closed.
        open.reconcile(with: [project("pj_a", "ก", stage: .closed)])
        #expect(open.activeIsWritable == false, "a stale tab stayed writable")
    }

    @Test("a renamed project's tab follows the new name")
    func titlesFollowTheProject() {
        var open = OpenWorkspaces()
        open.open(project("pj_a", "ชื่อเดิม"))
        open.reconcile(with: [project("pj_a", "ชื่อใหม่")])
        #expect(open.activeEntry.title == "ชื่อใหม่")
    }

    // A tab pointing at a deleted project is the same failure as a work
    // package that outlived its plan: it looks like a place you can go.
    @Test("a tab whose project was deleted is closed, and you land on General")
    func deletedProjectClosesItsTab() {
        var open = OpenWorkspaces()
        open.open(project("pj_a", "ก"))
        open.reconcile(with: [])

        #expect(open.entries.count == 1)
        #expect(open.active == .general)
    }

    @Test("focusing a tab that is not open changes nothing")
    func focusingSomethingClosed() {
        var open = OpenWorkspaces()
        open.open(project("pj_a", "ก"))
        open.focus(.project(ProjectID("pj_missing")))
        #expect(open.active == .project(ProjectID("pj_a")))
    }

    @Test("the active tab names the scope every screen should read")
    func activeScopeIsTheScope() {
        var open = OpenWorkspaces()
        #expect(open.activeScope == .central)
        open.open(project("pj_a", "ก"))
        #expect(open.activeScope == .project(ProjectID("pj_a")))
    }
}
