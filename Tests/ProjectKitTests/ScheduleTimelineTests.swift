import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// The calendar axis (§19.7, P10.9).
//
// The data for this existed after assignments became spans. What did not exist
// was an answer to the question that had blocked it for four plan items: a leaf
// touched on Monday and again on Thursday did not take four days, and the
// obvious drawing says it did.
//
// So these tests are almost entirely about what the picture must *not* claim.
// ─────────────────────────────────────────────────────────────

private let monday = Date(timeIntervalSince1970: 1_767_000_000)
private func at(_ hours: Double) -> Date { monday.addingTimeInterval(hours * 3_600) }

private func interval(_ id: String, _ package: String?, from: Double, to: Double,
                      succeeded: Bool = true) -> ScheduleTimeline.Interval {
    ScheduleTimeline.Interval(id: id, workPackage: package,
                              start: at(from), end: at(to), succeeded: succeeded)
}

private func leaf(_ id: String, _ title: String, order: Int = 0) -> WorkPackage {
    WorkPackage(id: id, projectID: ProjectID("pj"), title: title,
                acceptanceCriteria: [Criterion(text: "x", evidenceRequired: "y")],
                order: order)
}

@Suite("Schedule timeline — P10.9")
struct ScheduleTimelineTests {

    // The decision the whole chart rests on. One bar from first touch to last
    // is the lie a Gantt is best at telling.
    @Test("work split across days is separate marks, not one long bar")
    func aGapStaysAGap() {
        let timeline = ScheduleTimeline.build(
            intervals: [
                interval("s1", "wp_a", from: 0, to: 0.5),      // Monday, 30 minutes
                interval("s2", "wp_a", from: 72, to: 72.2),    // Thursday, 12 minutes
            ],
            leaves: [leaf("wp_a", "เขียนบทนำ")])

        let row = try! #require(timeline.rows.first)
        #expect(row.segments.count == 2, "the gap was drawn as work")
        // Forty-two minutes of work spread over three days, and both numbers
        // are reported rather than one being inferred from a rectangle.
        #expect(row.workedSeconds == 42 * 60)
        #expect(row.calendarSeconds == 72.2 * 3_600)
        #expect(row.gapNote?.contains("ช่องว่างคือช่องว่าง") == true)
    }

