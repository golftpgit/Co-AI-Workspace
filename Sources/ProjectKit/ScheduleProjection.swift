import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Where the work that has not started would land (ARCHITECTURE §19.7, P10.9's
// third axis · risk R9).
//
// The calendar axis already draws what happened (`ScheduleTimeline`), and the
// order box already knows which chain decides the end (`Schedule.criticalPaths`).
// What neither can say is **when a leaf that has not started would run** — and
// that is the half of a plan somebody actually opens it for.
//
// The whole difficulty is R9: a projection is where a schedule starts lying.
// Three rules keep this one honest, and each removes a way of inventing a date:
//
//  • **No population, no date.** A leaf whose kind of work has never been
//    finished here gets no projection at all — not a default, not an average of
//    everything, not "1 day". It is reported as unforecastable, by name, and
//    the screen says so.
//  • **Two dates, never one.** Every projection is a p50–p90 range from real
//    durations. A single date is a promise; a range is a measurement.
//  • **Unknowns propagate.** A leaf that depends on an unforecastable one has
//    no honest earliest start either, so it is unforecastable too. Silently
//    treating the unknown as zero would push a confident date onto work whose
//    predecessor nobody can time — the most expensive kind of wrong here.
//
// The forward pass itself is ordinary: a leaf may start when its dependencies
// have finished, and finishes p50 (or p90) later. Both ends are computed, which
// is why the result is a band and not a bar.
// ─────────────────────────────────────────────────────────────

public struct ProjectedLeaf: Sendable, Equatable, Identifiable {
    public let packageID: String
    public let title: String
    /// Earliest start under the optimistic (p50) pass and the cautious (p90)
    /// one. They differ because everything upstream also moves.
    public let earliestStart: Date
    public let latestStart: Date
    public let p50Finish: Date
    public let p90Finish: Date
    /// How many finished pieces of work the band is made of, so the screen can
    /// say "จาก 6 งาน" rather than presenting a number with no provenance.
    public let sampleCount: Int

    public var id: String { packageID }
}

public struct ScheduleProjection: Sendable, Equatable {
    public let leaves: [ProjectedLeaf]
    /// Leaves with no honest projection, and why — by name, because a chart
    /// that quietly omits work reads as a chart of all the work.
    public let unforecastable: [(packageID: String, title: String, reason: String)]
    /// The end of the p90 pass across everything projectable. `nil` when
    /// nothing could be projected.
    public let p90Finish: Date?

    public static func == (lhs: ScheduleProjection, rhs: ScheduleProjection) -> Bool {
        lhs.leaves == rhs.leaves && lhs.p90Finish == rhs.p90Finish
            && lhs.unforecastable.map(\.packageID) == rhs.unforecastable.map(\.packageID)
    }
}

public enum ScheduleForecast {

    /// - Parameters:
    ///   - wbs: the plan, for its leaves and their dependencies.
    ///   - started: leaves that already have recorded work. They are not
    ///     projected — what happened is drawn from spans, and a forecast laid
    ///     over measured work is a guess arguing with a fact.
    ///   - estimate: the band for a leaf, or `nil` when nothing comparable has
    ///     ever finished. The caller owns this because the population lives in
    ///     the span store.
    ///   - now: when the projection starts.
    public static func project(_ wbs: WorkBreakdown,
                               started: Set<String>,
                               now: Date,
                               estimate: (WorkPackage) -> ScheduleEstimate?) -> ScheduleProjection {
        let ordered = Schedule.order(wbs)
        var p50Finish: [String: Date] = [:]
        var p90Finish: [String: Date] = [:]
        var leaves: [ProjectedLeaf] = []
        var unforecastable: [(packageID: String, title: String, reason: String)] = []
        var unknown: Set<String> = []

        // `Schedule.order` already returns leaves only, in dependency order —
        // the same order the critical path is read from, so a projection and
        // the chain that decides the end can never disagree about sequence.
        for package in ordered {
            // Work already under way is measured, not projected.
            if started.contains(package.id) { continue }

            let blockers = package.dependsOn.filter { unknown.contains($0) }
            guard blockers.isEmpty else {
                unknown.insert(package.id)
                unforecastable.append((package.id, package.title,
                                       "ขึ้นกับใบงานที่ยังประมาณเวลาไม่ได้ (\(blockers.count) ใบ) — "
                                           + "ถ้านับใบที่ไม่รู้เป็นศูนย์ ใบนี้จะได้วันที่ดูมั่นใจโดยไม่มีอะไรรองรับ"))
                continue
            }
            guard let band = estimate(package) else {
                unknown.insert(package.id)
                unforecastable.append((package.id, package.title,
                                       "ยังไม่เคยมีงานชนิดเดียวกันเสร็จในระบบนี้ — ไม่มีตัวเลขจริงให้ประมาณ"))
                continue
            }

            let optimisticStart = package.dependsOn.compactMap { p50Finish[$0] }.max() ?? now
            let cautiousStart = package.dependsOn.compactMap { p90Finish[$0] }.max() ?? now
            let finish50 = optimisticStart.addingTimeInterval(band.p50)
            let finish90 = cautiousStart.addingTimeInterval(band.p90)
            p50Finish[package.id] = finish50
            p90Finish[package.id] = finish90

            leaves.append(ProjectedLeaf(packageID: package.id, title: package.title,
                                        earliestStart: optimisticStart,
                                        latestStart: cautiousStart,
                                        p50Finish: finish50, p90Finish: finish90,
                                        sampleCount: band.sampleCount))
        }

        return ScheduleProjection(leaves: leaves,
                                  unforecastable: unforecastable,
                                  p90Finish: leaves.map(\.p90Finish).max())
    }
}
