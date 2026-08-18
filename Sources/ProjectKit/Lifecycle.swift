import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The stage machine (ARCHITECTURE §19.4, P10.2).
//
// PRINCE2's "manage by stages" is only worth borrowing if the boundaries are
// real: a stage you can walk out of by setting a field is a label, and this
// project has already learned what labels are worth (`Scope.project` was one
// for nine phases).
//
// So there is exactly one way to change `Project.stage` — `advance` — and it
// refuses unless the gate's conditions hold. The conditions themselves are
// values, not prose, because a gate whose criteria are a paragraph is a gate
// somebody argues with rather than passes.
// ─────────────────────────────────────────────────────────────

/// One condition of a gate, and whether it currently holds.
public struct GateCondition: Sendable, Equatable {
    public let text: String
    public let satisfied: Bool
    /// True when the condition holds only because there is nothing to check.
    ///
    /// Driving the screen showed why this exists: with no work packages yet,
    /// every per-leaf condition rendered a green tick, and a tick that means
    /// "nothing was checked" looks exactly like one that means "checked and
    /// fine". It still does not block the gate — vacuous is not failing — but
    /// it must not read as passed.
    public let vacuous: Bool

    public init(text: String, satisfied: Bool, vacuous: Bool = false) {
        self.text = text
        self.satisfied = satisfied
        self.vacuous = vacuous
    }
}

public struct GateEvaluation: Sendable, Equatable {
    public let gate: String
    public let from: ProjectStage
    public let to: ProjectStage
    public let conditions: [GateCondition]

    public var passed: Bool { conditions.allSatisfy(\.satisfied) }
    public var unmet: [String] { conditions.filter { !$0.satisfied }.map(\.text) }
}

public enum LifecycleError: Error, CustomStringConvertible, Equatable {
    case notForward(from: ProjectStage, to: ProjectStage)
    case gateNotPassed(gate: String, unmet: [String])
    case alreadyClosed
    case dispositionIncomplete
    /// A write to a project that has been closed (§19.1.1, P21.3).
    ///
    /// Distinct from `alreadyClosed`, which means "there is no next stage to
    /// advance to". This one means "the agreement is final" — an archive that
    /// can still be edited makes the closing report describe something that
    /// changed after it was written.
    case projectIsArchived(name: String)

    public var description: String {
        switch self {
        case .notForward(let from, let to):
            return t("A stage cannot go backwards: \(from.label) → \(to.label)",
                     "Refusal message. Placeholders: the current stage and the one asked for.")
        case .gateNotPassed(let gate, let unmet):
            return t("\(gate) cannot pass yet — outstanding: ",
                     "Refusal message. Placeholder is the gate name; the unmet conditions follow.")
                + unmet.joined(separator: " · ")
        case .alreadyClosed:
            return t("The project is closed", "Refusal message when the project has ended.")
        case .dispositionIncomplete:
            return t("Both the policy applied and the name of who decided are required",
                     "Refusal message when a data-disposition decision is incomplete.")
        case .projectIsArchived(let name):
            return t("“\(name)” is closed — everything can be read, nothing can be changed (recording a benefit measured later is still allowed, because that adds a fact rather than amending an agreement)",
                     "Refusal message for an archived project. Placeholder is its name.")
        }
    }
}

extension GateCondition {
    /// Same condition, tagged as unchecked when the plan is still empty.
    init(vacuousWhenEmpty empty: Bool, text: String, satisfied: Bool) {
        self.init(text: text, satisfied: satisfied, vacuous: empty)
    }
}

/// Everything G4 asks about that is not in the plan (ARCHITECTURE §19.12).
///
/// The three optional fields are optional for one reason: they live in stores
/// this module does not own, and "nobody asked" must not arrive at the gate
/// looking like "asked and fine". `nil` fails the condition and says so in the
/// text — the same rule the stage gate uses for a project it cannot read
/// ("no way to ask is not the same as permission"), and the reason the eight conditions do not
/// quietly shrink to five when a store is missing.
public struct ClosingFacts: Sendable, Equatable {
    /// Risks, issues and change requests still open (§19.11). Transferring one
    /// out with a named owner is what closing it means here.
    public var openRegisterEntries: Int
    /// Unresolved contradictions in the knowledge base (§11.6). `nil` when the
    /// ledger was not consulted.
    public var openConflicts: Int?
    /// Analysis-plan decisions still marked `agent_suggested` (§12.4). An
    /// approved plan has none by construction, so a project closing with some
    /// has assumptions nobody confirmed. `nil` when the plans were not read.
    public var pendingAssumptions: Int?
    /// Practices with neither a real thing nor a tailoring record (§19.15).
    /// `nil` when conformance was not evaluated.
    public var conformanceGaps: [Practice]?
    /// What happens to the data and files (§19.12 condition 8).
    public var dataDisposition: DataDisposition?
    /// Whether this project ever collected answers from people (§20.5, P11.10).
    /// `nil` when the store was not consulted, which blocks — the same rule the
    /// other optional facts here follow.
    public var heldHumanData: Bool?
    /// Retention rules found in the project's `policy` scope.
    public var retentionRules: [RetentionRule]

