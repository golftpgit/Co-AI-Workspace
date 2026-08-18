import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Order and the critical path (ARCHITECTURE §19.7, P10.9).
//
// §19.7 is blunt about what a Gantt for AI work can honestly show. There are no
// person-days here, so the horizontal axis is not calendar time — what *is* real
// today is the order the work must happen in, which chain decides the end, and
// (since assignments became spans) how long each leaf has actually cost.
//
// So this file computes two things and refuses to invent a third:
//
//  • **Topological order** — what can start, and what is waiting on what.
//  • **The critical path** — the longest chain of dependencies, which is the
//    only sequence where being late is the project being late.
//
// Durations are supplied by the caller. When nobody can supply them every
// package weighs 1, and the path is the longest chain rather than the slowest
// one — which is a true statement about the plan, unlike a forecast made of
// numbers a model invented.
// ─────────────────────────────────────────────────────────────

public struct ScheduleEstimate: Sendable, Equatable {
    /// What the band is made of.
    ///
    /// Carried on the estimate rather than remembered by the caller, because
    /// the caller forgot: the time popover spent a release labelled "the same
    /// kind of work" over a band computed from chat turns, and before that from
    /// individual tool calls. A band is a claim about a population, and a claim
    /// whose population is only known at the call site travels without it.
    public enum Basis: Sendable, Equatable {
        /// Whole assignments that produced the same kind of thing, start to
        /// finish, rework included. The population §19.7 asks for.
        case assignments(kind: String)
        /// Completed chat turns by the roles this project assigns to — the
        /// fallback for an install with fewer than three finished assignments
        /// of any one kind. A turn is a smaller unit of work than an
        /// assignment, so this band reads low and must say so.
        case turns
    }

    public let p50: TimeInterval
    public let p90: TimeInterval
    public let sampleCount: Int
    public let basis: Basis

    /// What the sample is counted in, for a sentence that has to name it.
    public var unit: String {
        switch basis {
        case .assignments: t("tasks", "Unit a forecast was computed over.")
        case .turns: t("turns", "Unit a forecast was computed over.")
        }
    }

    public var label: String {
        func minutes(_ seconds: TimeInterval) -> String {
            seconds < 90
                ? t("\(Int(seconds)) s", "A short duration in seconds. Placeholder is a whole number.")
                : t("\(Int(seconds / 60)) min", "A duration in minutes. Placeholder is a whole number.")
        }
        return t("\(minutes(p50))–\(minutes(p90)) (from \(sampleCount) \(unit))",
                 "A forecast band. Placeholders: the p50, the p90, the sample size and its unit.")
    }
}

