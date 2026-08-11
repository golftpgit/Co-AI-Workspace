import Foundation
import AgentKit
import Knowledge

// ─────────────────────────────────────────────────────────────
// The policy scope of the knowledge base, wired into the hook chain
// (ARCHITECTURE §5.3, §11.2, P2.6) — replacing the `NoPolicyGate` placeholder
// that P1 shipped.
//
// What comes back is the rule as written. The chain turns that into
// `.hardStop`, which no autonomy setting can override: unlike an approval,
// there is no button that continues past it.
// ─────────────────────────────────────────────────────────────

public struct KnowledgePolicyGate: PolicyGate {
    private let library: PolicyLibrary

    public init(library: PolicyLibrary) {
        self.library = library
    }

    public func conflict(with call: PendingToolCall, risk: RiskAssessment) async -> String? {
        let action = PolicyAction(toolName: call.toolName,
                                  detail: "\(call.toolDescription) \(call.argumentsJSON)")
        guard let rule = library.hardConstraint(broken: action) else { return nil }

        // Verbatim, with where it came from. A human deciding whether the rule
        // really applies needs the sentence and the document, not a paraphrase.
        let source = rule.provenance.title
        return "\(rule.text)\n— \(source)"
    }
}
