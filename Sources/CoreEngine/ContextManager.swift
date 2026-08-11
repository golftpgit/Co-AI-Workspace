import Foundation
import AgentKit
import LLMProviders
import Observability

// ─────────────────────────────────────────────────────────────
// Keeping a long session inside its window (ARCHITECTURE §5.6, P4.9).
//
// Compaction happens at ~75% rather than when the window is full, because a
// handoff written with no room left is written badly or not at all.
//
// What gets dropped is ordered by what is cheapest to lose:
//
//   1. raw tool output, oldest first — the biggest thing in any transcript and
//      the least re-readable; what mattered about it is in the handoff;
//   2. older conversation turns, folded into the handoff;
//   3. never the durable rules, which is why they are held apart from the
//      transcript rather than being the first messages in it. Instructions
//      given at the start of a session are the thing a user is most surprised
//      to lose, and in v1 they were lost first.
//
// §5.6's handoff has six fields. Three of them — key_decisions, open_issues,
// file_pointers — are the debt v1 left behind (App. D, D-5): nobody had a way
// to fill them that produced anything but empty lists.
//
// They are filled here from the transcript rather than by asking a model, and
// that is the whole idea. A model asked "what were the key decisions" writes
// something plausible; an approval that was granted, a command that exited
// non-zero and a path that was actually opened are facts already sitting in
// the messages. The model is used for the two narrative fields, where being
// approximately right is the job — and if it is unavailable the handoff still
// has its evidence.
// ─────────────────────────────────────────────────────────────

public struct Handoff: Sendable, Equatable, Codable {
    public var goal: String
    public var completedSteps: [String]
    public var remainingSteps: [String]
    public var keyDecisions: [String]
    public var openIssues: [String]
    /// Paths, never contents (§5.6). A handoff that inlines a file grows the
    /// thing it exists to shrink.
    public var filePointers: [String]

    public init(goal: String = "",
                completedSteps: [String] = [], remainingSteps: [String] = [],
                keyDecisions: [String] = [], openIssues: [String] = [],
                filePointers: [String] = []) {
        self.goal = goal
        self.completedSteps = completedSteps
        self.remainingSteps = remainingSteps
        self.keyDecisions = keyDecisions
        self.openIssues = openIssues
        self.filePointers = filePointers
    }

    public var isEmpty: Bool {
        completedSteps.isEmpty && remainingSteps.isEmpty && keyDecisions.isEmpty
            && openIssues.isEmpty && filePointers.isEmpty
    }

    /// How the handoff re-enters the conversation: one system message, in the
    /// words the next turn will read.
    public var summary: String {
        var lines = ["[สรุปบทสนทนาก่อนหน้า — ย่อเพื่อให้พอดีกับหน้าต่างบริบท]"]
        if !goal.isEmpty { lines.append("เป้าหมาย: \(goal)") }
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append(title)
            lines.append(contentsOf: items.map { "- \($0)" })
        }
        section("ทำไปแล้ว:", completedSteps)
        section("ยังเหลือ:", remainingSteps)
        section("สิ่งที่ตัดสินไปแล้ว (อย่าตัดสินซ้ำ):", keyDecisions)
        section("ปัญหาที่ยังค้าง:", openIssues)
        section("ไฟล์ที่เกี่ยวข้อง:", filePointers)
        return lines.joined(separator: "\n")
    }
}

public struct ContextManager: Sendable {
    /// The window the transcript has to fit inside, in tokens.
    public let budget: Int
    /// §5.6's 70–80%. Compacting at the ceiling leaves no room to write the
    /// handoff, which is the one thing that must not be truncated.
    public let compactAt: Double
    /// Recent turns are kept verbatim: the last few exchanges are what the
    /// next reply is actually answering.
    public let keepRecent: Int
    private let log = AppLog.logger("context")

    public init(budget: Int, compactAt: Double = 0.75, keepRecent: Int = 6) {
        self.budget = budget
        self.compactAt = compactAt
        self.keepRecent = keepRecent
    }

    public var threshold: Int { Int(Double(budget) * compactAt) }

    public func tokens(_ messages: [LLMMessage]) -> Int {
        var request = LLMRequest(messages: messages)
        request.maxTokens = 0
        return request.estimatedPromptTokens
    }

    public func shouldCompact(_ messages: [LLMMessage]) -> Bool {
        tokens(messages) >= threshold
    }

    /// The result of compacting: what to send now, and what was learned on the
    /// way out. The handoff is returned as well as embedded so a caller can
    /// store it — §5.6 wants it durable, not only in the next prompt.
    public struct Compaction: Sendable {
        public let messages: [LLMMessage]
        public let handoff: Handoff
        public let tokensBefore: Int
        public let tokensAfter: Int
    }

