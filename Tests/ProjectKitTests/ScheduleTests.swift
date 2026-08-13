import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// Order, the critical path, and the forecast that refuses to be invented
// (ARCHITECTURE §19.7, P10.9).
//
// Tested against graphs whose answer is known by construction, because a
// critical path is exactly the kind of thing that looks right on screen while
// being wrong — and the screen is where people make decisions with it.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_sched")
private let done = [Criterion(text: "ตรวจได้", evidenceRequired: "exit 0")]

private func leaf(_ id: String, after: [String] = [], order: Int = 0,
                  status: WorkPackageStatus = .backlog) -> WorkPackage {
    WorkPackage(id: id, projectID: project, title: id, scopeRef: "ขอบเขต",
                acceptanceCriteria: done, raci: RACI(accountable: .teamLead),
                dependsOn: after, status: status, order: order)
}

@Suite("Schedule")
struct ScheduleTests {

    /// A → B → D, and A → C. The longest chain is A B D whatever order the
    /// packages are stored in.
    private var diamond: WorkBreakdown {
        WorkBreakdown([
            leaf("A", order: 0),
            leaf("C", after: ["A"], order: 1),
            leaf("B", after: ["A"], order: 2),
            leaf("D", after: ["B"], order: 3),
        ])
    }

    @Test("nothing is ordered before what it waits on")
    func topologicalOrder() {
        let ordered = Schedule.order(diamond).map(\.id)
        #expect(ordered.first == "A")
        #expect(ordered.firstIndex(of: "B")! < ordered.firstIndex(of: "D")!)
        #expect(ordered.count == 4)
    }

    @Test("the critical path is the longest chain, not the widest branch")
    func criticalPathIsTheLongestChain() {
        #expect(Schedule.criticalPath(diamond) == ["A", "B", "D"])
    }

    @Test("a heavier short chain outweighs a lighter long one")
    func durationsDecideWhenTheyExist() {
        // C alone is heavier than B and D together, so the decisive chain
        // changes even though the shape has not.
        let path = Schedule.criticalPath(diamond) { package in
            package.id == "C" ? 10 : 1
        }
        #expect(path == ["A", "C"])
    }

    @Test("a dependency cycle is reported and does not hang the plan")
    func cyclesAreSurvivable() {
        let tangled = WorkBreakdown([
            leaf("A", after: ["B"]),
            leaf("B", after: ["A"]),
        ])
        let problems = tangled.problems(inScope: ["ขอบเขต"])
        #expect(problems.contains { $0.kind == .dependencyCycle })
        // Both still appear, because a plan the screen cannot draw is a plan
        // nobody can fix.
        #expect(Schedule.order(tangled).count == 2)
        _ = Schedule.criticalPath(tangled)
    }

    @Test("a dependency on a package that no longer exists is named")
    func missingDependencyIsReported() {
        let orphan = WorkBreakdown([leaf("A", after: ["ghost"])])
        #expect(orphan.problems(inScope: ["ขอบเขต"]).contains { $0.kind == .missingDependency })
    }

    @Test("ready work is what has nothing unfinished in front of it")
    func readyRespectsDoneness() {
        let started = WorkBreakdown([
            leaf("A", order: 0, status: .done),
            leaf("B", after: ["A"], order: 1),
            leaf("C", after: ["B"], order: 2),
        ])
        #expect(Schedule.ready(started).map(\.id) == ["B"])
    }

    @Test("two measurements are not a distribution")
    func forecastRefusesThinEvidence() {
        #expect(Schedule.estimate(from: [10, 20]) == nil)
        // §19.7 — a project with no history shows "no data" rather than a
        // band drawn from nothing.
        #expect(Schedule.estimate(from: []) == nil)

        let estimate = try! #require(Schedule.estimate(from: [10, 20, 30, 40, 100]))
        #expect(estimate.sampleCount == 5)
        #expect(estimate.p50 == 30)
        #expect(estimate.p90 > estimate.p50)
    }

    @Test("independent leaves have no critical path to crown")
    func noDependenciesMeansNoCriticalPath() {
        // Two leaves that wait on nothing are equally decisive. Marking one of
        // them critical claims an order that does not exist — which is what
        // the screen was doing until it was driven by hand.
        let parallel = WorkBreakdown([leaf("A", order: 0), leaf("B", order: 1)])
        #expect(Schedule.criticalPaths(parallel).isEmpty)
        #expect(Schedule.criticalPaths(WorkBreakdown()).isEmpty)
    }

    @Test("two chains of the same length are both critical")
    func tiedChainsAreBothReturned() {
        let twin = WorkBreakdown([
            leaf("A", order: 0), leaf("B", after: ["A"], order: 1),
            leaf("C", order: 2), leaf("D", after: ["C"], order: 3),
        ])
        let paths = Schedule.criticalPaths(twin)
        #expect(paths.count == 2)
        #expect(paths.contains(["A", "B"]))
        #expect(paths.contains(["C", "D"]))
    }

    @Test("a single longest chain is still the only one crowned")
    func oneWinnerWhenItIsLonger() {
        let paths = Schedule.criticalPaths(diamond)
        #expect(paths == [["A", "B", "D"]])
    }
}
