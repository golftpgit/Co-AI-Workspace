import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// P10.13's outstanding item — reports came out when somebody remembered, and
// the weeks nobody remembers are the weeks a project most needs one.
//
// There is no daemon and there should not be: this app is not running when it
// is closed, and a scheduler that pretends otherwise reports Tuesday on
// Thursday. So what is tested here is the honest question — given when the
// last one went out, is one due, and for what period.
// ─────────────────────────────────────────────────────────────

private let calendar = Calendar(identifier: .gregorian)
private func day(_ day: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 9))!
}

@Suite("When a report is due (P10.13)")
struct ReportCycleTests {

    @Test("off means nothing is ever due")
    func offIsOff() {
        #expect(ReportCycle.due(ReportSchedule(cycle: .off), lastIssued: day(1),
                                projectStarted: day(1), now: day(30)) == nil)
    }

    @Test("a weekly report is due a week after the last one, and covers from it")
    func weeklyCoversFromTheLast() throws {
        let due = try #require(ReportCycle.due(ReportSchedule(cycle: .weekly),
                                               lastIssued: day(1), projectStarted: day(1),
                                               now: day(8)))
        // The period is what makes two reports comparable, and it is what the
        // builder already takes as `since`.
        #expect(due.since == day(1))
        #expect(due.missedCycles == 0)
        #expect(due.gapNote == nil)
    }

    @Test("nothing is due before the cycle has passed")
    func notDueEarly() {
        #expect(ReportCycle.due(ReportSchedule(cycle: .weekly), lastIssued: day(1),
                                projectStarted: day(1), now: day(7)) == nil)
        #expect(ReportCycle.due(ReportSchedule(cycle: .monthly), lastIssued: day(1),
                                projectStarted: day(1), now: day(20)) == nil)
    }

    /// A report covering a project's first afternoon has nothing in it, and
    /// teaches people to ignore the next one.
    @Test("a project with no report yet waits for its first full cycle")
    func firstReportWaits() throws {
        let schedule = ReportSchedule(cycle: .weekly)
        #expect(ReportCycle.due(schedule, lastIssued: nil, projectStarted: day(1),
                                now: day(3)) == nil)
        let due = try #require(ReportCycle.due(schedule, lastIssued: nil,
                                               projectStarted: day(1), now: day(9)))
        #expect(due.since == day(1))
    }

    /// Three weeks away is one report and a sentence, not three reports.
    /// Backfilled ones would put numbers under dates nobody was working on.
    @Test("missed cycles are counted and said, not backfilled")
    func gapsAreSaidNotFilled() throws {
        let due = try #require(ReportCycle.due(ReportSchedule(cycle: .weekly),
                                               lastIssued: day(1), projectStarted: day(1),
                                               now: day(25)))
        #expect(due.missedCycles == 2)
        // One report, covering the whole gap, and it says so.
        #expect(due.since == day(1))
        let note = try #require(due.gapNote)
        #expect(note.contains("2 รอบ"))
        #expect(note.contains("ไม่ได้ย้อนออกทีละรอบ"))
    }

    @Test("an ordinary report carries no apology")
    func noGapNoNote() throws {
        let due = try #require(ReportCycle.due(ReportSchedule(cycle: .fortnightly),
                                               lastIssued: day(1), projectStarted: day(1),
                                               now: day(15)))
        #expect(due.missedCycles == 0)
        #expect(due.gapNote == nil)
    }
}
