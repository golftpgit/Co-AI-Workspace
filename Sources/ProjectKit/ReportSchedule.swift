import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// When a highlight report is due (ARCHITECTURE §19.13, P10.13).
//
// Reports have been issued by pressing a button, which means they are issued
// when somebody remembers — and the weeks somebody does not remember are the
// weeks a project most needs one. §19.13 asks for a cycle.
//
// There is no daemon here and there should not be: this app is not running
// when it is not open, and a scheduler that pretends otherwise reports Tuesday
// on Thursday. So the question this answers is the honest one — **given when
// the last report was issued, is one due now, and for which period?**
//
// Three rules, each a way a cycle lies:
//
//  • **A report names the period it covers**, not the day it was made. "ตั้งแต่
//    12 ส.ค." is what makes two reports comparable, and it is what the builder
//    already takes as `since`.
//  • **Missed periods are said, not backfilled.** Three weeks away is not
//    three reports; it is one report and a sentence saying the gap. Writing
//    three would put numbers under dates nobody was working on.
//  • **A cycle never issues anything on its own.** It says a report is due;
//    the same call a person makes is what issues it, so nothing can arrive by
//    a path that skips the rules manual issuing follows.
// ─────────────────────────────────────────────────────────────

public struct ReportSchedule: Sendable, Codable, Equatable {
    public enum Cycle: String, Sendable, Codable, CaseIterable {
        case off, weekly, fortnightly, monthly

        public var label: String {
            switch self {
            case .off: "ไม่ออกเอง"
            case .weekly: "ทุกสัปดาห์"
            case .fortnightly: "ทุกสองสัปดาห์"
            case .monthly: "ทุกเดือน"
            }
        }

        var days: Int? {
            switch self {
            case .off: nil
            case .weekly: 7
            case .fortnightly: 14
            case .monthly: 30
            }
        }
    }

    public var cycle: Cycle
    /// When the last highlight report was issued, from the report history
    /// rather than remembered here — one source of truth for "when did we last
    /// tell anybody anything".
    public init(cycle: Cycle = .off) {
        self.cycle = cycle
    }
}

/// What the screen asks on launch.
public struct ReportDue: Sendable, Equatable {
    /// The period the report would cover.
    public let since: Date?
    /// How many whole cycles went by unreported. Zero on the ordinary case;
    /// anything higher is a gap that belongs in the report itself rather than
    /// in a series of invented ones.
    public let missedCycles: Int

    /// The sentence that goes with a report issued after a gap. Nil when
    /// nothing was missed — an ordinary report needs no apology.
    public var gapNote: String? {
        guard missedCycles > 0 else { return nil }
        return "ช่วงที่ผ่านมามี \(missedCycles) รอบที่ไม่ได้ออกรายงาน — "
            + "ฉบับนี้ครอบคลุมทั้งช่วง ไม่ได้ย้อนออกทีละรอบ "
            + "เพราะรายงานย้อนหลังคือตัวเลขที่ใส่ไว้ใต้วันที่ที่ไม่มีใครทำงาน"
    }
}

public enum ReportCycle {

    /// Whether a highlight report is due, and for what period.
    ///
    /// - Parameters:
    ///   - lastIssued: when the last highlight report was generated, or `nil`
    ///     if there has never been one.
    ///   - projectStarted: where the first report's period begins.
    public static func due(_ schedule: ReportSchedule,
                           lastIssued: Date?,
                           projectStarted: Date,
                           now: Date) -> ReportDue? {
        guard let days = schedule.cycle.days else { return nil }
        let period = TimeInterval(days) * 86_400

        guard let lastIssued else {
            // Never reported. Due once the first cycle has actually passed —
            // a report covering a project's first afternoon has nothing in it
            // and teaches people to ignore the next one.
            guard now.timeIntervalSince(projectStarted) >= period else { return nil }
            return ReportDue(since: projectStarted, missedCycles: 0)
        }

        let elapsed = now.timeIntervalSince(lastIssued)
        guard elapsed >= period else { return nil }
        return ReportDue(since: lastIssued,
                         missedCycles: max(0, Int(elapsed / period) - 1))
    }
}