public enum Schedule {
    /// Leaves in an order that never puts a package before something it waits
    /// on. Packages in a cycle come last rather than disappearing — a plan the
    /// screen cannot draw is a plan nobody can fix.
    public static func order(_ wbs: WorkBreakdown) -> [WorkPackage] {
        let leaves = wbs.leaves
        let byID = Dictionary(leaves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var remaining = leaves
        var placed: [WorkPackage] = []
        var placedIDs = Set<String>()

        while !remaining.isEmpty {
            let ready = remaining.filter { package in
                package.dependsOn.allSatisfy { placedIDs.contains($0) || byID[$0] == nil }
            }
            guard !ready.isEmpty else {
                placed.append(contentsOf: remaining.sorted { $0.order < $1.order })
                break
            }
            let next = ready.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
            placed.append(contentsOf: next)
            placedIDs.formUnion(next.map(\.id))
            remaining.removeAll { placedIDs.contains($0.id) }
        }
        return placed
    }

    /// Every chain that decides the finish, not just one of them.
    ///
    /// Driving the screen showed why this is plural: with two independent
    /// leaves, crowning the first one implies the second is slack, and it is
    /// not — they are both as critical as each other. A single winner is only
    /// honest when there is a single longest chain.
    public static func criticalPaths(_ wbs: WorkBreakdown,
                                     duration: (WorkPackage) -> Double = { _ in 1 }) -> [[String]] {
        let leaves = wbs.leaves
        guard !leaves.isEmpty else { return [] }
        // No dependencies at all means no sequence decides anything: every
        // leaf could start now, and calling one of them critical is a claim
        // about an order that does not exist.
        guard leaves.contains(where: { !$0.dependsOn.isEmpty }) else { return [] }

        var paths: [[String]] = []
        var best = 0.0
        for package in leaves.sorted(by: { ($0.order, $0.title) < ($1.order, $1.title) }) {
            let (weight, path) = weighted(package, wbs: wbs, duration: duration)
            if weight > best {
                best = weight
                paths = [path]
            } else if weight == best, !path.isEmpty, !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }

    private static func weighted(_ package: WorkPackage, wbs: WorkBreakdown,
                                 duration: (WorkPackage) -> Double) -> (Double, [String]) {
        let path = criticalPath(WorkBreakdown(wbs.packages), duration: duration, endingAt: package.id)
        let weight = path.compactMap { id in wbs.packages.first { $0.id == id } }
            .reduce(0.0) { $0 + duration($1) }
        return (weight, path)
    }

    /// The chain that decides the finish, longest-first. Ties break on order so
    /// the same plan always highlights the same path — a critical path that
    /// moves between redraws is one nobody trusts.
    public static func criticalPath(_ wbs: WorkBreakdown,
                                    duration: (WorkPackage) -> Double = { _ in 1 },
                                    endingAt: String? = nil) -> [String] {
        let leaves = wbs.leaves
        let byID = Dictionary(leaves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var best: [String: (weight: Double, path: [String])] = [:]

        func longest(_ package: WorkPackage, _ visiting: Set<String>) -> (Double, [String]) {
            if let cached = best[package.id] { return (cached.weight, cached.path) }
            // A cycle has no longest path; the WBS reports it as a problem and
            // this refuses to loop forever over it.
            guard !visiting.contains(package.id) else { return (0, []) }
            let seen = visiting.union([package.id])

            var bestWeight = 0.0
            var bestPath: [String] = []
            for id in package.dependsOn.sorted() {
                guard let parent = byID[id] else { continue }
                let (weight, path) = longest(parent, seen)
                if weight > bestWeight || (weight == bestWeight && path.count > bestPath.count) {
                    bestWeight = weight
                    bestPath = path
                }
            }
            let total = bestWeight + duration(package)
            let path = bestPath + [package.id]
            best[package.id] = (total, path)
            return (total, path)
        }

        if let endingAt {
            guard let package = byID[endingAt] else { return [] }
            return longest(package, []).1
        }
        var winner: (weight: Double, path: [String]) = (0, [])
        for package in leaves.sorted(by: { ($0.order, $0.title) < ($1.order, $1.title) }) {
            let (weight, path) = longest(package, [])
            if weight > winner.weight { winner = (weight, path) }
        }
        return winner.path
    }

    /// What can be started right now: everything whose dependencies are done.
    public static func ready(_ wbs: WorkBreakdown) -> [WorkPackage] {
        let done = Set(wbs.leaves.filter { $0.status == .done }.map(\.id))
        return wbs.leaves.filter { package in
            package.status.isOpen && package.dependsOn.allSatisfy { done.contains($0) }
        }
    }

    /// p50/p90 of past durations. `nil` for fewer than three samples: two
    /// measurements are not a distribution, and a band drawn from them is a
    /// guess wearing a statistic's clothes (§19.7).
    ///
    /// `basis` has no default on purpose. Every caller has to say what it
    /// measured, because the two times this band was wrong it was not the
    /// arithmetic that was wrong — it was that nobody could see, at the call
    /// site, which population had been handed in.
    public static func estimate(from durations: [TimeInterval],
                                basis: ScheduleEstimate.Basis) -> ScheduleEstimate? {
        let sorted = durations.filter { $0 > 0 }.sorted()
        guard sorted.count >= 3 else { return nil }
        func quantile(_ q: Double) -> TimeInterval {
            let position = q * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, sorted.count - 1)
            let fraction = position - Double(lower)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        }
        return ScheduleEstimate(p50: quantile(0.5), p90: quantile(0.9),
                                sampleCount: sorted.count, basis: basis)
    }
}
