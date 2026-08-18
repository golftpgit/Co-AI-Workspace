import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Editing a plan that has already been agreed (ARCHITECTURE §19.2.4, §19.11,
// P10.16).
//
// §19.2.4 settles the behaviour, and it is not "block the edit": it is **say so
// at the moment of editing**. Before a baseline exists, editing the plan *is*
// writing the plan and nothing here fires. After one exists, the same edit is a
// change to an agreement, so the screen puts the consequence in front of the
// person before they confirm — which change request this becomes, and what it
// does to scope, time and money.
//
// Two properties make that honest rather than decorative:
//
//  • **The preview is the commit.** `applying` produces the plan the edit would
//    result in, and the impact is computed from *that* — not from a description
//    of the edit. A preview computed a second way is a preview that can be
//    wrong, which is worse than none.
//  • **An estimate says what it rests on.** Time and cost are extrapolated from
//    leaves this project has actually finished; with nothing finished, the
//    fields say there is no basis instead of printing a zero. A change request
//    reading "time +0" would be quoted as "no delay expected" (§19.10's rule
//    about unmeasured numbers, in the place where it does the most damage).
// ─────────────────────────────────────────────────────────────

/// One thing a person can change about an agreed plan. Everything the Plan area
/// edits inline goes through one of these four, so there is exactly one place
/// where "this is now a change request" can be decided.
public enum PlanEdit: Sendable, Equatable {
    /// Adding a leaf or editing one — title, criteria, scope link, risk class,
    /// role, RACI, dependencies, order. One case, because from change control's
    /// point of view they are the same event: the agreed plan now says something
    /// else about this deliverable.
    case savePackage(WorkPackage)
    case removePackage(id: String, title: String)
    case scopeStatement(ScopeStatement)
    /// The whole frame, not one axis: the autonomy presets set several at once
    /// (§19.10), and one case means the preset and a single typed number are the
    /// same event to change control.
    case tolerances(Tolerances)

    /// What the change request will be called. Written from the edit rather than
    /// typed, because a change request titled "edit the plan" is one nobody can review.
    public func summary(in wbs: WorkBreakdown, of project: Project) -> String {
        switch self {
        case .savePackage(let package):
            return wbs.packages.contains(where: { $0.id == package.id })
                ? t("Change work package: \(package.title)",
                    "Title of a change request. Placeholder is the package title.")
                : t("Add work package: \(package.title)",
                    "Title of a change request. Placeholder is the package title.")
        case .removePackage(_, let title):
            return t("Remove work package: \(title)",
                     "Title of a change request. Placeholder is the package title.")
        case .scopeStatement:
            return t("Change the project's scope", "Title of a change request.")
        case .tolerances(let next):
            let moved = ToleranceDimension.allCases.filter {
                next.limit($0) != project.tolerances.limit($0)
            }
            return moved.isEmpty
                ? t("Change how far the team may go on its own", "Title of a change request.")
                : t("Change tolerances: ",
                    "Title of a change request; the tolerances that moved follow.")
                    + moved.map {
                    "\($0.label) \(ChangeControl.number(project.tolerances.limit($0)))"
                        + " → \(ChangeControl.number(next.limit($0)))"
                }.joined(separator: " · ")
        }
    }
}

/// What a person is asked to confirm. Every field is a sentence rather than a
/// number so the change register reads the same way a person was told it would.
public struct PlanChangeProposal: Sendable, Equatable {
    public let edit: PlanEdit
    public let title: String
    /// "#4" — which change request in this project's history this becomes.
    public let requestNumber: Int
    public let scopeImpact: String
    public let timeImpact: String
    public let costImpact: String
    /// The drift the plan will have against the current baseline once this is
    /// applied. Distinct from the impact of the edit itself: one edit can be
    /// small while the plan has moved a long way.
    public let driftAfter: String

    /// The one line §19.2.4 asks for, in the words it asks for them.
    public var headline: String {
        t("This edit becomes change request #\(requestNumber) · impact: scope \(scopeImpact), time \(timeImpact), money \(costImpact)",
          "Headline of a pending change. Placeholders: the request number and its three impacts.")
    }

    /// The register entry it becomes on confirmation — the same three impacts,
    /// not a re-derivation of them.
    public var detail: RegisterDetail {
        .change(scopeImpact: scopeImpact, timeImpact: timeImpact, costImpact: costImpact)
    }
}

/// What the app has actually measured, for the two impacts that need history.
public struct ChangeEstimateBasis: Sendable, Equatable {
    /// Seconds recorded against each leaf (§19.7).
    public var elapsedByPackage: [String: TimeInterval]
    /// Money recorded for this project, and whether that number is real.
    public var spent: Double
    public var costMeasured: Bool

    public init(elapsedByPackage: [String: TimeInterval] = [:],
                spent: Double = 0,
                costMeasured: Bool = false) {
        self.elapsedByPackage = elapsedByPackage
        self.spent = spent
        self.costMeasured = costMeasured
    }
}

public enum ChangeControl {

    /// The plan and project the edit would produce. Pure, so the preview and the
    /// commit cannot disagree.
    ///
    /// Removing a parent removes its branch, matching what the store does — a
    /// preview that leaves the children in place would under-report the impact
    /// of exactly the edit people are most likely to regret.
    public static func applying(_ edit: PlanEdit, to wbs: WorkBreakdown,
                                of project: Project) -> (WorkBreakdown, Project) {
        var packages = wbs.packages
        var next = project
        switch edit {
        case .savePackage(let package):
            if let index = packages.firstIndex(where: { $0.id == package.id }) {
                packages[index] = package
            } else {
                packages.append(package)
            }
        case .removePackage(let id, _):
            var doomed: Set<String> = [id]
            var changed = true
            while changed {
                changed = false
                for package in packages where package.parent.map(doomed.contains) == true
                    && !doomed.contains(package.id) {
                    doomed.insert(package.id)
                    changed = true
                }
            }
            packages.removeAll { doomed.contains($0.id) }
        case .scopeStatement(let statement):
            next.statement = statement
        case .tolerances(let limits):
            next.tolerances = limits
        }
        return (WorkBreakdown(packages), next)
    }

    /// The proposal to put in front of a person, or `nil` when this edit is not a
    /// change to anything agreed.
    ///
    /// `nil` in two cases, and they are different: there is no baseline yet (the
    /// plan is still being written), or the edit turns out to change nothing the
    /// baseline holds — reordering siblings, or setting a field to what it
    /// already was. Asking somebody to confirm a change request for a no-op is
    /// how confirmation dialogs get clicked through without reading.
    public static func proposal(for edit: PlanEdit,
                                project: Project,
                                wbs: WorkBreakdown,
                                baseline: Baseline?,
                                existingChanges: Int,
                                basis: ChangeEstimateBasis = ChangeEstimateBasis())
    -> PlanChangeProposal? {
        guard let baseline else { return nil }
        let (after, changedProject) = applying(edit, to: wbs, of: project)

        // The edit's own effect: today's plan treated as the thing being changed.
        let here = Baseline.freeze(project, wbs: wbs, version: 0,
                                   reason: t("now", "Reason recorded on the throwaway baseline used to compute drift."))
        let delta = BaselineDiff.between(here, and: changedProject, wbs: after)
        // A baseline holds the frame as well as the plan (§19.11), so moving a
        // tolerance after G2 is a change to the agreement even though the WBS is
        // untouched — and `BaselineDiff` deliberately does not look at it.
        let toleranceMoved = changedProject.toleranceLimits != project.toleranceLimits
        guard !delta.isEmpty || toleranceMoved else { return nil }

        let driftAfter = BaselineDiff.between(baseline, and: changedProject, wbs: after)
        return PlanChangeProposal(
            edit: edit,
            title: edit.summary(in: wbs, of: project),
            requestNumber: existingChanges + 1,
            scopeImpact: scopeImpact(edit, delta: delta, project: changedProject),
            timeImpact: timeImpact(delta: delta, wbs: wbs, after: after, basis: basis),
            costImpact: costImpact(delta: delta, wbs: wbs, basis: basis),
            driftAfter: driftAfter.summary)
    }

    // MARK: - the three impacts

    private static func scopeImpact(_ edit: PlanEdit, delta: BaselineDiff,
                                    project: Project) -> String {
        if case .tolerances = edit {
            return t("Tolerances changed — the plan did not",
                     "Scope impact when only tolerances moved.")
        }
        var parts: [String] = []
        if !delta.added.isEmpty {
            parts.append(t("+\(delta.added.count) packages",
                           "Scope impact. Placeholder is how many were added."))
        }
        if !delta.removed.isEmpty {
            parts.append(t("−\(delta.removed.count) packages",
                           "Scope impact. Placeholder is how many were removed."))
        }
        if !delta.changed.isEmpty {
            parts.append(t("\(delta.changed.count) packages changed",
                           "Scope impact. Placeholder is how many were edited."))
        }
        if delta.scopeChanged {
            parts.append(t("Scope: \(project.statement.inScope.count) in · \(project.statement.outOfScope.count) out",
                           "Scope impact. Placeholders: how many scope lines in and out."))
        }
        return parts.isEmpty
            ? t("no change", "Impact when nothing moved.")
            : parts.joined(separator: " · ")
    }

    private static func timeImpact(delta: BaselineDiff, wbs: WorkBreakdown,
                                   after: WorkBreakdown, basis: ChangeEstimateBasis) -> String {
        // The part that is a fact: sequencing. Adding a leaf onto the critical
        // chain moves the end; adding one beside it does not, and a plan that
        // reports both the same way teaches people the number is noise.
        let before = Schedule.criticalPaths(wbs).map(\.count).max() ?? 0
        let now = Schedule.criticalPaths(after).map(\.count).max() ?? 0
        var parts: [String] = []
        if now != before {
            parts.append(t("critical path \(before) → \(now) packages",
                           "Time impact. Placeholders: the length before and after."))
        }

        // The part that is an estimate, with its basis attached.
        let finished = wbs.leaves.filter { $0.status == .done }
            .compactMap { basis.elapsedByPackage[$0.id] }
            .filter { $0 > 0 }
        let net = delta.added.count - delta.removed.count
        if net != 0 {
            if finished.isEmpty {
                parts.append(t("cannot be estimated — no work package in this project has measured time yet",
                               "Time impact when there is no history to estimate from."))
            } else {
                let average = finished.reduce(0, +) / Double(finished.count)
                let minutes = Int((average * Double(net) / 60).rounded())
                parts.append(t("≈ \(minutes >= 0 ? "+" : "")\(minutes) minutes (averaged over \(finished.count) finished packages)",
                               "Time impact. Placeholders: the sign, the minutes, and the sample size."))
            }
        }
        return parts.isEmpty
            ? t("no change to the order or the amount of work", "Time impact when nothing moved.")
            : parts.joined(separator: " · ")
    }

    private static func costImpact(delta: BaselineDiff, wbs: WorkBreakdown,
                                   basis: ChangeEstimateBasis) -> String {
        let net = delta.added.count - delta.removed.count
        guard net != 0 else {
            return t("no change to the amount of work", "Cost impact when nothing moved.")
        }
        let finished = wbs.leaves.count { $0.status == .done }
        guard basis.costMeasured, finished > 0, basis.spent > 0 else {
            return t("cannot be estimated — no spending has been recorded to compare against",
                     "Cost impact when there is no history to estimate from.")
        }
        let perLeaf = basis.spent / Double(finished)
        let amount = perLeaf * Double(net)
        return "≈ \(amount >= 0 ? "+" : "−")$\(number(abs(amount))) "
            + t("(averaged over \(finished) finished packages)",
                "Cost impact. Placeholder is the sample size.")
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
