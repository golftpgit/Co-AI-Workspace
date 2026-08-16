import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// A team as one specialist of the team above it
// (ARCHITECTURE §22.2, §22.4 · P16.1/P16.3/P16.7).
//
// The whole of §22 turns on one line: `Team: Specialist`. A sub-team is not a
// new kind of thing, not a mode and not a flag — it is a specialist, seen from
// its parent. Three properties then follow with nothing else written:
//
//  • **Isolation is the compiler's** (§2.3). A `Specialist` is an actor that
//    returns a `Deliverable`. There is no member on it that yields a
//    transcript or a ledger, so the Coding team cannot read the Medical
//    Research team's context — not by discipline, by there being no way to ask.
//  • **The hand-off protocol is already written**: `Assignment` down,
//    `Deliverable` up, through the same `QAReviewer` at every level. The
//    sub-lead reviews before sending up and the parent reviews again — two
//    reviews of one evidence set, not two opinions.
//  • **What §2.4 forbids stays forbidden.** Becoming a team is not a way for an
//    Engineer to fan out; the rule is checked on every `TeamPlan` at every
//    depth.
//
// **Authority only ever shrinks** (§22.4). A team cannot grant a sub-team a
// tool it does not itself hold. Without that rule, "make a sub-team that needs
// `run_shell`" is the cheapest way around the policy gate, and it is the same
// shape as privilege escalation by spawning a child process.
// ─────────────────────────────────────────────────────────────

/// What a team is for. The team-level twin of `Assignment`, and it refuses to
/// exist without acceptance criteria for the same reason `Assignment` has
/// since P1.1: work whose definition of done was never written is work nobody
/// can review, and at team level it is a whole branch of the organisation
/// producing unreviewable output.
public struct TeamCharter: Sendable, Equatable {
    public let mission: String
    /// What this team is the team *for* — research, coding, analysis. §22.1's
    /// deliberate departure from ICS: knowledge work separates by domain, not
    /// by administrative function.
    public let domain: String
    public let acceptanceCriteria: [Criterion]
    /// The ceiling on what this team may do, whatever its members can do
    /// individually (§22.4). Empty means "whatever the parent allows", which is
    /// the only honest default — a charter cannot widen anything.
    public let toolCeiling: Set<String>

    /// `nil` when the mission is blank or there are no acceptance criteria.
    /// A failable initialiser rather than a validating method: an unreviewable
    /// charter must not be constructible, so no code path can be written that
    /// forgets to call the check.
    public init?(mission: String, domain: String,
                 acceptanceCriteria: [Criterion],
                 toolCeiling: Set<String> = []) {
        let mission = mission.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mission.isEmpty, !acceptanceCriteria.isEmpty else { return nil }
        self.mission = mission
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.acceptanceCriteria = acceptanceCriteria
        self.toolCeiling = toolCeiling
    }
}

/// How deep the organisation may go, and what it costs to go deeper.
public enum CommandDepth {
    /// Three, and the number is not a taste (§22.2): every level multiplies the
    /// number of agents, and R6 measured multi-agent work at roughly 15× the
    /// tokens. Unbounded nesting is a fork bomb that arrives with an invoice.
    public static let maximum = 3

    /// Whether a team at this depth may create another level beneath it.
    public static func mayNest(at depth: Int) -> Bool { depth < maximum }
}

/// Why a sub-team was not created. Each case is something a person can act on,
/// because §22.3's rule is that the system says why rather than quietly doing
/// the work the slow way — or, worse, splitting and running out of budget
/// halfway.
public enum NestingRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    case tooDeep(depth: Int)
    case wouldExceedAuthority(tools: [String])
    case tooTangled(reason: String)
    case notEnoughBudget(needMoreUSD: Double)
    case fanOutForbidden(role: Role)

    public var description: String {
        switch self {
        case .tooDeep(let depth):
            "ลึกถึงชั้นที่ \(depth) แล้ว — ชั้นที่ \(CommandDepth.maximum + 1) ต้องให้คนอนุมัติ "
                + "เพราะทุกชั้นคูณจำนวน agent และโทเคน (R6 วัดไว้ ~15×)"
        case .wouldExceedAuthority(let tools):
            "ทีมย่อยขอสิทธิ์ที่ทีมแม่เองไม่มี: \(tools.sorted().joined(separator: ", ")) — "
                + "สิทธิ์ไหลลงอย่างเดียวและหดได้เท่านั้น (§22.4) ไม่งั้นการตั้งทีมใหม่จะกลายเป็น "
                + "วิธีหลบ policy gate ที่ถูกที่สุด"
        case .tooTangled(let reason):
            "ใบงานที่เกินมาผูกกันแน่นเกินกว่าจะแยกทีม: \(reason) — "
                + "แตกไปสองทีมจะแก้ขัดกันเอง ทำเป็นรอบ ๆ ดีกว่า"
        case .notEnoughBudget(let need):
            String(format: "งบที่เหลือไม่พอจะตั้งทีมย่อย — ต้องยกเพดานอีกราว $%.2f "
                   + "· แตกทีมเงียบ ๆ แล้วงบหมดกลางทางแย่กว่าทำช้า", need)
        case .fanOutForbidden(let role):
            "\(role.rawValue) ห้ามแตกงานออกไปหลายสาย (§2.4) และการตั้งทีมย่อยไม่ใช่ช่องหลบข้อนั้น"
        }
    }
}

