import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The three reports (ARCHITECTURE §19.13, P10.11).
//
// The standards ask for reporting at three rhythms — a status report while a
// stage runs, one at each boundary, one at the end — and the interesting design
// question is not which sections they have. It is where the sentences come from.
//
// Here they come from rows. Every line below is a restatement of something the
// system already recorded: the plan for what was delivered, the ledger for what
// it cost, the registers for what went wrong, the baseline for what changed, the
// benefit ledger for whether it was worth it. Nothing is passed to a model and
// nothing is summarised by one, which is the whole of the Done-when: change the
// source and the report changes, because there is no second copy of the facts.
//
// `ReportBuilder` is a pure function of (kind, inputs, now) for the same reason
// `ToleranceCheck` is: a report is the thing people quote in meetings, and a
// report that cannot be reproduced from stored data is a report nobody can
// check afterwards.
// ─────────────────────────────────────────────────────────────

public enum ReportKind: String, Sendable, Codable, CaseIterable {
    /// While a stage runs, on a cycle or on request.
    case highlight
    /// At a stage boundary, asking to go on.
    case endStage
    /// At closing.
    case endProject

    public var label: String {
        switch self {
        case .highlight: t("Progress report", "Kind of report.")
        case .endStage: t("End-of-stage report", "Kind of report.")
        case .endProject: t("End-of-project report", "Kind of report.")
        }
    }
}

public struct ReportSection: Sendable, Codable, Equatable {
    public let heading: String
    /// Already-formatted lines. Empty is not allowed to happen silently — a
    /// section with nothing in it says so, because a heading with no body reads
    /// as "nothing to report" when it often means "nothing was recorded".
    public let lines: [String]

    public init(heading: String, lines: [String]) {
        self.heading = heading
        self.lines = lines.isEmpty
            ? [t("— nothing recorded —", "Stand-in for an empty report section.")]
            : lines
    }
}

public struct ProjectReport: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    public let kind: ReportKind
    public let title: String
    /// The stage the project was in when this was written. Kept because a
    /// boundary report read a year later is meaningless without it — and named
    /// so it cannot be mistaken for the project's current stage, which only
    /// `ProjectService.advance` may set (§19.15 invariant 1).
    public let stageAtIssue: ProjectStage
    public let generatedAt: Date
    public let sections: [ReportSection]

    public init(id: String = OpaqueID.make(OpaqueID.report),
                projectID: ProjectID,
                kind: ReportKind,
                title: String,
                stageAtIssue: ProjectStage,
                generatedAt: Date,
                sections: [ReportSection]) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.title = title
        self.stageAtIssue = stageAtIssue
        self.generatedAt = generatedAt
        self.sections = sections
    }

    /// The report as text, which is what a channel sends and what the document
    /// writer turns into a file. One rendering, so the version on somebody's
    /// phone is the version in the .docx.
    public var rendered: String {
        var lines = [title, ""]
        lines.append(t("Stage \(stageAtIssue.label) · \(generatedAt.formatted(date: .abbreviated, time: .shortened))",
                       "Report header. Placeholders: the stage and when it was issued."))
        for section in sections {
            lines.append("")
            lines.append(section.heading)
            lines.append(contentsOf: section.lines.map { "• \($0)" })
        }
        lines.append("")
        // The line that makes the rest checkable. Without it a reader has no way
        // to tell this from a summary a model wrote.
        lines.append(t("This report is assembled from what the system recorded (the plan · the register · spans · baselines · the benefit ledger). No sentence in it was written by a model.",
                       "Footer on every report, stating where its content comes from."))
        return lines.joined(separator: "\n")
    }
}

/// Everything the three reports read. Assembled by `ProjectService`, which is
/// the only object holding all of these stores.
public struct ReportInputs: Sendable {
    public var project: Project
    public var wbs: WorkBreakdown
    public var registers: [RegisterEntry]
    public var benefits: BenefitLedger
    public var baselines: [Baseline]
    public var drift: BaselineDiff?
    public var tolerances: [ToleranceStatus]
    /// Which tolerance dimensions the app is actually reading. The rest print as
    /// "not measured yet" — a number nobody measured is worse in a report than in a
    /// status strip, because the report gets quoted.
    public var measured: Set<ToleranceDimension>
    public var elapsedSeconds: TimeInterval
    public var exceptions: [ExceptionReport]
    public var gate: GateEvaluation?
    public var conformance: [PracticeStatus]
    /// When the previous report of this kind was written. "New since last time"
    /// is the only honest reading of "new issue/risk"; without it a highlight
    /// report repeats every risk ever raised.
    public var since: Date?

