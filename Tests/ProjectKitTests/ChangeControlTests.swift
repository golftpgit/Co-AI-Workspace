import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// Editing a plan that is already an agreement (§19.2.4, §19.11, P10.16).
//
// The Done-when has three parts, and two of them are about *not* being able to
// do something:
//
//  • an edit after G2 produces a change request that states its impact on scope,
//    time and money before anybody confirms;
//  • RACI cannot be given two accountable people from the UI — which is tested
//    by the type having one field and no case that takes a `Role`, plus a
//    structural rule in check.sh that the screen's letter list has no A in it;
//  • Gantt bars cannot be dragged, which is a structural rule for the same
//    reason: it is the absence of a gesture, and absences rot silently.
//
// What is tested here is the first, plus the two properties that make it honest:
// the preview is computed by applying the edit (not by describing it), and an
// estimate with no basis says so instead of printing a zero.
// ─────────────────────────────────────────────────────────────

private let criteria = [Criterion(text: "α ≥ 0.70", evidenceRequired: "ผลรัน")]

private func agreedProject() -> Project {
    var project = Project(name: "ความเครียดพยาบาล", kind: .research, brief: "วัดความชุก",
                          statement: ScopeStatement(inScope: ["ความชุก"],
                                                    outOfScope: ["ข้ามวิชาชีพ"],
                                                    acceptanceCriteria: ["ส่งวารสารได้"]),
                          board: [BoardRole(seat: .executive, person: "ผู้ใช้")])
    project.stage = .execution
    return project
}

private func leaf(_ project: Project, _ title: String,
                  status: WorkPackageStatus = .backlog) -> WorkPackage {
    var package = WorkPackage(projectID: project.id, title: title, scopeRef: "ความชุก",
                              acceptanceCriteria: criteria,
                              raci: RACI(accountable: .teamLead))
    package.status = status
    return package
}

@Suite("Change control on an agreed plan")
struct ChangeControlTests {

    @Test("before a baseline exists, editing the plan is writing the plan")
    func nothingToChangeYet() {
        let project = agreedProject()
        let wbs = WorkBreakdown([leaf(project, "ตารางที่ 2")])
        let proposal = ChangeControl.proposal(
            for: .savePackage(leaf(project, "ตารางที่ 3")),
            project: project, wbs: wbs, baseline: nil, existingChanges: 0)
        // No bar, no change request, no ceremony. G2 has not happened.
        #expect(proposal == nil)
    }

