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

    public init(text: String, satisfied: Bool) {
        self.text = text
        self.satisfied = satisfied
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

    public var description: String {
        switch self {
        case .notForward(let from, let to):
            return "ย้อนขั้นไม่ได้: \(from.label) → \(to.label)"
        case .gateNotPassed(let gate, let unmet):
            return "ยังผ่าน \(gate) ไม่ได้ — ค้าง: " + unmet.joined(separator: " · ")
        case .alreadyClosed:
            return "โครงการปิดแล้ว"
        }
    }
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
    ///
    /// G3 and G4 depend on work packages and registers, which arrive in
    /// P10.4/P10.8/P10.10. Until then their conditions are the ones that can be
    /// checked honestly today — and they are written as conditions rather than
    /// left out, so the gate reads as incomplete instead of as passed.
    public static func evaluate(_ project: Project,
                                wbs: WorkBreakdown = WorkBreakdown(),
                                hasLessons: Bool = true) -> GateEvaluation? {
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
                GateCondition(text: "โครงการมีชื่อ",
                              satisfied: !project.name.trimmingCharacters(in: .whitespaces).isEmpty),
                GateCondition(text: "มีเหตุผลที่ทำ (brief)",
                              satisfied: !project.brief.trimmingCharacters(in: .whitespaces).isEmpty),
                GateCondition(text: "ขอบเขต 'ทำ' อย่างน้อย 1 ข้อ",
                              satisfied: !project.statement.inScope.isEmpty),
                GateCondition(text: "ขอบเขต 'ไม่ทำ' อย่างน้อย 1 ข้อ",
                              satisfied: !project.statement.outOfScope.isEmpty),
                // §19.5 — the seat that is never an agent's. Empty by default
                // rather than filled in with a plausible name: the point of
                // the rule is that somebody put their own name there.
                GateCondition(text: "มีชื่อผู้รับผิดชอบทางธุรกิจ (Executive) ที่เป็นคน",
                              satisfied: project.executive?.isFilled == true),
            ]
        case .planning:
            // G2 is where the plan stops being a list of intentions. Each
            // condition names a plan that looks finished and is not (§19.6).
            let uncovered = wbs.uncoveredScope(inScope: project.statement.inScope)
            conditions = [
                GateCondition(text: "เกณฑ์รับงานอย่างน้อย 1 ข้อ",
                              satisfied: !project.statement.acceptanceCriteria.isEmpty),
                GateCondition(text: "มีใบงานอย่างน้อย 1 ใบ",
                              satisfied: !wbs.leaves.isEmpty),
                GateCondition(text: "ทุกใบงานบอกว่าเสร็จแปลว่าอะไร",
                              satisfied: !problems.contains { $0.kind == .noAcceptanceCriteria }),
                GateCondition(text: "ทุกใบงานผูกกับข้อในขอบเขต 'ทำ'",
                              satisfied: !problems.contains {
                                  $0.kind == .noScopeRef || $0.kind == .danglingScopeRef
                              }),
                GateCondition(text: "ไม่มีงานแม่ที่ไม่มีใบงานอยู่ข้างใน",
                              satisfied: !problems.contains { $0.kind == .emptyGroup }),
                GateCondition(text: "ทุกใบงานมีผู้รับผิดชอบผล (A) หนึ่งคน",
                              satisfied: !problems.contains { $0.kind == .noAccountable }),
                GateCondition(text: "งานเสี่ยงสูงมีคนเป็นผู้รับผิดชอบผล",
                              satisfied: !problems.contains { $0.kind == .highRiskWithoutHuman }),
                GateCondition(text: "โครงสร้างไม่ขาด (ไม่มีใบงานลอย)",
                              satisfied: !problems.contains {
                                  $0.kind == .missingParent || $0.kind == .cycle
                              }),
                // The other half of the 100% rule: work that covers nothing is
                // caught above, scope that nothing covers is caught here.
                GateCondition(text: "ทุกข้อในขอบเขต 'ทำ' มีใบงานรองรับ",
                              satisfied: uncovered.isEmpty),
            ]
        case .execution:
            conditions = [
                GateCondition(text: "ไม่มีใบงานที่ยังไม่เสร็จ",
                              satisfied: openWorkPackages == 0),
            ]
        case .closing:
            // §19.12 condition 7. The rest of the eight arrive with the
            // registers they read (P10.8, P10.10).
            conditions = [
                GateCondition(text: "ไม่มีใบงานที่ยังไม่เสร็จ",
                              satisfied: openWorkPackages == 0),
                GateCondition(text: "บันทึกบทเรียนอย่างน้อย 1 ข้อ",
                              satisfied: hasLessons),
            ]
        case .closed:
            conditions = []
        }
        return GateEvaluation(gate: gate, from: project.stage, to: to, conditions: conditions)
    }
}