    public init(project: Project,
                wbs: WorkBreakdown = WorkBreakdown(),
                registers: [RegisterEntry] = [],
                benefits: BenefitLedger = BenefitLedger(),
                baselines: [Baseline] = [],
                drift: BaselineDiff? = nil,
                tolerances: [ToleranceStatus] = [],
                measured: Set<ToleranceDimension> = [],
                elapsedSeconds: TimeInterval = 0,
                exceptions: [ExceptionReport] = [],
                gate: GateEvaluation? = nil,
                conformance: [PracticeStatus] = [],
                since: Date? = nil) {
        self.project = project
        self.wbs = wbs
        self.registers = registers
        self.benefits = benefits
        self.baselines = baselines
        self.drift = drift
        self.tolerances = tolerances
        self.measured = measured
        self.elapsedSeconds = elapsedSeconds
        self.exceptions = exceptions
        self.gate = gate
        self.conformance = conformance
        self.since = since
    }
}

public enum ReportBuilder {

    public static func build(_ kind: ReportKind, from inputs: ReportInputs,
                             now: Date = Date()) -> ProjectReport {
        ProjectReport(projectID: inputs.project.id,
                      kind: kind,
                      title: "\(kind.label): \(inputs.project.name)",
                      stageAtIssue: inputs.project.stage,
                      generatedAt: now,
                      sections: sections(kind, inputs, now))
    }

    private static func sections(_ kind: ReportKind, _ inputs: ReportInputs,
                                 _ now: Date) -> [ReportSection] {
        switch kind {
        case .highlight: highlight(inputs, now)
        case .endStage: endStage(inputs)
        case .endProject: endProject(inputs)
        }
    }

    // MARK: - highlight (§19.13)

    private static func highlight(_ inputs: ReportInputs, _ now: Date) -> [ReportSection] {
        let leaves = inputs.wbs.leaves
        let done = leaves.filter { $0.status == .done }
        let running = leaves.filter { $0.status == .inProgress || $0.status == .inReview }
        let next = Schedule.ready(inputs.wbs)
        let fresh = inputs.registers.filter { entry in
            guard [RegisterKind.risk, .issue].contains(entry.kind) else { return false }
            guard let since = inputs.since else { return true }
            // `>=`, not `>`. Both timestamps have been through ISO-8601 without
            // fractional seconds on the way to the database, so two things that
            // happened in the same second come back equal — and with a strict
            // comparison a risk raised in the same second as the previous report
            // is never reported at all. Driving it found exactly that. Repeating
            // one entry is noise; dropping a new one is a missed escalation.
            return entry.createdAt >= since
        }
        return [
            ReportSection(heading: t("Finished", "Report section heading."), lines: done.map(delivered)),
            ReportSection(heading: t("In progress and coming next", "Report section heading."),
                          lines: running.map { "\($0.title) — \($0.status.label)" }
                              + next.map { t("\($0.title) — ready to start",
                                             "A work package that can begin. Placeholder is its title.") }),
            ReportSection(heading: t("Where the agreed tolerances stand now", "Report section heading."),
                          lines: toleranceLines(inputs)),
            ReportSection(heading: inputs.since == nil
                          ? t("Risks and issues on record", "Report section heading for the first report.")
                          : t("Risks and issues new since the previous report",
                              "Report section heading for a later report."),
                          lines: fresh.map {
                              t("[\($0.kind.label)] \($0.title) — \($0.status.label) · raised by \($0.origin.label)",
                                "A register line in a report. Placeholders: its kind, title, status and who raised it.")
                          }),
            ReportSection(heading: t("Time and money spent", "Report section heading."),
                          lines: spendLines(inputs)),
        ]
    }

    // MARK: - end of stage (§19.13)

