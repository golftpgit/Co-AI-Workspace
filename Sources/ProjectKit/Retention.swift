import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// Retention (ARCHITECTURE §20.5, §19.12 condition 8, P11.10) — what happens to
// somebody's answers after the study ends.
//
// **What was wrong before this.** Condition 8 asked for a `DataDisposition`
// whose `policy` was any non-empty string. Typing "จะจัดการให้เรียบร้อย" passed
// it. So the gate that exists to make the promise made to participants
// survive the end of the project could be satisfied without there being a
// promise at all — box-ticking, which is the exact thing `isDecided` was
// written to prevent and did not.
//
// **What makes it enforced.** §20.5 puts the retention rule in the `policy`
// scope, which is a real place with real documents (§11.2). So the disposition
// now has to name a rule that is *in there*, and the gate answers in three
// ways — deliberately the same three as `ProjectTypeGate` (P11.1), because a
// second vocabulary for "we cannot check this yet" is how one of them rots:
//
//   • a rule exists and the disposition names it   → check it, block if false
//   • the project never collected data from people → the condition does not
//     apply, and says so rather than showing a tick that means nothing
//   • data was collected and no retention rule exists → **block**, because
//     that is a study that promised something to participants and wrote it
//     down nowhere
//
// **What it does not do: delete anything.** P10.10 settled that condition 8
// records the decision and the system does not remove files on somebody's
// behalf, and that stands — an app that quietly deletes a folder because a
// date passed is worse than one that reminds you. Closing records an
// *obligation* with the date it falls due, and that obligation is the thing a
// person can be shown later.
// ─────────────────────────────────────────────────────────────

/// A retention rule as found in the `policy` scope.
public struct RetentionRule: Sendable, Equatable {
    /// The rule as written, shown to the person unchanged (§11.2's habit).
    public let text: String
    /// How long the data may be kept, when the rule says. `nil` means the rule
    /// is about retention but never gives a period — which is worth knowing
    /// rather than defaulting to a number nobody wrote.
    public let months: Int?
    /// Which document it came from, so "says who" is answerable.
    public let source: String

    public init(text: String, months: Int?, source: String) {
        self.text = text
        self.months = months
        self.source = source
    }

    /// Whether `named` refers to this rule. Matching on the rule's own words
    /// rather than an id: the policy library is documents, not a registry, and
    /// asking a person to quote an id they cannot see is how a field ends up
    /// holding "1" forever.
    public func matches(_ named: String) -> Bool {
        let needle = named.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 4 else { return false }
        return text.lowercased().contains(needle) || needle.contains(text.lowercased())
    }
}

public enum RetentionPolicyReader {
    /// Rules that are about keeping or destroying data, out of everything in
    /// the policy scope.
    ///
    /// Matching is on the vocabulary the rule uses, not on a tag somebody had
    /// to remember to add — a policy document written by a research office
    /// will not carry our metadata.
    public static func rules(in policies: [PolicyRule]) -> [RetentionRule] {
        policies.compactMap { rule in
            let text = rule.text
            guard mentionsRetention(text) else { return nil }
            return RetentionRule(text: text,
                                 months: period(in: text),
                                 source: rule.provenance.title)
        }
    }

    private static let retentionTerms = [
        "เก็บรักษา", "เก็บข้อมูล", "ทำลาย", "ลบข้อมูล", "ระยะเวลาเก็บ",
        "retention", "retain", "destroy", "dispose", "anonymis", "anonymiz",
        "ทำให้ไม่ระบุตัวตน", "นิรนาม",
    ]

    static func mentionsRetention(_ text: String) -> Bool {
        let lower = text.lowercased()
        return retentionTerms.contains { lower.contains($0.lowercased()) }
    }

    /// The period a rule gives, in months. Reads years and months in both
    /// languages; returns `nil` rather than guessing when the rule gives none.
    static func period(in text: String) -> Int? {
        let lower = text.lowercased()
        let patterns: [(String, Int)] = [
            (#"(\d+)\s*(?:ปี|years?|yrs?)"#, 12),
            (#"(\d+)\s*(?:เดือน|months?|mos?)"#, 1),
        ]
        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(lower.startIndex..., in: lower)
            if let match = regex.firstMatch(in: lower, range: range),
               let numberRange = Range(match.range(at: 1), in: lower),
               let value = Int(lower[numberRange]) {
                return value * multiplier
            }
        }
        return nil
    }
}

/// What closing the project commits somebody to doing later.
///
/// Recorded, never executed — see the header. `dueOn` is `nil` when the rule
/// names no period, and that is reported rather than filled in.
public struct RetentionObligation: Sendable, Equatable, Codable {
    public let policy: String
    public let action: DataDisposition.Action
    public let decidedBy: String
    public let recordedAt: Date
    public let dueOn: Date?

    public init(policy: String, action: DataDisposition.Action, decidedBy: String,
                recordedAt: Date, dueOn: Date?) {
        self.policy = policy
        self.action = action
        self.decidedBy = decidedBy
        self.recordedAt = recordedAt
        self.dueOn = dueOn
    }

