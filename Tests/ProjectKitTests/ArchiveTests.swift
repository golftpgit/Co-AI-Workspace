import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// A closed project is an archive (ARCHITECTURE §19.1.1, P21.3).
//
// Closing has been a gate with eight conditions since P10.10 — and once it
// passed, **nothing stopped anybody editing the project afterwards.** A closing
// report is a claim about a state on a date, so a project that can still be
// changed makes every report describe something that moved after it was
// written.
//
// The refusal is at the service, not in the view: hiding a button leaves the
// agent's tools, the channels and every future screen able to write to an
// archive.
//
// There is exactly one carve-out — measuring a benefit — and it already has a
// test of its own in `ClosingTests.postProjectReview`. The test here is the
// other half of that pair: it checks the carve-out survives *this* rule, so
// that tightening the rule later cannot quietly take the review with it.
// ─────────────────────────────────────────────────────────────

private let done = [Criterion(text: "ตรวจได้", evidenceRequired: "exit 0")]

private func service() -> ProjectService {
    ProjectService(store: MemoryProjectStore(),
                   plans: MemoryPlanStore(),
                   exceptions: MemoryExceptionStore(),
                   registers: MemoryRegisterStore(),
                   baselines: MemoryBaselineStore(),
                   benefits: MemoryBenefitStore())
}

/// A project taken through the door that really closes it, rather than one
/// constructed at `.closed` — so the fixture exercises the same path the app
/// does, and the guard cannot pass by only recognising a hand-made state.
private func closedProject(_ service: ProjectService,
                           name: String = "ปิดแล้ว") async throws -> Project {
    let project = try await service.create(name: name)
    return try await service.terminate(project.id, reason: "จบรอบ")
}

@Suite("A closed project is read-only — P21.3")
struct ArchiveTests {

    @Test("editing a closed project is refused")
    func editingIsRefused() async throws {
        let service = service()
        var closed = try await closedProject(service)
        closed.brief = "แก้ทีหลัง"

        await #expect(throws: LifecycleError.projectIsArchived(name: "ปิดแล้ว")) {
            try await service.update(closed)
        }
    }

    @Test("adding or removing a work package in an archive is refused")
    func planEditsAreRefused() async throws {
        let service = service()
        let closed = try await closedProject(service)

        await #expect(throws: (any Error).self) {
            try await service.save(WorkPackage(projectID: closed.id, title: "งานใหม่",
                                               acceptanceCriteria: done))
        }
        await #expect(throws: (any Error).self) {
            try await service.removePackage("wp_x", from: closed.id)
        }
    }

    @Test("a leaf cannot be completed after the project closed")
    func completingIsRefused() async throws {
        let service = service()
        let closed = try await closedProject(service)

        await #expect(throws: (any Error).self) {
            try await service.complete("wp_x", in: closed.id,
                                       with: [Evidence(kind: .commandExit,
                                                       summary: "exit 0", passed: true)])
        }
    }

    @Test("a register entry cannot be filed against an archive")
    func registerWritesAreRefused() async throws {
        let service = service()
        let closed = try await closedProject(service)
        let late = RegisterEntry(projectID: closed.id, title: "ความเสี่ยงที่นึกออกทีหลัง",
                                 detail: .risk(probability: 3, impact: 4, response: .reduce),
                                 origin: .human("ผู้ใช้"))

        await #expect(throws: (any Error).self) { try await service.record(late) }
    }

    // §19.12's review date is usually months after closing. A measurement
    // **adds a fact** rather than changing an agreement, which is why it is the
    // one write closing does not stop.
    @Test("measuring a benefit after closing is still allowed")
    func benefitReviewSurvivesTheRule() async throws {
        let service = service()
        let project = try await service.create(name: "ปิดแล้วแต่ยังต้องวัด")
        let benefit = Benefit(projectID: project.id, title: "ต้นทุนต่อเคส",
                              measure: "บาทต่อเคส", baselineValue: 100, target: 80,
                              reviewAt: Date(), owner: .human("ผู้ใช้"))
        try await service.save(benefit)
        _ = try await service.terminate(project.id, reason: "จบรอบ")

        try await service.measure(benefit, value: 90, by: "ผู้ใช้", note: "ไตรมาสถัดมา")
        #expect(await service.benefitLedger(of: project.id).benefits.first?.result?.value == 90)
    }

    @Test("a live project is untouched by any of this")
    func liveProjectStillWrites() async throws {
        let service = service()
        var live = try await service.create(name: "ยังทำอยู่")
        live.brief = "แก้ได้ตามปกติ"

        try await service.update(live)
        try await service.save(WorkPackage(projectID: live.id, title: "งาน",
                                           acceptanceCriteria: done))
        #expect(await service.project(live.id)?.brief == "แก้ได้ตามปกติ")
        #expect(await service.breakdown(of: live.id).leaves.count == 1)
    }

    // Closing is the one stage change that has to be storable. The guard sits
    // on the public edit, not on the primitive the transition writes through —
    // without that split, the last transition would be the single thing the
    // system could not record.
    @Test("the act of closing is not blocked by the archive rule")
    func closingItselfIsNotBlocked() async throws {
        let service = service()
        let project = try await service.create(name: "กำลังจะปิด")

        let closed = try await service.terminate(project.id, reason: "จบรอบ")
        #expect(closed.isOpen == false)
        #expect(await service.project(project.id)?.stage == .closed)
    }
}
