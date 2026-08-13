import Testing
import Foundation
import AgentKit
import Observability
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// Spans against the plan (ARCHITECTURE §19.6, §19.7, P10.15).
//
// Spans have always known how long something took. What they could not say was
// what it took that long *for* — which is why the schedule had no time axis and
// four of the six tolerances were enforced but unread. This is that link, and
// the numbers it produces are the ones the screen will act on, so they are
// checked against durations that are known by construction.
// ─────────────────────────────────────────────────────────────

@Suite("Spans point at work packages", .serialized)
struct SpanWorkPackageTests {

    private func span(_ package: String?, role: Role, project: ProjectID,
                      seconds: TimeInterval, status: SpanStatus = .succeeded) -> Span {
        let started = Date().addingTimeInterval(-seconds)
        var span = Span(name: "tool:run_shell", role: role, scope: .project(project),
                        status: status, startedAt: started, workPackage: package)
        span.endedAt = started.addingTimeInterval(seconds)
        return span
    }

    @Test("time against a leaf is summed, not wall-clocked", .timeLimit(.minutes(2)))
    func elapsedIsSummed() async throws {
        guard let server = try await makeServer(port: 18_621) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)
        let project = ProjectID("pj_time")

        await sink.record(span("wp_a", role: .analyst, project: project, seconds: 30))
        await sink.record(span("wp_a", role: .analyst, project: project, seconds: 45))
        await sink.record(span("wp_b", role: .engineer, project: project, seconds: 10))
        // Work outside the plan still belongs to the project; it simply does
        // not belong to a promise.
        await sink.record(span(nil, role: .researcher, project: project, seconds: 900))

        let elapsed = try await sink.elapsedByWorkPackage(project: project)
        // A package worked on across three sittings did not take three
        // sittings' worth of wall clock.
        #expect(elapsed["wp_a"] == 75)
        #expect(elapsed["wp_b"] == 10)
        #expect(elapsed.count == 2)
    }

    @Test("one project's time is not another's", .timeLimit(.minutes(2)))
    func projectsDoNotShareTime() async throws {
        guard let server = try await makeServer(port: 18_622) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)

        await sink.record(span("wp_a", role: .analyst, project: ProjectID("pj_x"), seconds: 20))
        await sink.record(span("wp_a", role: .analyst, project: ProjectID("pj_y"), seconds: 500))

        #expect(try await sink.elapsedByWorkPackage(project: ProjectID("pj_x")) == ["wp_a": 20])
    }

    @Test("the forecast reads finished work of the same role", .timeLimit(.minutes(2)))
    func durationsForForecast() async throws {
        guard let server = try await makeServer(port: 18_623) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)
        let project = ProjectID("pj_history")

        for seconds in [10.0, 20, 30, 40] {
            await sink.record(span("wp_x", role: .analyst, project: project, seconds: seconds))
        }
        // Unfinished work has no duration to learn from, and failed work is
        // not what "how long does this usually take" is asking about.
        await sink.record(span("wp_x", role: .analyst, project: project,
                               seconds: 9_999, status: .failed))

        let durations = try await sink.durations(forRole: .analyst)
        #expect(durations.count == 4)
        #expect(durations.max() == 40)
        #expect(try await sink.durations(forRole: .writer).isEmpty)
    }
}
