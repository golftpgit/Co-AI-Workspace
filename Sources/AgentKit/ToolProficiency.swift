import Foundation

// ─────────────────────────────────────────────────────────────
// How well a role actually uses a tool (ARCHITECTURE §21.1 layer 3, P12.8).
//
// The spans already hold the answer: every tool call is one, with a role, a
// status and a detail line. What they do not hold is the distinction that makes
// the number mean anything.
//
// **A blocked call is not a failure at the tool.** The gateway records a policy
// hard stop, a stage gate refusal, a human declining and plan-only mode all as
// spans that did not succeed. Counting those against the role would make a
// well-behaved agent look incompetent — and worse, would make the number go
// *up* when the guard rails were loosened, which is the opposite of what
// anybody reading it wants to learn. They are counted separately and shown
// separately, because "this role keeps trying things the rules forbid" is worth
// knowing and is a different fact.
//
// **A small denominator says nothing, so it does not get a percentage.** One
// call out of one is 100%, and a panel that prints 100% next to a single
// attempt teaches people either to trust it wrongly or to stop reading it. Below
// the floor the answer is "not enough to say yet", which is true and is what a
// forecast band already does elsewhere in this system.
//
// What *is* counted against the role: a call the tool refused before running
// because the arguments were wrong, a call the critic sent back, and a call
// that ran and failed. Those are the three ways a role can be bad at a tool.
// ─────────────────────────────────────────────────────────────

public struct ToolProficiency: Sendable, Equatable {
    /// Below this many attempts, no percentage is offered. Five is not a
    /// statistical threshold — it is the point below which the number would
    /// swing between 0% and 100% on a single call, and a figure that does that
    /// is one people learn to ignore.
    public static let leastMeaningfulSample = 5

    public let role: Role
    public let tool: String
    /// Calls that were this role's to get right.
    public let attempts: Int
    public let succeeded: Int
    /// Calls the rules stopped: policy, stage gate, a person declining,
    /// plan-only. Not counted against the role, and not hidden either.
    public let blockedByRules: Int

    public init(role: Role, tool: String, attempts: Int, succeeded: Int, blockedByRules: Int) {
        self.role = role
        self.tool = tool
        self.attempts = attempts
        self.succeeded = succeeded
        self.blockedByRules = blockedByRules
    }

    /// `nil` when there have not been enough attempts to mean anything.
    public var successRate: Double? {
        guard attempts >= Self.leastMeaningfulSample else { return nil }
        return Double(succeeded) / Double(attempts)
    }

    public var isTooFewToJudge: Bool { successRate == nil }

    /// The line the RACI panel shows. Says "not enough yet" rather than a
    /// number that would be read as a fact.
    /// Worded to read the same at one as at many.
    ///
    /// English inflects a noun after a count and Thai does not, so "over
    /// \(attempts) attempts" is correct in Thai and wrong at 1 in English. The
    /// honest fix for a plural is a `.stringsdict`; the honest fix for *this*
    /// sentence is not to put a count in front of a noun, which costs nothing
    /// and cannot be got wrong in a language nobody here speaks.
    public var summary: String {
        let rate = successRate.map { localised("\(Int(($0 * 100).rounded()))% succeeded (attempts: \(attempts))", "How well a role uses a tool. Placeholders: the success rate and the attempt count.") }
            ?? localised("used too little to say anything (attempts: \(attempts))", "Too few attempts to judge. Placeholder: the attempt count.")
        guard blockedByRules > 0 else { return rate }
        return rate + localised(" · a rule blocked \(blockedByRules) more, which is not counted against the role", "Attempts a rule stopped. Placeholder: how many.")
    }
}

public enum ToolProficiencyReader {

    /// One recorded tool call, as the span sink reads it out.
    public struct Attempt: Sendable, Equatable {
        public let role: Role
        public let tool: String
        public let succeeded: Bool
        /// The span's detail line, which is where the gateway wrote *why* a
        /// call did not succeed.
        public let detail: String?

        public init(role: Role, tool: String, succeeded: Bool, detail: String?) {
            self.role = role
            self.tool = tool
            self.succeeded = succeeded
            self.detail = detail
        }
    }

    /// Prefixes the gateway writes when the *rules* stopped a call, rather than
    /// the role getting it wrong. Matched on the prefix the gateway actually
    /// writes; a change there without a change here would quietly start
    /// counting refusals as incompetence.
    static let ruleRefusalPrefixes = ["policy hard stop", "stage gate", "denied", "plan-only"]

    public static func wasBlockedByRules(_ detail: String?) -> Bool {
        guard let detail else { return false }
        return ruleRefusalPrefixes.contains { detail.hasPrefix($0) }
    }

    public static func aggregate(_ attempts: [Attempt]) -> [ToolProficiency] {
        struct Key: Hashable { let role: Role; let tool: String }
        var tally: [Key: (attempts: Int, succeeded: Int, blocked: Int)] = [:]

        for attempt in attempts {
            let key = Key(role: attempt.role, tool: attempt.tool)
            var entry = tally[key] ?? (0, 0, 0)
            if !attempt.succeeded, wasBlockedByRules(attempt.detail) {
                entry.blocked += 1
            } else {
                entry.attempts += 1
                if attempt.succeeded { entry.succeeded += 1 }
            }
            tally[key] = entry
        }

        return tally.map { key, value in
            ToolProficiency(role: key.role, tool: key.tool,
                            attempts: value.attempts, succeeded: value.succeeded,
                            blockedByRules: value.blocked)
        }
        // Most-used first: a panel sorted by success rate puts the one-call
        // 100% at the top, which is the reading this type exists to prevent.
        .sorted { ($0.attempts + $0.blockedByRules, $0.tool) > ($1.attempts + $1.blockedByRules, $1.tool) }
    }
}