/// Whether a sub-team may exist, and if not, why.
///
/// Its own type rather than `Result<Void, NestingRefusal>`: the refusal is the
/// interesting half of this decision and it gets read, logged and shown to a
/// person, so it deserves to be pattern-matched on directly rather than
/// unwrapped from a success that carries nothing.
public enum NestingDecision: Sendable, Equatable {
    case allowed
    case refused(NestingRefusal)

    public var isAllowed: Bool { self == .allowed }
    public var refusal: NestingRefusal? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// The three conditions §22.3 requires *together*, and the authority rule from
/// §22.4. Pure decisions, so the organisation's shape can be tested without
/// running a model.
public enum CommandRules {

    /// Span of control: 3–7 members, five being comfortable (§22.1). Over
    /// seven, the plan has to become sub-teams — the constraint is the lead's
    /// context window rather than a person's attention, but the behaviour that
    /// falls out is the same.
    public static let spanOfControl = 7

    /// Whether this plan needs splitting at all.
    ///
    /// `cap` exists so the lead asks *this* rule rather than comparing against
    /// a number of its own: it had `maxFanOut = 4` while this file published 7,
    /// so "how wide may a plan be" had two answers and the one that ran was
    /// whichever the caller happened to hit. Tests still narrow the cap
    /// deliberately, which is a different thing from a second opinion.
    public static func needsSplitting(assignments: Int, cap: Int = spanOfControl) -> Bool {
        assignments > cap
    }

    /// Whether a sub-team may be created, or why not.
    ///
    /// - Parameters:
    ///   - depth: how deep the parent already is; the child would be `depth + 1`.
    ///   - parentTools: what the parent may call. The child's request is
    ///     checked against this and never against the global tool list.
    ///   - childTools: what the sub-team is asking for.
    ///   - independent: whether the work that would move out can be done
    ///     without constant reference to the work that stays.
    ///   - budgetShortfallUSD: what the governor says is missing, if anything.
    ///   - leadRole: the role being asked to run the sub-team.
    public static func mayCreateSubTeam(depth: Int,
                                        parentTools: Set<String>,
                                        childTools: Set<String>,
                                        independent: Bool,
                                        tangledReason: String = "ใบงานอ้างถึงผลของกันและกัน",
                                        budgetShortfallUSD: Double = 0,
                                        leadRole: Role) -> NestingDecision {
        // §2.4 first: a rule that can be escaped by re-describing the work is
        // not a rule. An Engineer works in one context, and being called a team
        // does not change that.
        guard leadRole != .engineer else { return .refused(.fanOutForbidden(role: leadRole)) }
        guard CommandDepth.mayNest(at: depth) else { return .refused(.tooDeep(depth: depth)) }

        let excess = childTools.subtracting(parentTools)
        guard excess.isEmpty else {
            return .refused(.wouldExceedAuthority(tools: Array(excess)))
        }
        guard independent else { return .refused(.tooTangled(reason: tangledReason)) }
        guard budgetShortfallUSD <= 0 else {
            return .refused(.notEnoughBudget(needMoreUSD: budgetShortfallUSD))
        }
        return .allowed
    }

    /// What a team can actually do: what its members can do, capped by its
    /// charter, capped again by its parent (§22.4). Written as one expression
    /// because the order does not matter — every step can only remove.
    public static func capability(ofMembers members: [Set<String>],
                                  charter: TeamCharter,
                                  parentTools: Set<String>) -> Set<String> {
        let union = members.reduce(into: Set<String>()) { $0.formUnion($1) }
        let underCharter = charter.toolCeiling.isEmpty
            ? union
            : union.intersection(charter.toolCeiling)
        return underCharter.intersection(parentTools)
    }
}
