import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The schedule on a calendar axis (ARCHITECTURE §19.7, P10.9).
//
// §19.7 asked for a Gantt whose horizontal axis is time, and for four plan items
// the answer was "there is nothing honest to put there": spans did not carry a
// work package, and assignments were not recorded at all. Both are fixed, so
// what is left is not missing data — it is one question that has to be answered
// before a single rectangle is drawn.
//
// **A leaf touched on Monday and again on Thursday did not take four days.**
//
// The obvious drawing — one bar per leaf from first touch to last — is exactly
// the lie a Gantt is best at. It reads as four days of work. Shading the bar to
// show that only forty minutes of it was real does not help: the eye reads the
// rectangle, not the fill.
//
// So a row is **one segment per piece of work, and a gap stays a gap**. Monday
// and Thursday are two marks with nothing between them, because nothing was
// between them. Nobody has to interpret a fill ratio; the picture is the record.
//
// Four more decisions follow from the same principle:
//
//  • **Planned work that has not started gets a row with no segments.** A
//    schedule that only shows what happened is a report; half of what a person
//    opens a plan for is what has not begun.
//  • **Work outside the plan gets its own row**, never dropped. It is real time
//    the project spent, and hiding it makes the plan look like the whole story.
//  • **Failed and cancelled work is drawn.** It cost hours. A chart showing only
//    successes shows a project that went better than it did.
//  • **The model returns exact fractions.** The minimum width that makes a
//    forty-second job visible is a drawing concern and lives in the view — put
//    it here and every number computed downstream inherits a lie told for the
//    benefit of a pixel.
// ─────────────────────────────────────────────────────────────

public struct ScheduleTimeline: Sendable, Equatable {

    /// One piece of work that happened, as this needs it.
    ///
    /// Its own type rather than `Span`, which lives in Observability — ProjectKit
    /// depends on AgentKit and nothing else, and a picture of the plan should not
    /// need to know how observability is stored. Same reason `EntityGraph` has
    /// its own `Relation`.
    public struct Interval: Sendable, Equatable, Identifiable {
        public let id: String
        /// The leaf this was against, or `nil` for work outside the plan.
        public let workPackage: String?
        public let start: Date
        public let end: Date
        /// Whether the work was accepted. Drawn either way — see the header.
        public let succeeded: Bool

        public init(id: String, workPackage: String?, start: Date, end: Date,
                    succeeded: Bool) {
            self.id = id
            self.workPackage = workPackage
            self.start = start
            self.end = end
            self.succeeded = succeeded
        }

        public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    /// One mark on a row, positioned as a fraction of the axis.
    public struct Segment: Sendable, Equatable, Identifiable {
        public let id: String
        public let start: Date
        public let end: Date
        public let succeeded: Bool
        /// Where it sits on the axis, 0…1. Exact — the view clamps for drawing.
        public let from: Double
        public let to: Double

        public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        /// `nil` for the row that holds work belonging to no leaf.
        public let packageID: String?
        public let title: String
        public let segments: [Segment]
        /// Time actually spent, summed. Not the width of the row.
        public let workedSeconds: TimeInterval
        /// First touch to last touch. Reported *beside* the worked time
        /// precisely so the difference between them is readable rather than
        /// something the reader has to infer from a rectangle.
        public let calendarSeconds: TimeInterval

        public var id: String { packageID ?? "\u{0}outside-the-plan" }
        public var hasStarted: Bool { !segments.isEmpty }

        /// What the row says when the two numbers disagree — which is the whole
        /// reason this chart took four plan items to draw.
        public var gapNote: String? {
            guard segments.count > 1, calendarSeconds > workedSeconds * 2 else { return nil }
            return "ทำจริง \(Self.readable(workedSeconds)) "
                + "แต่กระจายอยู่ในช่วง \(Self.readable(calendarSeconds)) — ช่องว่างคือช่องว่าง"
        }

        static func readable(_ seconds: TimeInterval) -> String {
            if seconds >= 86_400 { return String(format: "%.1f วัน", seconds / 86_400) }
            if seconds >= 3_600 { return String(format: "%.1f ชม.", seconds / 3_600) }
            if seconds >= 60 { return "\(Int((seconds / 60).rounded())) นาที" }
            return "\(Int(seconds.rounded())) วิ"
        }
    }

    public let rows: [Row]
    public let start: Date
    public let end: Date

    /// Nothing has been worked on yet. Distinct from having no plan: a plan with
    /// leaves and no work still produces rows, all of them empty.
    public var isEmpty: Bool { rows.allSatisfy { !$0.hasStarted } }

    public var axisSeconds: TimeInterval { max(0, end.timeIntervalSince(start)) }

    // ─────────────────────────────────────────────────────────

    /// The shortest axis worth drawing. Everything happening inside one second
    /// would otherwise divide by zero; a minute floor also stops a project's
    /// whole history collapsing onto a single vertical line on its first day.
    static let shortestAxis: TimeInterval = 60

    public static func build(intervals: [Interval],
                             leaves: [WorkPackage]) -> ScheduleTimeline {
        let usable = intervals.filter { $0.end >= $0.start }
        // Ordered before anything is positioned, so the same data always draws
        // the same picture whatever order the database returned rows in.
        let ordered = usable.sorted { ($0.start, $0.id) < ($1.start, $1.id) }

        let first = ordered.first?.start ?? Date()
        let rawLast = ordered.map(\.end).max() ?? first
        let last = max(rawLast, first.addingTimeInterval(shortestAxis))
        let axis = last.timeIntervalSince(first)

        func segment(_ interval: Interval) -> Segment {
            Segment(id: interval.id, start: interval.start, end: interval.end,
                    succeeded: interval.succeeded,
                    from: interval.start.timeIntervalSince(first) / axis,
                    to: interval.end.timeIntervalSince(first) / axis)
        }

        var byPackage: [String: [Interval]] = [:]
        var unplanned: [Interval] = []
        for interval in ordered {
            if let package = interval.workPackage { byPackage[package, default: []].append(interval) }
            else { unplanned.append(interval) }
        }

        func row(_ packageID: String?, _ title: String, _ intervals: [Interval]) -> Row {
            let segments = intervals.map(segment)
            // Summed, never wall-clocked — the same rule
            // `elapsedByWorkPackage` follows, for the same reason.
            let worked = intervals.reduce(0.0) { $0 + $1.seconds }
            let calendar = zip(intervals.map(\.start).min(), intervals.map(\.end).max())
                .map { $1.timeIntervalSince($0) } ?? 0
            return Row(packageID: packageID, title: title, segments: segments,
                       workedSeconds: worked, calendarSeconds: max(0, calendar))
        }

        // Plan order, so the chart reads down the plan rather than down whatever
        // happened to start first.
        var rows = leaves
            .sorted { ($0.order, $0.title) < ($1.order, $1.title) }
            .map { row($0.id, $0.title, byPackage[$0.id] ?? []) }

        // Work against a leaf that is no longer in the plan. Deleting a package
        // does not un-spend the hours, and dropping the row would quietly shrink
        // the project's recorded time.
        let known = Set(leaves.map(\.id))
        for (packageID, intervals) in byPackage.sorted(by: { $0.key < $1.key })
        where !known.contains(packageID) {
            rows.append(row(packageID, "ใบงานที่ถูกลบไปแล้ว (\(packageID))", intervals))
        }

        if !unplanned.isEmpty {
            rows.append(row(nil, "งานที่ไม่ได้ผูกกับใบงาน", unplanned))
        }
        return ScheduleTimeline(rows: rows, start: first, end: last)
    }
}

/// `zip` for two optionals — both present or nothing.
private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
