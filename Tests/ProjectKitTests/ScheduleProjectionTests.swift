import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// P10.9's third axis — where work that has not started would land.
//
// R9 is the risk this is written against: a projection is where a schedule
// starts lying, and the lie is always confident. Every test here is about the
// refusal rather than the arithmetic; the forward pass is ordinary.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_forecast")
private let done = [Criterion(text: "ตรวจได้", evidenceRequired: "exit 0")]

private func leaf(_ id: String, after: [String] = [], order: Int = 0) -> WorkPackage {
    WorkPackage(id: id, projectID: project, title: id, scopeRef: "ขอบเขต",
                acceptanceCriteria: done, raci: RACI(accountable: .teamLead),
                dependsOn: after, status: .backlog, order: order)
}

private let now = Calendar(identifier: .gregorian)
    .date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 9))!

private func band(_ p50: TimeInterval, _ p90: TimeInterval, samples: Int = 6) -> ScheduleEstimate {
    ScheduleEstimate(p50: p50, p90: p90, sampleCount: samples,
                     basis: .assignments(kind: "เอกสาร"))
}

private let chain = WorkBreakdown([
    leaf("A", order: 0),
    leaf("B", after: ["A"], order: 1),
    leaf("C", after: ["B"], order: 2),
])

@Suite("Projecting work that has not started (P10.9, R9)")
struct ScheduleProjectionTests {

    @Test("a chain is laid out end to end, with both ends of the band")
    func forwardPass() {
        let projection = ScheduleForecast.project(chain, started: [], now: now) { _ in
            band(3600, 7200)
        }

        #expect(projection.leaves.map(\.packageID) == ["A", "B", "C"])
        let a = projection.leaves[0], b = projection.leaves[1]
        #expect(a.earliestStart == now)
        // B starts when A is done — optimistic against optimistic, cautious
        // against cautious, because everything upstream moves too.
        #expect(b.earliestStart == a.p50Finish)
        #expect(b.latestStart == a.p90Finish)
        #expect(projection.p90Finish == projection.leaves[2].p90Finish)
        #expect(b.p90Finish.timeIntervalSince(b.p50Finish) > 0, "the band collapsed to one date")
    }

    /// R9, as code: no population, no date.
    @Test("a leaf with no comparable finished work gets no date at all")
    func noPopulationNoDate() {
        let projection = ScheduleForecast.project(chain, started: [], now: now) { package in
            package.id == "A" ? nil : band(3600, 7200)
        }

        #expect(projection.leaves.contains { $0.packageID == "A" } == false)
        // And it is named rather than quietly dropped — a chart missing a row
        // reads as a chart of all the rows.
        #expect(projection.unforecastable.contains { $0.packageID == "A" })
        #expect(projection.unforecastable.first?.reason.contains("ไม่มีตัวเลขจริง") == true)
    }

    /// The expensive mistake: treating the unknown as zero and handing its
    /// successor a confident date.
    @Test("work waiting on something unforecastable is unforecastable too")
    func unknownsPropagate() {
        let projection = ScheduleForecast.project(chain, started: [], now: now) { package in
            package.id == "A" ? nil : band(3600, 7200)
        }

        #expect(projection.leaves.isEmpty, "a date was invented downstream of an unknown")
        #expect(projection.unforecastable.map(\.packageID) == ["A", "B", "C"])
        #expect(projection.unforecastable[1].reason.contains("ขึ้นกับใบงานที่ยังประมาณเวลาไม่ได้"))
        #expect(projection.p90Finish == nil)
    }

    /// A forecast drawn over measured work is a guess arguing with a fact.
    @Test("work already under way is not projected")
    func startedWorkIsLeftAlone() {
        let projection = ScheduleForecast.project(chain, started: ["A"], now: now) { _ in
            band(3600, 7200)
        }

        #expect(projection.leaves.map(\.packageID) == ["B", "C"])
        // B has no *projected* predecessor left, so it starts from now rather
        // than from a date invented for A.
        #expect(projection.leaves[0].earliestStart == now)
    }

    @Test("the band carries how many finished pieces of work it came from")
    func sampleCountTravels() {
        let projection = ScheduleForecast.project(chain, started: [], now: now) { _ in
            band(3600, 7200, samples: 11)
        }
        #expect(projection.leaves.allSatisfy { $0.sampleCount == 11 })
    }

    @Test("an empty plan projects nothing rather than a date for nothing")
    func emptyPlan() {
        let projection = ScheduleForecast.project(WorkBreakdown([]), started: [], now: now) { _ in
            band(3600, 7200)
        }
        #expect(projection.leaves.isEmpty)
        #expect(projection.unforecastable.isEmpty)
        #expect(projection.p90Finish == nil)
    }
}
