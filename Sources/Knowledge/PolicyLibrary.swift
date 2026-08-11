import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Rules the system must not break (ARCHITECTURE §11.2, §5.3, P2.6).
//
// Policy is knowledge, so it lives in the knowledge base — but in its own
// scope, chunked differently from everything else. Two reasons:
//
//  • a rule is atomic. Half a rule retrieved is worse than no rule, so policy
//    documents are split one rule per chunk regardless of the token budget
//    that governs ordinary prose;
//  • a hard constraint stops a tool call outright, and the human has to see
//    the rule *verbatim*. "This looks risky" is what the risk scorer says;
//    the policy gate says "this rule, in these words, forbids it."
//
// Matching is deliberately conservative. A gate that fires on fuzzy similarity
// blocks legitimate work and teaches people to ignore it, so a rule applies
// only when every one of its content terms is present in the action. Being
// too narrow is recoverable — the risk scorer and the human are still in the
// chain behind it.
// ─────────────────────────────────────────────────────────────

public struct PolicyRule: Sendable, Equatable {
    public let id: String
    /// The rule as written. Shown to the human unchanged (§11.2).
    public let text: String
    /// Hard constraints stop the call. Everything else is advisory and is
    /// surfaced without blocking.
    public let isHardConstraint: Bool
    /// The terms that have to appear in an action for this rule to apply.
    public let terms: [String]
    public let provenance: Provenance

    public init(id: String, text: String, isHardConstraint: Bool,
                terms: [String], provenance: Provenance) {
        self.id = id
        self.text = text
        self.isHardConstraint = isHardConstraint
        self.terms = terms
        self.provenance = provenance
    }
}

/// What the gate is asked about: a tool call flattened into the words that
/// describe it.
public struct PolicyAction: Sendable {
    public let toolName: String
    public let detail: String

    public init(toolName: String, detail: String) {
        self.toolName = toolName
        self.detail = detail
    }

    var searchable: String { "\(toolName) \(detail)" }
}

public struct PolicyLibrary: Sendable {
    private let rules: [PolicyRule]
    private let tokenizer: Tokenizer

    public init(rules: [PolicyRule], tokenizer: Tokenizer = Tokenizer()) {
        self.rules = rules
        self.tokenizer = tokenizer
    }

    public var count: Int { rules.count }

    /// Every rule that applies, hard constraints first so a caller that only
    /// looks at the first one still stops for the right reason.
    public func rules(matching action: PolicyAction) -> [PolicyRule] {
        let words = Set(tokenizer.tokens(action.searchable))
        return rules
            .filter { rule in
                !rule.terms.isEmpty && rule.terms.allSatisfy(words.contains)
            }
            .sorted { a, b in
                a.isHardConstraint == b.isHardConstraint
                    ? a.id < b.id
                    : a.isHardConstraint
            }
    }

    /// The first hard constraint an action breaks, if any.
    public func hardConstraint(broken action: PolicyAction) -> PolicyRule? {
        rules(matching: action).first { $0.isHardConstraint }
    }
}

// MARK: - reading a policy document

public struct PolicyDocumentParser: Sendable {
    /// Words that make a rule a prohibition rather than guidance. Kept short
    /// and explicit: the alternative is guessing at intent, and a gate that
    /// guesses wrong either blocks work or waves through what it should stop.
    static let prohibitionMarkers = [
        "ห้าม", "ต้องไม่", "อย่า",
        "must not", "may not", "never", "do not", "don't", "forbidden", "prohibited",
    ]
    /// Dropped when working out what a rule is *about*: they carry the
    /// prohibition, not the subject.
    private static let ignoredTerms: Set<String> = [
        "ห้าม", "ต้องไม่", "อย่า", "ต้อง", "ควร", "การ", "ใน", "ที่", "และ", "หรือ", "ของ",
        "must", "not", "may", "never", "do", "don't", "the", "a", "an", "on", "in",
        "to", "of", "and", "or", "is", "are", "be",
    ]

    private let tokenizer: Tokenizer

    public init(tokenizer: Tokenizer = Tokenizer()) {
        self.tokenizer = tokenizer
    }

    /// One rule per line or list item — the chunking that makes policy atomic
    /// (P2.6). Headings are dropped rather than parsed as rules: a heading has
    /// no obligation in it, and indexing one produces a rule whose terms match
    /// everything below it.
    public func rules(in document: String, provenance: Provenance) -> [PolicyRule] {
        document
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
            .map { line in
                line.trimmingPrefix(while: { "-*•>".contains($0) || $0.isNumber || $0 == "." })
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { $0.count > 3 }
            .enumerated()
            .map { index, text in
                let lowered = text.lowercased()
                let isHard = Self.prohibitionMarkers.contains { lowered.contains($0) }
                let terms = tokenizer.tokens(text)
                    .filter { !Self.ignoredTerms.contains($0) && $0.count > 1 }
                return PolicyRule(
                    id: "\(provenance.documentID)#rule\(index + 1)",
                    text: text,
                    isHardConstraint: isHard,
                    terms: Array(Set(terms)).sorted(),
                    provenance: provenance)
            }
    }
}

private extension String {
    func trimmingPrefix(while predicate: (Character) -> Bool) -> String {
        String(drop(while: predicate))
    }
}