    public init(openRegisterEntries: Int = 0,
                openConflicts: Int? = nil,
                pendingAssumptions: Int? = nil,
                conformanceGaps: [Practice]? = nil,
                dataDisposition: DataDisposition? = nil,
                heldHumanData: Bool? = nil,
                retentionRules: [RetentionRule] = []) {
        self.openRegisterEntries = openRegisterEntries
        self.openConflicts = openConflicts
        self.pendingAssumptions = pendingAssumptions
        self.conformanceGaps = conformanceGaps
        self.dataDisposition = dataDisposition
        self.heldHumanData = heldHumanData
        self.retentionRules = retentionRules
    }

    /// Condition 8's answer (§20.5, P11.10).
    public var retention: RetentionCheck.Result {
        RetentionCheck.evaluate(disposition: dataDisposition,
                                heldHumanData: heldHumanData,
                                rules: retentionRules)
    }
}

/// What G2 needs to know about a study before its plan is agreed (§12.6.1,
/// P19.6).
///
/// Its own type rather than two more arguments, and defaulting to "not a study
/// that collects from people": the gate must be vacuous for the projects it
/// does not apply to, or it becomes a field people fill in with anything.
public struct StudyFacts: Sendable, Equatable {
    public var collectsPrimaryData: Bool
    /// The size and what it assumed. Both together — a size with no assumption
    /// is a number nobody, least of all an ethics committee, can check.
    public var plannedSampleSize: Int?
    public var sampleSizeAssumption: String

    public var hasPlannedSampleSize: Bool {
        (plannedSampleSize ?? 0) > 0 && !sampleSizeAssumption.isEmpty
    }

    public init(collectsPrimaryData: Bool = false,
                plannedSampleSize: Int? = nil,
                sampleSizeAssumption: String = "") {
        self.collectsPrimaryData = collectsPrimaryData
        self.plannedSampleSize = plannedSampleSize
        self.sampleSizeAssumption = sampleSizeAssumption
    }
}

/// The two facts G4 needs from stores ProjectKit does not own (§19.12
/// conditions 4 and 5).
///
/// One protocol rather than two because a project that can answer one can answer
/// the other — both are "what is still unresolved about what this project
/// concluded", and splitting them would only make it possible to wire half.
public protocol ClosingLedgerReading: Sendable {
    /// Contradictions still waiting for a person (§11.6).
    func openConflictCount(scope: Scope) async -> Int
    /// Analysis-plan decisions still marked `agent_suggested` (§12.4).
    func unconfirmedAssumptionCount(scope: Scope) async -> Int
}

public enum ProjectLifecycle {
    /// What the next stage is. Stages are walked one at a time on purpose:
    /// skipping Planning is how a project ends up executing against a scope
    /// nobody agreed to.
    public static func next(after stage: ProjectStage) -> ProjectStage? {
        switch stage {
        case .initiation: .planning
        case .planning: .execution
        case .execution: .closing
        case .closing: .closed
        case .closed: nil
        }
    }