    @Test("adding a leaf after the baseline becomes a numbered change request")
    func addingAfterBaselineAsks() throws {
        let project = agreedProject()
        let existing = leaf(project, "ตารางที่ 2")
        let wbs = WorkBreakdown([existing])
        let baseline = Baseline.freeze(project, wbs: wbs, version: 1, reason: "ผ่าน G2")

        let proposal = try #require(ChangeControl.proposal(
            for: .savePackage(leaf(project, "ภาคผนวก ก")),
            project: project, wbs: wbs, baseline: baseline, existingChanges: 3))

        #expect(proposal.requestNumber == 4)
        #expect(proposal.scopeImpact.contains("+1 packages"))
        // The one line §19.2.4 asks for, with all three impacts in it.
        #expect(proposal.headline.contains("change request #4"))
        #expect(proposal.headline.contains("scope"))
        #expect(proposal.headline.contains("time"))
        #expect(proposal.headline.contains("money"))
        // And the register entry carries the same three, not a re-derivation.
        if case .change(let scope, let time, let cost) = proposal.detail {
            #expect(scope == proposal.scopeImpact)
            #expect(time == proposal.timeImpact)
            #expect(cost == proposal.costImpact)
        } else {
            Issue.record("รายการที่ได้ไม่ใช่คำขอเปลี่ยนแปลง")
        }
    }

    @Test("an estimate with nothing to estimate from says so, not zero")
    func noBasisIsStated() throws {
        let project = agreedProject()
        let wbs = WorkBreakdown([leaf(project, "ตารางที่ 2")])
        let baseline = Baseline.freeze(project, wbs: wbs, version: 1, reason: "ผ่าน G2")

        let blind = try #require(ChangeControl.proposal(
            for: .savePackage(leaf(project, "ภาคผนวก ก")),
            project: project, wbs: wbs, baseline: baseline, existingChanges: 0))
        // "เวลา +0" would be quoted in a meeting as "no delay expected".
        #expect(blind.timeImpact.contains("cannot be estimated"))
        #expect(blind.costImpact.contains("cannot be estimated"))

        // With one finished leaf that took 30 minutes and $120 spent, the same
        // edit can be estimated — and the estimate names what it rests on.
        let finished = leaf(project, "ตารางที่ 2", status: .done)
        let measured = WorkBreakdown([finished])
        let informed = try #require(ChangeControl.proposal(
            for: .savePackage(leaf(project, "ภาคผนวก ก")),
            project: project, wbs: measured,
            baseline: Baseline.freeze(project, wbs: measured, version: 1, reason: "ผ่าน G2"),
            existingChanges: 0,
            basis: ChangeEstimateBasis(elapsedByPackage: [finished.id: 1_800],
                                       spent: 120, costMeasured: true)))
        #expect(informed.timeImpact.contains("+30 minutes"))
        #expect(informed.timeImpact.contains("averaged over 1 finished packages"))
        #expect(informed.costImpact.contains("$120"))
    }

    @Test("moving a tolerance after the baseline is a change to the agreement")
    func tolerancesAreAgreedToo() throws {
        let project = agreedProject()
        let wbs = WorkBreakdown([leaf(project, "ตารางที่ 2")])
        let baseline = Baseline.freeze(project, wbs: wbs, version: 1, reason: "ผ่าน G2")

        var loosened = project.tolerances
        loosened.limits[.cost] = 5_000
        let proposal = try #require(ChangeControl.proposal(
            for: .tolerances(loosened), project: project, wbs: wbs,
            baseline: baseline, existingChanges: 0))
        // A baseline holds the frame as well as the plan, and `BaselineDiff`
        // deliberately does not look at it — so this is the case that would have
        // slipped through if the guard only asked the diff.
        #expect(proposal.title.contains("Cost"))
        #expect(proposal.scopeImpact.contains("the plan did not"))
    }

    @Test("an edit that changes nothing agreed does not ask for a change request")
    func noOpDoesNotAsk() {
        let project = agreedProject()
        let package = leaf(project, "ตารางที่ 2")
        let wbs = WorkBreakdown([package])
        let baseline = Baseline.freeze(project, wbs: wbs, version: 1, reason: "ผ่าน G2")

        // Saving the same leaf unchanged, and doing work on it. Neither is a
        // change to the plan — status is the plan happening, not the plan moving.
        #expect(ChangeControl.proposal(for: .savePackage(package), project: project,
                                       wbs: wbs, baseline: baseline,
                                       existingChanges: 0) == nil)
        var working = package
        working.status = .inProgress
        #expect(ChangeControl.proposal(for: .savePackage(working), project: project,
                                       wbs: wbs, baseline: baseline,
                                       existingChanges: 0) == nil)
    }

    @Test("removing a parent counts its whole branch, like the store does")
    func removingABranchIsReportedInFull() throws {
        let project = agreedProject()
        let parent = WorkPackage(projectID: project.id, title: "บทที่ 3",
                                 acceptanceCriteria: [])
        var childA = leaf(project, "ตารางที่ 2")
        childA.parent = parent.id
        var childB = leaf(project, "ตารางที่ 3")
        childB.parent = parent.id
        let wbs = WorkBreakdown([parent, childA, childB])
        let baseline = Baseline.freeze(project, wbs: wbs, version: 1, reason: "ผ่าน G2")

        let proposal = try #require(ChangeControl.proposal(
            for: .removePackage(id: parent.id, title: parent.title),
            project: project, wbs: wbs, baseline: baseline, existingChanges: 0))
        // Three rows go, not one. A preview that under-reports the edit people
        // most regret is worse than no preview.
        #expect(proposal.scopeImpact.contains("−3 packages"))
    }

    @Test("the preview is what gets applied")
    func previewMatchesCommit() {
        let project = agreedProject()
        let existing = leaf(project, "ตารางที่ 2")
        let wbs = WorkBreakdown([existing])
        let added = leaf(project, "ภาคผนวก ก")

        let (after, unchanged) = ChangeControl.applying(.savePackage(added),
                                                        to: wbs, of: project)
        #expect(after.packages.count == 2)
        #expect(unchanged == project)

        var renamed = existing
        renamed.title = "ตารางที่ 2 (แก้)"
        let (edited, _) = ChangeControl.applying(.savePackage(renamed), to: wbs, of: project)
        // Edited in place rather than appended: a rename that adds a second row
        // would show up as "+1 ใบ" in the very preview meant to describe it.
        #expect(edited.packages.count == 1)
        #expect(edited.packages.first?.title == "ตารางที่ 2 (แก้)")
    }

    @Test("applying an edit through the service opens the change request with it")
    func serviceRecordsTheRequest() async throws {
        let registers = MemoryRegisterStore()
        let baselines = MemoryBaselineStore()
        let service = ProjectService(store: MemoryProjectStore(), plans: MemoryPlanStore(),
                                     registers: registers, baselines: baselines)
        var project = try await service.create(
            name: "แก้หลังตกลง", brief: "b",
            statement: ScopeStatement(inScope: ["ความชุก"], outOfScope: ["อื่น"],
                                      acceptanceCriteria: ["ตรวจได้"]),
            board: [BoardRole(seat: .executive, person: "ผู้ใช้")])
        project.stage = .execution
        try await service.update(project)
        try await service.save(leaf(project, "ตารางที่ 2"))
        try await service.freezeBaseline(project, reason: "ผ่าน G2")

        // Before: nothing pending, so the gate has no undecided change to wait on.
        let added = leaf(project, "ภาคผนวก ก")
        let proposal = try #require(try await service.apply(.savePackage(added),
                                                           in: project.id, by: "ผู้ใช้"))
        #expect(proposal.requestNumber == 1)

        let changes = await service.entries(of: project.id, kind: .change)
        #expect(changes.count == 1)
        #expect(changes.first?.title == "Add work package: ภาคผนวก ก")
        // Proposed, not approved: §19.11 reserves the decision for a person, and
        // the edit landing does not decide it.
        #expect(changes.first?.status == .proposed)
        #expect(changes.first?.origin == .human("ผู้ใช้"))
        // The words the person was shown are kept, so the register and the bar
        // cannot disagree later.
        #expect(changes.first?.note.contains("change request #1") == true)
        // The edit really landed — this is not a "propose then maybe apply" flow.
        #expect(await service.breakdown(of: project.id).packages.count == 2)
        // And G3 is now shut on the undecided request (§19.11).
        let gate = try #require(await service.gate(for: project.id))
        #expect(gate.unmet.contains("No undecided change request"))
    }

    @Test("an edit before the baseline lands with no change request at all")
    func nothingRecordedBeforeG2() async throws {
        let registers = MemoryRegisterStore()
        let service = ProjectService(store: MemoryProjectStore(), plans: MemoryPlanStore(),
                                     registers: registers,
                                     baselines: MemoryBaselineStore())
        let project = try await service.create(name: "ยังวางแผน")
        #expect(try await service.apply(.savePackage(leaf(project, "ใบแรก")),
                                        in: project.id) == nil)
        #expect(await service.entries(of: project.id, kind: .change).isEmpty)
        #expect(await service.breakdown(of: project.id).packages.count == 1)
    }
}