    /// The sentence to show. Says when, or says that the rule never said when —
    /// "ตามนโยบาย" with no date is the version nobody can act on.
    public var summary: String {
        let base = "\(action.label) ตามนโยบาย “\(policy)” · ตัดสินโดย \(decidedBy)"
        guard let dueOn else {
            return base + " · **นโยบายไม่ได้ระบุระยะเวลา** จึงไม่มีวันครบกำหนดให้เตือน"
        }
        return base + " · ครบกำหนด \(dueOn.formatted(date: .abbreviated, time: .omitted))"
    }
}

public enum RetentionCheck {
    /// The three-way answer for condition 8 (§19.12).
    public enum Result: Sendable, Equatable {
        /// Nothing was collected from people, so there is nothing to promise.
        case notApplicable
        /// Nobody asked the store whether data was collected. Shown as a grey
        /// dash and **does not block** — the `ProjectTypeGate` decision (P11.1):
        /// a gate that blocks every project because one reader is unwired is a
        /// bug wearing strictness as a costume. The enforcement lives in the
        /// wired case, and this one says out loud that it is not it.
        case unchecked(String)
        case satisfied(RetentionObligation)
        case blocked(String)

        public var passes: Bool {
            switch self {
            case .notApplicable, .unchecked, .satisfied: true
            case .blocked: false
            }
        }

        /// Whether the screen should draw this as "nothing to check" rather
        /// than as a tick (U21-2).
        public var isVacuous: Bool {
            switch self {
            case .notApplicable, .unchecked: true
            case .satisfied, .blocked: false
            }
        }
    }

    /// - Parameters:
    ///   - disposition: what the person said will happen.
    ///   - heldHumanData: whether this project ever collected answers from
    ///     people. `nil` means nobody asked the store — which blocks, because
    ///     "we could not check" must never read as "it is fine" (the rule
    ///     `ClosingFacts` already follows for its other optional facts).
    ///   - rules: retention rules found in the project's `policy` scope.
    public static func evaluate(disposition: DataDisposition?,
                                heldHumanData: Bool?,
                                rules: [RetentionRule],
                                now: Date = Date()) -> Result {
        guard let heldHumanData else {
            return .unchecked("นโยบายเก็บรักษาข้อมูล — ยังไม่ได้ตรวจว่าโปรเจกต์นี้เก็บข้อมูลจากคนไว้หรือไม่")
        }
        guard heldHumanData else { return .notApplicable }

        guard let disposition, disposition.isDecided else {
            return .blocked("โปรเจกต์นี้เก็บคำตอบจากคนไว้ — ต้องระบุว่าข้อมูลจะไปทางไหน "
                            + "และใครเป็นคนตัดสิน ก่อนปิดโครงการ (§20.5)")
        }
        guard !rules.isEmpty else {
            return .blocked("""
                โปรเจกต์นี้เก็บคำตอบจากคนไว้ แต่ **ไม่มีนโยบายเก็บรักษาข้อมูลใน `policy` scope เลย**
                — สิ่งที่สัญญากับผู้เข้าร่วมไว้ ต้องเขียนไว้ที่ไหนสักแห่งก่อนโครงการจะปิด (§20.5)
                """)
        }
        guard let matched = rules.first(where: { $0.matches(disposition.policy) }) else {
            return .blocked("""
                ไม่พบนโยบาย “\(disposition.policy)” ในนโยบายเก็บรักษาที่มีอยู่ — \
                ข้อความที่พิมพ์เองผ่านประตูนี้ได้ก่อนหน้านี้ ซึ่งทำให้เงื่อนไขนี้ไม่มีความหมาย
                นโยบายที่มีจริง: \(rules.map { "“\($0.text)”" }.joined(separator: " · "))
                """)
        }

        let due = matched.months.flatMap {
            Calendar.current.date(byAdding: .month, value: $0, to: now)
        }
        return .satisfied(RetentionObligation(policy: matched.text,
                                              action: disposition.action,
                                              decidedBy: disposition.decidedBy,
                                              recordedAt: now,
                                              dueOn: due))
    }
}

/// The two facts condition 8 needs that ProjectKit cannot reach itself: whether
/// anybody ever answered (M16's store) and what the `policy` scope says (M7's).
///
/// One protocol rather than two, for the reason `ClosingLedgerReading` gives:
/// a wiring that can answer one of these can answer the other, and splitting
/// them only makes it possible to connect half. Optional on `ProjectService` —
/// absent means `heldHumanData` is `nil`, which reads as `unchecked` and shows
/// a grey dash rather than blocking every project in the app.
public protocol RetentionFactsReading: Sendable {
    /// `nil` when the project's response store could not be read at all —
    /// which must not be confused with "nobody answered".
    func heldHumanData(scope: Scope) async -> Bool?
    func retentionRules(scope: Scope) async -> [RetentionRule]
}