    /// Compacts, reading everything it can out of the transcript itself.
    ///
    /// `narrate` is the optional model step (Tier 0 is enough — it runs on
    /// every compaction, so it has to be cheap). It fills the two narrative
    /// fields; everything else is evidence and is filled whether or not a model
    /// is reachable.
    public func compact(_ messages: [LLMMessage],
                        goal: String,
                        durableRules: [String] = [],
                        narrate: ((String) async -> (completed: [String], remaining: [String]))? = nil)
        async -> Compaction {
        let before = tokens(messages)

        var handoff = evidence(in: messages)
        handoff.goal = goal

        if let narrate {
            let (completed, remaining) = await narrate(transcriptDigest(messages))
            handoff.completedSteps = completed
            handoff.remainingSteps = remaining
        }

        var kept: [LLMMessage] = durableRules.map { LLMMessage(.system, $0) }
        kept.append(LLMMessage(.system, handoff.summary))
        kept.append(contentsOf: tail(of: messages))

        let after = tokens(kept)
        log.info("compacted \(before, privacy: .public) → \(after, privacy: .public) tokens")
        return Compaction(messages: kept, handoff: handoff,
                          tokensBefore: before, tokensAfter: after)
    }

    // MARK: - what the transcript already knows

    /// The three fields v1 never managed to fill, read off the messages.
    func evidence(in messages: [LLMMessage]) -> Handoff {
        var decisions: [String] = []
        var issues: [String] = []
        var paths: [String] = []

        for message in messages {
            switch message.role {
            case .tool:
                // A tool result that reports a failure is an open issue by
                // definition — nobody has to judge whether it counts.
                if let problem = Self.failure(in: message.content) {
                    issues.appendUnique(problem)
                }
                paths.appendUnique(contentsOf: Self.paths(in: message.content))
            case .user:
                // Approvals and refusals are the decisions that most need to
                // survive: re-asking is how a user ends up answering twice.
                if let decision = Self.decision(in: message.content) {
                    decisions.appendUnique(decision)
                }
                paths.appendUnique(contentsOf: Self.paths(in: message.content))
            case .assistant:
                for call in message.toolCalls {
                    paths.appendUnique(contentsOf: Self.paths(in: call.argumentsJSON))
                }
            case .system:
                break
            }
        }

        return Handoff(keyDecisions: decisions, openIssues: issues, filePointers: paths)
    }

    /// Words that mean a step did not work, in either language the transcript
    /// might use them in. Deliberately narrow: a heuristic that flags
    /// everything produces a handoff nobody reads.
    private static let failureMarkers = [
        "exit code 1", "exit code 2", "exit status", "command not found",
        "error:", "failed", "ล้มเหลว", "ไม่สำเร็จ", "ผิดพลาด", "ไม่พบ",
        "traceback", "exception", "permission denied", "ถูกปฏิเสธ",
    ]

    private static func failure(in text: String) -> String? {
        let lowered = text.lowercased()
        guard failureMarkers.contains(where: { lowered.contains($0.lowercased()) }) else {
            return nil
        }
        // The first line that carries the marker, not the whole output: the
        // point is to remember that it failed and roughly why.
        let line = text.split(separator: "\n").first { candidate in
            let lowered = candidate.lowercased()
            return failureMarkers.contains { lowered.contains($0.lowercased()) }
        }
        return (line.map(String.init) ?? text).trimmed(to: 200)
    }

    private static let decisionMarkers = [
        "อนุมัติ", "ไม่อนุมัติ", "ปฏิเสธ", "ยืนยัน", "ตกลง", "ให้ใช้", "ห้าม",
        "approve", "approved", "denied", "reject", "confirm",
    ]

    private static func decision(in text: String) -> String? {
        let lowered = text.lowercased()
        guard decisionMarkers.contains(where: { lowered.contains($0.lowercased()) }) else {
            return nil
        }
        return text.trimmed(to: 200)
    }

    /// Absolute paths and file-looking names. Pointers only — §5.6 is explicit
    /// that contents stay out.
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"(/[\w.\-/]+\.[A-Za-z0-9]{1,8})|([\w.\-]+\.(swift|md|json|txt|pdf|csv|py|sh|plist))"#)

    static func paths(in text: String) -> [String] {
        guard let pathPattern else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pathPattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    /// What the model is asked to narrate. Trimmed hard — this runs on every
    /// compaction, so it must not itself be an expensive call.
    private func transcriptDigest(_ messages: [LLMMessage]) -> String {
        messages.suffix(40).map { message in
            let who = message.role.rawValue
            let body = message.role == .tool
                ? "[ผลลัพธ์เครื่องมือ \(message.content.count) ตัวอักษร]"
                : message.content.trimmed(to: 300)
            return "\(who): \(body)"
        }.joined(separator: "\n")
    }

    /// The recent turns kept verbatim, without orphaning a tool result from the
    /// assistant turn that asked for it — the endpoint rejects a `tool` message
    /// whose `tool_calls` are missing (ARCHITECTURE E.9).
    private func tail(of messages: [LLMMessage]) -> [LLMMessage] {
        var start = max(0, messages.count - keepRecent)
        while start > 0, messages[start].role == .tool { start -= 1 }
        return Array(messages[start...]).filter { $0.role != .system }
    }
}

private extension String {
    func trimmed(to limit: Int) -> String {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= limit ? clean : String(clean.prefix(limit)) + "…"
    }
}

private extension Array where Element == String {
    mutating func appendUnique(_ value: String) {
        guard !value.isEmpty, !contains(value) else { return }
        append(value)
    }

    mutating func appendUnique(contentsOf values: [String]) {
        for value in values { appendUnique(value) }
    }
}