    @Test("a single unbroken piece of work has nothing to warn about")
    func contiguousWorkHasNoGapNote() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("s1", "wp_a", from: 0, to: 2)],
            leaves: [leaf("wp_a", "เขียนบทนำ")])
        let row = try! #require(timeline.rows.first)
        #expect(row.gapNote == nil)
        #expect(row.workedSeconds == row.calendarSeconds)
    }

    // Half of what a person opens a plan for is what has not begun.
    @Test("planned work that has not started still gets a row")
    func unstartedWorkIsVisible() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("s1", "wp_a", from: 0, to: 1)],
            leaves: [leaf("wp_a", "เขียนบทนำ", order: 0),
                     leaf("wp_b", "ทบทวนวรรณกรรม", order: 1)])

        #expect(timeline.rows.count == 2)
        #expect(timeline.rows[1].hasStarted == false)
        #expect(timeline.rows[1].segments.isEmpty)
        #expect(timeline.rows[1].workedSeconds == 0)
    }

    @Test("a plan with leaves and no work is not the same as an empty chart")
    func plannedButUntouched() {
        let timeline = ScheduleTimeline.build(intervals: [],
                                              leaves: [leaf("wp_a", "เขียนบทนำ")])
        #expect(timeline.rows.count == 1)
        #expect(timeline.isEmpty)
    }

    // Real time the project spent. Hiding it makes the plan look like the whole
    // story, which is the same failure as a Gantt with no unplanned work on it.
    @Test("work outside the plan gets its own row rather than disappearing")
    func unplannedWorkIsKept() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("s1", "wp_a", from: 0, to: 1),
                        interval("s2", nil, from: 1, to: 4)],
            leaves: [leaf("wp_a", "เขียนบทนำ")])

        let outside = try! #require(timeline.rows.last)
        #expect(outside.packageID == nil)
        #expect(outside.workedSeconds == 3 * 3_600)
        #expect(outside.title.contains("ไม่ได้ผูก"))
    }

    // Deleting a package does not un-spend the hours.
    @Test("work against a deleted leaf still appears, named as such")
    func workAgainstADeletedLeaf() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("s1", "wp_gone", from: 0, to: 2)],
            leaves: [leaf("wp_a", "เขียนบทนำ")])

        let orphan = try! #require(timeline.rows.first { $0.packageID == "wp_gone" })
        #expect(orphan.workedSeconds == 2 * 3_600)
        #expect(orphan.title.contains("ถูกลบ"))
    }

    // A chart of successes only shows a project that went better than it did.
    @Test("failed and cancelled work is drawn, because it cost hours")
    func failedWorkIsStillTime() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("s1", "wp_a", from: 0, to: 1),
                        interval("s2", "wp_a", from: 1, to: 6, succeeded: false)],
            leaves: [leaf("wp_a", "เขียนบทนำ")])

        let row = try! #require(timeline.rows.first)
        #expect(row.segments.count == 2)
        #expect(row.workedSeconds == 6 * 3_600, "five hours of failed work vanished")
        #expect(row.segments.contains { !$0.succeeded })
    }

    @Test("segments sit where they happened on the axis")
    func segmentsArePositioned() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("s1", "wp_a", from: 0, to: 2),
                        interval("s2", "wp_a", from: 8, to: 10)],
            leaves: [leaf("wp_a", "เขียนบทนำ")])

        let segments = try! #require(timeline.rows.first?.segments)
        #expect(segments[0].from == 0)
        #expect(segments[0].to == 0.2)
        #expect(segments[1].from == 0.8)
        #expect(segments[1].to == 1.0)
    }

    // The clamp that makes a forty-second job visible belongs to the view. Here
    // it would be a lie every downstream number inherits.
    @Test("a very short piece of work keeps its true width in the model")
    func noMinimumWidthInTheModel() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("s1", "wp_a", from: 0, to: 100),
                        interval("s2", "wp_a", from: 50, to: 50.01)],
            leaves: [leaf("wp_a", "เขียนบทนำ")])

        let brief = try! #require(timeline.rows.first?.segments.first { $0.id == "s2" })
        // A ten-thousandth of the axis — far below one pixel, and the model
        // hands it over anyway.
        #expect(abs((brief.to - brief.from) - 0.0001) < 1e-9)
    }

    @Test("everything happening at once does not divide by zero")
    func instantaneousWork() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("s1", "wp_a", from: 0, to: 0)],
            leaves: [leaf("wp_a", "เขียนบทนำ")])

        let segment = try! #require(timeline.rows.first?.segments.first)
        #expect(segment.from == 0)
        #expect(segment.to == 0)
        #expect(timeline.axisSeconds == ScheduleTimeline.shortestAxis)
    }

    @Test("rows follow the plan's order, not whatever started first")
    func rowsFollowThePlan() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("s1", "wp_b", from: 0, to: 1),
                        interval("s2", "wp_a", from: 5, to: 6)],
            leaves: [leaf("wp_a", "ทำก่อน", order: 0), leaf("wp_b", "ทำทีหลัง", order: 1)])

        #expect(timeline.rows.map(\.packageID) == ["wp_a", "wp_b", nil].compactMap { $0 })
    }

    @Test("the same rows in a different order give the same chart")
    func deterministic() {
        let intervals = [interval("s1", "wp_a", from: 0, to: 1),
                         interval("s2", "wp_a", from: 4, to: 5),
                         interval("s3", nil, from: 2, to: 3)]
        let leaves = [leaf("wp_a", "เขียนบทนำ")]
        #expect(ScheduleTimeline.build(intervals: intervals, leaves: leaves)
                == ScheduleTimeline.build(intervals: intervals.reversed(), leaves: leaves))
    }

    // A row that ended before it started is a clock problem, not a bar that
    // reaches backwards across the chart.
    @Test("an interval that ends before it starts is dropped, not drawn backwards")
    func backwardsIntervalsAreDropped() {
        let timeline = ScheduleTimeline.build(
            intervals: [interval("ok", "wp_a", from: 0, to: 1),
                        interval("bad", "wp_a", from: 5, to: 2)],
            leaves: [leaf("wp_a", "เขียนบทนำ")])

        #expect(timeline.rows.first?.segments.map(\.id) == ["ok"])
    }
}