    private static func endStage(_ inputs: ReportInputs) -> [ReportSection] {
        let approved = inputs.registers.filter { $0.kind == .change && $0.status == .approved }
        var agreement: [String] = []
        if let latest = inputs.baselines.max(by: { $0.version < $1.version }) {
            agreement.append(t("The agreed plan: v\(latest.version) (\(latest.reason)) · \(latest.packages.count) work packages",
                               "Report line. Placeholders: the baseline version, why it was frozen, and how many packages."))
            agreement.append(inputs.drift.map { $0.isEmpty
                ? t("Today's plan matches v\(latest.version)",
                    "Report line when there is no drift. Placeholder is the baseline version.")
                : t("Differs from v\(latest.version): \($0.summary)",
                    "Report line when the plan has drifted. Placeholders: the version and a summary.") }
                ?? t("The difference could not be read", "Report line when drift is unavailable."))
        } else {
            // Before G2 there is no agreement to compare against, and saying so
            // is more useful than printing a variance of zero.
            agreement.append(t("No baseline yet — the plan has never been frozen into an agreement",
                               "Shown in the scope popover when there is nothing to compare against."))
        }
        return [
            ReportSection(heading: t("Against the agreed plan", "Report section heading."), lines: agreement),
            ReportSection(heading: t("Differences and why", "Report section heading."),
                          lines: approved.map { entry in
                              var line = t("\(entry.title) — approved by \(entry.decidedBy ?? "—")",
                                           "A change request in a report. Placeholders: its title and who approved it.")
                              if case .change(let scope, let time, let cost) = entry.detail {
                                  line += t(" · scope: \(scope) · time: \(time) · money: \(cost)",
                                            "The impact of a change request. Placeholders: its scope, time and cost impact.")
                              }
                              return line
                          }),
            ReportSection(heading: t("Is the business case still worth it?", "Report section heading."),
                          lines: benefitLines(inputs)),
            ReportSection(heading: t("Asking to enter the next stage", "Report section heading."),
                          lines: gateLines(inputs)),
        ]
    }

    // MARK: - end of project (§19.13)

    private static func endProject(_ inputs: ReportInputs) -> [ReportSection] {
        let leaves = inputs.wbs.leaves
        let lessons = inputs.registers.filter { $0.kind == .lesson }
        let stillOpen = inputs.registers.filter {
            [RegisterKind.risk, .issue, .change].contains($0.kind) && $0.status.isOpen
        }
        var handover = stillOpen.map {
            t("[\($0.kind.label)] \($0.title) — still open · owner \($0.owner?.label ?? t("nobody yet", "Stand-in when a register entry has no owner."))",
              "An open register entry in a report. Placeholders: its kind, title and owner.")
        }
        // A benefit whose review date is after closing is the most commonly
        // dropped handover item there is, so it is listed as one.
        handover += inputs.benefits.unmeasured.map {
            t("Still to be measured: \($0.title) — due \($0.reviewAt.formatted(date: .abbreviated, time: .omitted)) · \($0.owner.label)",
              "An unmeasured benefit in a report. Placeholders: its title, due date and owner.")
        }
        if let disposition = inputs.project.dataDisposition, disposition.isDecided {
            handover.append(t("Data and files: \(disposition.action.label) under policy “\(disposition.policy)” · decided by \(disposition.decidedBy)",
                              "The data-disposition line in a closing report. Placeholders: the action, the policy and who decided."))
        }
        let tailored = inputs.conformance.filter(\.isTailored)
        var variance: [String] = []
        if let first = inputs.baselines.min(by: { $0.version < $1.version }) {
            variance.append(t("The first agreed plan: v\(first.version) · \(first.packages.count) work packages",
                              "Closing report line. Placeholders: the version and how many packages."))
            variance.append(t("The plan at closing: \(leaves.count) work packages · the agreement changed \(inputs.baselines.count) times",
                              "Closing report line. Placeholders: how many packages and how many baselines."))
        }
        variance.append(contentsOf: spendLines(inputs))
        return [
            ReportSection(heading: t("What was delivered", "Report section heading."),
                          lines: leaves.filter { $0.status == .done }.map(delivered)),
            ReportSection(heading: t("Benefits measured", "Report section heading."),
                          lines: benefitLines(inputs)),
            ReportSection(heading: t("Total variance", "Report section heading."), lines: variance),
            ReportSection(heading: t("Lessons", "Name of an ISO 21502 practice."),
                          lines: lessons.map { entry in
                var line = entry.title
                if case .lesson(let cause, let differently, let appliesTo) = entry.detail {
                    line += t(" — cause: \(cause) · next time: \(differently)",
                              "A lesson in a report. Placeholders: its cause and what to do differently.")
                    if !appliesTo.isEmpty {
                        line += t(" · applies to: \(appliesTo)",
                                  "Where a lesson applies. Placeholder is the list.")
                    }
                }
                return line
            }),
            ReportSection(heading: t("Handed on to somebody else", "Report section heading."), lines: handover),
            ReportSection(heading: t("Practices decided against (tailoring)", "Report section heading."),
                          lines: tailored.map {
                              "\($0.practice.label) — \($0.tailoring?.reason ?? "")"
                                  + t(" · decided by \($0.tailoring?.decidedBy ?? "—")",
                                      "Who decided against a practice. Placeholder is their name.")
                          }),
        ]
    }

