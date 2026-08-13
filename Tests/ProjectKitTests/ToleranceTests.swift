import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// Manage by exception (ARCHITECTURE §19.10, P10.6).
//
// The rule under test is not "notices a breach" — it is "stops". A frame that
// produces a warning and lets the work continue is a frame nobody has to
// respect, which is the state escalation was in before this: one trigger, and
// nothing downstream of it.
// ─────────────────────────────────────────────────────────────

actor MemoryExceptionStore: ExceptionPersisting {
    private var rows: [String: ExceptionReport] = [:]
    func save(_ report: ExceptionReport) async throws { rows[report.id] = report }
    func all(project: ProjectID) async throws -> [ExceptionReport] {
        rows.values.filter { $0.projectID == project }
    }
}

private func service() -> ProjectService {
    ProjectService(store: MemoryProjectStore(), exceptions: MemoryExceptionStore())
}

@Suite("Tolerance")
struct ToleranceTests {

    @Test("five dimensions count up to their limit; benefit counts down")
    func benefitIsTheOneThatCountsDown() {
        #expect(ToleranceCheck.isBreach(.cost, current: 501, limit: 500))
        #expect(!ToleranceCheck.isBreach(.cost, current: 499, limit: 500))
        // A benefit below its floor is the breach, and reading it the other way
        // would silently make the one dimension the business case rests on the
        // one dimension nothing checks.
        #expect(ToleranceCheck.isBreach(.benefit, current: 0.6, limit: 0.8))
        #expect(!ToleranceCheck.isBreach(.benefit, current: 0.9, limit: 0.8))
        // A benefit with no target set is not a breach — an unset limit is not
        // a limit of zero.
        #expect(!ToleranceCheck.isBreach(.benefit, current: 0, limit: 0))
    }

    @Test("the slider presets are the same six numbers, widening together")
    func presetsWiden() {
        for dimension in ToleranceDimension.allCases where dimension != .benefit {
            #expect(Tolerances.approvalRequired.limit(dimension)
                    <= Tolerances.balanced.limit(dimension))
            #expect(Tolerances.balanced.limit(dimension)
                    <= Tolerances.fullAutonomous.limit(dimension))
        }
    }

    @Test("a breach names the dimension, the number and the frame")
    func statusCarriesItsNumbers() {
        let breaches = ToleranceCheck.breaches(
            .balanced, readings: ToleranceReadings(spent: 640, maxRework: 4))

        #expect(Set(breaches.map(\.dimension)) == [.cost, .quality])
        let cost = try! #require(breaches.first { $0.dimension == .cost })
        #expect(cost.current == 640)
        #expect(cost.limit == 500)
        #expect(cost.fraction > 1)
    }

    @Test("the automatic report says what was asked for, not just what happened")
    func automaticReportIsADecisionRequest() {
        let status = ToleranceStatus(dimension: .time, limit: 1.5, current: 2.2, breached: true)
        let report = ExceptionReport.automatic(projectID: ProjectID("pj_1"), status: status)

        // The field that separates a report from a status update.
        #expect(!report.needsFromHuman.isEmpty)
        #expect(report.options.count == 3)
        #expect(report.message.contains("เวลา"))
        #expect(report.message.contains("ต้องการจากคุณ"))
        #expect(report.isOpen)
    }

    @Test("a breach stops the project, and resolving it starts it again")
    func openExceptionBlocksTheProject() async throws {
        let service = service()
        let project = try await service.create(name: "ความเครียดพยาบาล")
        #expect(await service.hasOpenException(project.id) == false)

        let raised = try await service.raiseBreaches(
            for: project.id, readings: ToleranceReadings(spent: 900))
        #expect(raised.count == 1)
        #expect(raised.first?.dimension == .cost)
        // The half that matters: the gate asks this, and the answer is what
        // stops work rather than a warning nobody reads.
        #expect(await service.hasOpenException(project.id))

        try await service.resolve(raised[0], decision: "ขยายเพดานเป็น 1,000")
        #expect(await service.hasOpenException(project.id) == false)
    }

    @Test("the same breach does not raise a second report every time it is checked")
    func breachesAreNotRepeated() async throws {
        let service = service()
        let project = try await service.create(name: "คัดกรองเบาหวาน")
        let readings = ToleranceReadings(spent: 900, maxRework: 9)

        let first = try await service.raiseBreaches(for: project.id, readings: readings)
        #expect(first.count == 2)
        // Raised once, not once per check — otherwise a project that stopped
        // fifteen minutes ago has fifteen identical reports and a person has to
        // find which one is new.
        #expect(try await service.raiseBreaches(for: project.id, readings: readings).isEmpty)
        #expect(try await service.openExceptions(project.id).count == 2)
    }

    @Test("one dimension resolved does not restart a project that broke two")
    func stillStoppedWhileAnyRemainOpen() async throws {
        let service = service()
        let project = try await service.create(name: "สองข้อ")
        let raised = try await service.raiseBreaches(
            for: project.id, readings: ToleranceReadings(spent: 900, maxRework: 9))

        try await service.resolve(raised[0], decision: "แก้แล้ว")
        #expect(await service.hasOpenException(project.id))

        try await service.resolve(raised[1], decision: "แก้แล้ว")
        #expect(await service.hasOpenException(project.id) == false)
    }

    @Test("a stop survives a restart")
    func blockedSetIsRebuiltFromTheStore() async throws {
        let store = MemoryProjectStore()
        let exceptions = MemoryExceptionStore()
        let first = ProjectService(store: store, exceptions: exceptions)
        let project = try await first.create(name: "ค้างไว้")
        _ = try await first.raiseBreaches(for: project.id, readings: ToleranceReadings(spent: 900))

        // A new service over the same rows — the app after a relaunch. A stop
        // that only exists in memory is a pause that coincides with somebody
        // being at their desk.
        let second = ProjectService(store: store, exceptions: exceptions)
        #expect(await second.hasOpenException(project.id) == false)
        await second.refreshExceptions()
        #expect(await second.hasOpenException(project.id))
    }
}
