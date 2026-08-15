import Testing
import Foundation
import AgentKit
import Observability
@testable import Persistence

// ─────────────────────────────────────────────────────────────
// What the forecast band is made of, now that there is something honest to make
// it from (ARCHITECTURE §19.7, P10.15).
//
// The band has been wrong twice. First it was every span carrying a role, which
// is overwhelmingly `tool:kb_search`, so a schedule was drawn from a p90 of
// search calls. Then it was completed chat turns — closer, but a turn is a
// message-and-tools round trip standing in for a reviewed promise, and it reads
// low. Both times the arithmetic was right and the population was wrong, which
// is why these tests are all about which rows come back rather than about
// quantiles.
// ─────────────────────────────────────────────────────────────

@Suite("Forecast population — assignments", .serialized)
struct AssignmentPopulationTests {

    private func assignmentSpan(kind: String, seconds: TimeInterval,
                                status: SpanStatus = .succeeded,
                                project: ProjectID = ProjectID("pj_kind"),
                                workPackage: String? = nil,
                                startedAt: Date = Date()) -> Span {
        var span = Span(name: Span.assignmentName, role: .writer, scope: .project(project),
                        status: status, startedAt: startedAt,
                        workPackage: workPackage,
                        deliverableKind: Assignment.deliverableKind(kind))
        span.endedAt = startedAt.addingTimeInterval(seconds)
        return span
    }

    @Test("finished assignments of one kind are the population", .timeLimit(.minutes(2)))
    func kindIsThePopulation() async throws {
        guard let server = try await makeServer(port: 18_691) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)

