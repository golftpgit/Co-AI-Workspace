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

    /// A completed turn, which is what the forecast band is made of.
    private func turn(role: Role, project: ProjectID, seconds: TimeInterval,
                      status: SpanStatus = .succeeded) -> Span {
        let started = Date().addingTimeInterval(-seconds)
        var span = Span(name: "turn", role: role, scope: .project(project),
                        status: status, startedAt: started)
        span.endedAt = started.addingTimeInterval(seconds)
        return span
    }

    @Test("the forecast reads finished turns of the same role", .timeLimit(.minutes(2)))
    func durationsForForecast() async throws {
        guard let server = try await makeServer(port: 18_623) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)
        let project = ProjectID("pj_history")

        // Turns, not tool calls. This test used the `tool:run_shell` helper
        // and passed, which is how the forecast band came to be computed from
        // the duration of individual tool calls — the test asserted the
        // behaviour rather than the intent its own name states.
        for seconds in [10.0, 20, 30, 40] {
            await sink.record(turn(role: .analyst, project: project, seconds: seconds))
        }
        // Unfinished work has no duration to learn from, and failed work is
        // not what "how long does this usually take" is asking about.
        await sink.record(turn(role: .analyst, project: project,
                               seconds: 9_999, status: .failed))

        let durations = try await sink.durations(forRole: .analyst)
        #expect(durations.count == 4)
        #expect(durations.max() == 40)
        #expect(try await sink.durations(forRole: .writer).isEmpty)
    }
}

// ─────────────────────────────────────────────────────────────
// P10.15's outstanding half — what the forecast band is made of.
//
// `durations(forRole:)` had no filter on the span kind, so it returned every
// span carrying the role. Those are overwhelmingly `tool:kb_search` and the
// like, which meant the p50–p90 band drawn on a schedule was computed from the
// duration of individual tool calls. A p90 of search calls is not an estimate
// for a work package, and the popover presented it as one.
// ─────────────────────────────────────────────────────────────

@Suite("Forecast band population", .serialized)
struct ForecastPopulationTests {

    private func span(_ name: String, role: Role, seconds: TimeInterval,
                      status: SpanStatus = .succeeded) -> Span {
        var span = Span(name: name, role: role, scope: .central)
        span.status = status
        span.endedAt = span.startedAt.addingTimeInterval(seconds)
        return span
    }

    @Test("tool spans are not part of the band", .timeLimit(.minutes(2)))
    func toolSpansExcluded() async throws {
        guard let server = try await makeServer(port: 18_681) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)

        for _ in 0..<10 { await sink.record(span("tool:kb_search", role: .analyst, seconds: 2)) }
        for seconds in [600.0, 900.0, 1_200.0] {
            await sink.record(span("turn", role: .analyst, seconds: seconds))
        }

        let durations = try await sink.durations(forRole: .analyst)
        #expect(durations.count == 3, "tool calls are still in the forecast population")
        #expect(durations.allSatisfy { $0 >= 600 })
    }

    // Unfinished and failed work is not evidence of how long the work takes.
    @Test("only completed turns count", .timeLimit(.minutes(2)))
    func onlySucceededTurns() async throws {
        guard let server = try await makeServer(port: 18_682) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)

        await sink.record(span("turn", role: .writer, seconds: 300))
        await sink.record(span("turn", role: .writer, seconds: 5_000, status: .failed))

        #expect(try await sink.durations(forRole: .writer).count == 1)
    }

    // Roles are separate populations: a writer's turns say nothing about an
    // engineer's.
    @Test("one role's turns do not appear under another", .timeLimit(.minutes(2)))
    func rolesStaySeparate() async throws {
        guard let server = try await makeServer(port: 18_683) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)

        await sink.record(span("turn", role: .engineer, seconds: 100))
        await sink.record(span("turn", role: .writer, seconds: 900))

        #expect(try await sink.durations(forRole: .engineer) == [100])
    }
}