    // MARK: - lines shared by more than one report

    private static func delivered(_ package: WorkPackage) -> String {
        let accepted = package.evidence.filter(\.passed)
        let evidence = accepted.isEmpty
            ? t("No evidence QA has accepted yet", "Report line for a package with no accepted evidence.")
            : accepted.map(\.summary).joined(separator: " · ")
        return "\(package.title) — \(evidence)"
    }

    private static func toleranceLines(_ inputs: ReportInputs) -> [String] {
        inputs.tolerances.map { status in
            guard inputs.measured.contains(status.dimension) else {
                return t("\(status.dimension.label): limit \(number(status.limit)) · not measured yet",
                         "A tolerance line in a report. Placeholders: which tolerance and its limit.")
            }
            return "\(status.dimension.label): \(number(status.current)) / \(number(status.limit))"
                + (status.breached
                   ? t(" — breached", "Appended to a tolerance line that has been exceeded.")
                   : "")
        }
        + inputs.exceptions.filter(\.isOpen).map {
            t("Stopped for a decision: the \($0.dimension.label) tolerance was breached — \($0.needsFromHuman)",
              "An open exception in a report. Placeholders: which tolerance and what is needed from a person.")
        }
    }

    private static func benefitLines(_ inputs: ReportInputs) -> [String] {
        guard !inputs.benefits.isEmpty else { return [] }
        return inputs.benefits.benefits.map { benefit in
            guard let achieved = benefit.achievement, let result = benefit.result else {
                return t("\(benefit.title): not measured yet (due \(benefit.reviewAt.formatted(date: .abbreviated, time: .omitted)))",
                         "An unmeasured benefit in a report. Placeholders: its title and due date.")
            }
            return "\(benefit.title): \(number(result.value)) \(benefit.measure)"
                + t(" · from \(number(benefit.baselineValue)) target \(number(benefit.target)) · reached \(Int(achieved * 100))% of target · measured by \(result.measuredBy)",
                    "A measured benefit in a report. Placeholders: the baseline, the target, the percentage reached, and who measured it.")
        }
    }

    private static func gateLines(_ inputs: ReportInputs) -> [String] {
        guard let gate = inputs.gate else {
            return [t("The project is closed — there is no next stage",
                      "Report line for a project with no next gate.")]
        }
        return ["\(gate.gate): \(gate.from.label) → \(gate.to.label) — "
                + (gate.passed
                   ? t("every condition holds", "Report line: the gate passes.")
                   : t("not yet passed", "Report line: the gate does not pass."))]
            + gate.conditions.map { "\($0.satisfied ? "✓" : "✗") \($0.text)" }
    }

    private static func spendLines(_ inputs: ReportInputs) -> [String] {
        var lines: [String] = []
        if inputs.elapsedSeconds > 0 {
            lines.append(t("Time measured from spans: \(Int(inputs.elapsedSeconds / 60)) minutes",
                           "Report line. Placeholder is a number of minutes."))
        } else {
            lines.append(t("Time: no span is tied to any of this project's work packages yet",
                           "Report line when no time has been recorded."))
        }
        if inputs.measured.contains(.cost) {
            lines.append(t("Spending recorded: $\(number(inputs.tolerances.first { $0.dimension == .cost }?.current ?? 0))",
                           "Report line. Placeholder is an amount in the endpoint's currency."))
        } else {
            lines.append(t("Spending: not connected to the ledger yet",
                           "Report line when spending cannot be read."))
        }
        return lines
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Where issued reports are kept. They are history, so there is no update and no
/// delete: "how often did anybody report" is a question about the past, and a
/// report that can be withdrawn afterwards cannot answer it.
public protocol ReportPersisting: Sendable {
    func save(_ report: ProjectReport) async throws
    func all(project: ProjectID) async throws -> [ProjectReport]
}