        for seconds in [600.0, 900.0, 1_200.0] {
            await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: seconds))
        }
        await sink.record(assignmentSpan(kind: "โค้ดที่ผ่านเทส", seconds: 30))

        let durations = try await sink.durations(forDeliverableKind: "รายงานสรุป")
        #expect(durations.sorted() == [600, 900, 1_200])
        // A literature review and a bug fix in one distribution is an average
        // nobody's work resembles.
        #expect(try await sink.durations(forDeliverableKind: "โค้ดที่ผ่านเทส") == [30])
    }

    // The rounds inside an assignment are recorded too, and they must not be
    // counted as assignments — four rounds of one job would look like four jobs
    // that each took a quarter as long.
    @Test("attempt spans are not in the population", .timeLimit(.minutes(2)))
    func attemptsExcluded() async throws {
        guard let server = try await makeServer(port: 18_692) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)

        for seconds in [600.0, 900.0, 1_200.0] {
            await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: seconds))
        }
        // Given the same kind on purpose. The orchestrator does not write it
        // there — a separate test holds that line — and this one is about the
        // query: it asks for assignments by name, so an attempt is excluded by
        // what it *is* rather than by what it happens to be missing.
        for _ in 0..<9 {
            var attempt = Span(name: Span.attemptName, role: .writer, scope: .central,
                               status: .succeeded,
                               deliverableKind: "รายงานสรุป")
            attempt.endedAt = attempt.startedAt.addingTimeInterval(5)
            await sink.record(attempt)
        }

        #expect(try await sink.durations(forDeliverableKind: "รายงานสรุป").count == 3)
    }

    // An escalation is how long it took to give up, and a cancellation is a
    // decision somebody made about something else entirely. Neither answers
    // "how long does this take".
    @Test("escalated and cancelled work is not evidence of duration", .timeLimit(.minutes(2)))
    func onlySucceededCounts() async throws {
        guard let server = try await makeServer(port: 18_693) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)

        await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: 600))
        await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: 9_999, status: .failed))
        await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: 12, status: .cancelled))
        await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: 40, status: .running))

        #expect(try await sink.durations(forDeliverableKind: "รายงานสรุป") == [600])
    }

    // The same promise typed with a capital or a stray space is the same
    // promise. Deliberately nothing cleverer: merging "รายงานสรุป" with
    // "รายงานสรุปผลการวิเคราะห์" would be two different jobs in one band.
    @Test("case and stray spaces are the same kind", .timeLimit(.minutes(2)))
    func kindIsNormalised() async throws {
        guard let server = try await makeServer(port: 18_694) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)

        await sink.record(assignmentSpan(kind: "Summary Report", seconds: 600))
        await sink.record(assignmentSpan(kind: " summary report ", seconds: 900))
        await sink.record(assignmentSpan(kind: "SUMMARY REPORT", seconds: 1_200))

        #expect(try await sink.durations(forDeliverableKind: "summary  report").count == 3)
        #expect(try await sink.durations(forDeliverableKind: "  ").isEmpty,
                "an empty kind matched everything with no kind")
    }

    // The rows a schedule with a real time axis is drawn from (§19.7, P10.9).
    @Test("a project's work comes back as pieces on a calendar", .timeLimit(.minutes(2)))
    func workForTheSchedule() async throws {
        guard let server = try await makeServer(port: 18_695) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)
        let project = ProjectID("pj_gantt")
        let start = Date().addingTimeInterval(-7_200)

        await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: 600, project: project,
                                         workPackage: "wp_a", startedAt: start))
        await sink.record(assignmentSpan(kind: "โค้ดที่ผ่านเทส", seconds: 300, project: project,
                                         workPackage: "wp_b",
                                         startedAt: start.addingTimeInterval(900)))
        // Work outside the plan is real work; a chart that hid it would make
        // the plan look like the whole story.
        await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: 120, project: project,
                                         startedAt: start.addingTimeInterval(1_800)))
        await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: 999,
                                         project: ProjectID("pj_other"), startedAt: start))

        let (rows, total) = try await sink.topLevelWork(project: project)
        #expect(rows.count == 3, "another project's work is on this project's chart")
        #expect(total == 3)
        #expect(rows.map(\.workPackage) == ["wp_a", "wp_b", nil], "not in start order")
        #expect(rows.allSatisfy { $0.endedAt != nil })
        #expect(rows.first?.deliverableKind == "รายงานสรุป")
    }

    // The chart is drawn from these rows and the total beside it is summed from
    // the same rule, so a piece already inside another piece must not be here
    // either — otherwise the picture and the number are two answers.
    @Test("a piece inside another piece is not drawn again", .timeLimit(.minutes(2)))
    func nestedWorkIsNotAPiece() async throws {
        guard let server = try await makeServer(port: 18_696) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)
        let project = ProjectID("pj_nested_chart")

        let parent = assignmentSpan(kind: "รายงานสรุป", seconds: 600, project: project,
                                    workPackage: "wp_a")
        await sink.record(parent)
        var attempt = Span(parent: parent.id, name: Span.attemptName, role: .writer,
                           scope: .project(project), status: .succeeded,
                           workPackage: "wp_a")
        attempt.endedAt = attempt.startedAt.addingTimeInterval(200)
        await sink.record(attempt)
        // Still running: nothing to draw a bar to yet.
        await sink.record(Span(name: Span.turnName, role: .writer, scope: .project(project),
                               workPackage: "wp_a"))

        let (rows, total) = try await sink.topLevelWork(project: project)
        #expect(rows.map(\.name) == [Span.assignmentName])
        #expect(total == 1)
    }

    // A busy project must not silently show a third of its history as though it
    // were all of it — the same rule the knowledge graph follows.
    @Test("a truncated chart says how much it is not showing", .timeLimit(.minutes(2)))
    func truncationIsReported() async throws {
        guard let server = try await makeServer(port: 18_697) else { return }
        defer { Task { await server.shutdown() } }
        let sink = SurrealSpanSink(client: await server.client)
        let project = ProjectID("pj_busy")

        for index in 0..<7 {
            await sink.record(assignmentSpan(kind: "รายงานสรุป", seconds: 60, project: project,
                                             startedAt: Date().addingTimeInterval(Double(index) * 60)))
        }

        let (rows, total) = try await sink.topLevelWork(project: project, limit: 3)
        #expect(rows.count == 3)
        #expect(total == 7, "the caller cannot tell it is looking at part of the history")
    }
}