    /// The gate between `project.stage` and the stage after it.
    /// `typeGates` are the extra gates this project's *type* declared (§20.2),
    /// and `typeFacts` is what the system can say about the conditions they name.
    /// They are checked on the way out of execution — see `TypeGates.swift` for
    /// why there and not at a milestone of their own.
    public static func evaluate(_ project: Project,
                                wbs: WorkBreakdown = WorkBreakdown(),
                                hasLessons: Bool = true,
                                drift: BaselineDiff? = nil,
                                undecidedChanges: Int = 0,
                                closing: ClosingFacts = ClosingFacts(),
                                typeGates: [ProjectTypeGate] = [],
                                typeFacts: TypeGateFacts = TypeGateFacts(),
                                study: StudyFacts = StudyFacts()) -> GateEvaluation? {
        guard let to = next(after: project.stage), let gate = project.stage.exitGate else {
            return nil
        }
        let problems = wbs.problems(inScope: project.statement.inScope)
        let openWorkPackages = wbs.openLeaves.count

        let conditions: [GateCondition]
        switch project.stage {
        case .initiation:
            // §19.6 — the out-of-scope list is required, not encouraged. It is
            // the half people skip, and the half an agent needs in order to
            // refuse work with a reason.
            conditions = [
                GateCondition(text: t("The project has a name", "G1 gate condition."),
                              satisfied: !project.name.trimmingCharacters(in: .whitespaces).isEmpty),
                GateCondition(text: t("There is a reason for doing it (the brief)", "G1 gate condition."),
                              satisfied: !project.brief.trimmingCharacters(in: .whitespaces).isEmpty),
                GateCondition(text: t("At least one thing in scope", "G1 gate condition."),
                              satisfied: !project.statement.inScope.isEmpty),
                GateCondition(text: t("At least one thing out of scope", "G1 gate condition."),
                              satisfied: !project.statement.outOfScope.isEmpty),
                // §19.5 — the seat that is never an agent's. Empty by default
                // rather than filled in with a plausible name: the point of
                // the rule is that somebody put their own name there.
                GateCondition(text: t("A named human business owner (Executive)",
                                      "G1 gate condition. Executive is the standard role name."),
                              satisfied: project.executive?.isFilled == true),
            ]
        case .planning:
            let noLeaves = wbs.leaves.isEmpty
            // G2 is where the plan stops being a list of intentions. Each
            // condition names a plan that looks finished and is not (§19.6).
            let uncovered = wbs.uncoveredScope(inScope: project.statement.inScope)
            conditions = [
                GateCondition(text: t("At least one acceptance criterion", "G2 gate condition."),
                              satisfied: !project.statement.acceptanceCriteria.isEmpty),
                GateCondition(text: t("At least one work package", "G2 gate condition."),
                              satisfied: !wbs.leaves.isEmpty),
                GateCondition(vacuousWhenEmpty: noLeaves,
                              text: t("Every work package says what done means", "G2 gate condition."),
                              satisfied: !problems.contains { $0.kind == .noAcceptanceCriteria }),
                GateCondition(vacuousWhenEmpty: noLeaves,
                              text: t("Every work package is tied to something in scope", "G2 gate condition."),
                              satisfied: !problems.contains {
                                  $0.kind == .noScopeRef || $0.kind == .danglingScopeRef
                              }),
                GateCondition(vacuousWhenEmpty: noLeaves,
                              text: t("No parent package is empty", "G2 gate condition."),
                              satisfied: !problems.contains { $0.kind == .emptyGroup }),
                GateCondition(vacuousWhenEmpty: noLeaves,
                              text: t("Every work package has exactly one accountable (A)",
                                      "G2 gate condition. A is the RACI letter."),
                              satisfied: !problems.contains { $0.kind == .noAccountable }),
                GateCondition(vacuousWhenEmpty: noLeaves,
                              text: t("High-risk work has a person accountable", "G2 gate condition."),
                              satisfied: !problems.contains { $0.kind == .highRiskWithoutHuman }),
                GateCondition(vacuousWhenEmpty: noLeaves,
                              text: t("The structure is whole (no orphan package)", "G2 gate condition."),
                              satisfied: !problems.contains {
                                  $0.kind == .missingParent || $0.kind == .cycle
                              }),
                GateCondition(vacuousWhenEmpty: noLeaves,
                              text: t("No dependency waits on itself", "G2 gate condition."),
                              satisfied: !problems.contains {
                                  $0.kind == .dependencyCycle || $0.kind == .missingDependency
                              }),
                // The other half of the 100% rule: work that covers nothing is
                // caught above, scope that nothing covers is caught here.
                GateCondition(text: t("Every in-scope line has a work package behind it", "G2 gate condition."),
                              satisfied: uncovered.isEmpty),
                // §12.6.1 / P19.6 — asked here because here is the last moment
                // it can change anything. A study too small to see the effect
                // it was designed around does not produce "no effect"; it
                // produces nothing, at the same cost in people's time and
                // consent. Vacuous for projects that collect no primary data:
                // a gate that asks everybody produces a number everybody types
                // past.
                // Vacuous rather than satisfied for a project that collects
                // nothing from people: it does not block, and it must not
                // render as a green tick that means "checked and fine" — the
                // distinction this type was given a third state for.
                GateCondition(vacuousWhenEmpty: !study.collectsPrimaryData,
                              text: t("Work collecting data from people states its sample size and the assumptions behind it",
                                      "G2 gate condition for studies with human participants."),
                              satisfied: !study.collectsPrimaryData
                                  || study.hasPlannedSampleSize),
            ]
        case .execution:
            // The type's own gates are checked here, last, so the standard three
            // read first and the extra ones read as what they are: what *this
            // kind* of project promised on top (§20.2).
            conditions = [
                GateCondition(text: t("No unfinished work package", "G3 gate condition."),
                              satisfied: openWorkPackages == 0),
                // §19.11 — the plan may have moved, but it may not have moved
                // *quietly*: drift that no change request accounts for is the
                // difference between a project that changed and one that was
                // rewritten.
                GateCondition(text: t("No undecided change request", "G3 gate condition."),
                              satisfied: undecidedChanges == 0),
                GateCondition(text: t("The plan matches the latest baseline", "G3 gate condition."),
                              satisfied: drift?.isEmpty ?? true),
            ] + TypeGateConditions.conditions(for: typeGates, facts: typeFacts)
        case .closing:
            // §19.12's eight, in the standard's order. This is the project's own
            // rule turned on itself — README §5's "never mark work done while
            // anything is outstanding" as eight things a gate reads rather than a sentence
            // somebody remembers.
            let delivered = wbs.leaves.filter { $0.status == .done }
            let unreviewed = delivered.filter { !$0.evidence.contains(where: \.passed) }
            conditions = [
                GateCondition(text: t("No unfinished work package", "G3 gate condition."),
                              satisfied: openWorkPackages == 0),
                GateCondition(vacuousWhenEmpty: delivered.isEmpty,
                              text: t("Every finished package has evidence QA accepted", "G4 gate condition."),
                              satisfied: unreviewed.isEmpty),
                GateCondition(text: t("No open risk, issue or change request", "G4 gate condition."),
                              satisfied: closing.openRegisterEntries == 0),
                GateCondition(text: closing.openConflicts == nil
                              ? t("No conflict left open in the knowledge base (cannot be checked — not connected to it)",
                                  "G4 gate condition when the knowledge base is unreachable.")
                              : t("No conflict left open in the knowledge base", "G4 gate condition."),
                              satisfied: closing.openConflicts == 0),
                GateCondition(text: closing.pendingAssumptions == nil
                              ? t("No assumption an agent guessed is still unconfirmed (cannot be checked — not connected to the analysis plan)",
                                  "G4 gate condition when the analysis plan is unreachable.")
                              : t("No assumption an agent guessed is still unconfirmed", "G4 gate condition."),
                              satisfied: closing.pendingAssumptions == 0),
                GateCondition(text: {
                                  guard let gaps = closing.conformanceGaps else {
                                      return t("Every ISO 21502 practice has evidence or a recorded decision not to do it (not checked yet)",
                                               "G4 gate condition before conformance has been evaluated.")
                                  }
                                  guard !gaps.isEmpty else {
                                      return t("Every ISO 21502 practice has evidence or a recorded decision not to do it",
                                               "G4 gate condition.")
                                  }
                                  // Naming them matters: "conformance failed"
                                  // sends somebody hunting through seventeen
                                  // rows for the two that are empty.
                                  return t("Practices still unanswered: ",
                                           "Prefix before the list of unanswered practices.")
                                      + gaps.map(\.label).joined(separator: " · ")
                              }(),
                              satisfied: closing.conformanceGaps?.isEmpty == true),
                // Recorded here, published on the way out (`advance`): a lesson
                // cannot be in `central` before the project is closed, so the
                // gate checks the half that can be true now and says so.
                GateCondition(text: t("At least one lesson recorded (it flows into the shared base at closing)",
                                      "G4 gate condition."),
                              satisfied: hasLessons),
                // Condition 8 keeps its original job — every project has to say
                // where its files go — and P11.10 adds the half that was missing:
                // when the project collected answers from people, the retention
                // policy it names has to be one that really exists in the
                // `policy` scope (§20.5). Free text used to satisfy this.
                {
                    guard closing.dataDisposition?.isDecided == true else {
                        return GateCondition(text: t("It has been decided where the remaining data and files go",
                                              "G4 gate condition on data disposition."),
                                             satisfied: false)
                    }
                    switch closing.retention {
                    case .notApplicable:
                        return GateCondition(text: t("It has been decided where the remaining data and files go",
                                              "G4 gate condition on data disposition."),
                                             satisfied: true)
                    case .unchecked(let note):
                        // Not a block: one unwired reader must not stop every
                        // project from closing (the ProjectTypeGate decision).
                        // Not a tick either — U21-2.
                        return GateCondition(text: t("It has been decided where the remaining data and files go · ",
                                                     "G4 gate condition on data disposition; a note about what could not be checked follows.")
                                                   + note,
                                             satisfied: true, vacuous: true)
                    case .satisfied(let obligation):
                        return GateCondition(text: t("Where the data goes: ",
                                                     "Prefix before the retention obligation that applies.")
                                                   + obligation.summary,
                                             satisfied: true)
                    case .blocked(let why):
                        return GateCondition(text: why, satisfied: false)
                    }
                }(),
            ]
        case .closed:
            conditions = []
        }
        return GateEvaluation(gate: gate, from: project.stage, to: to, conditions: conditions)
    }
}
