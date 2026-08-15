import Foundation
import AgentKit
import Knowledge
import Observability

// ─────────────────────────────────────────────────────────────
// The policy gate, actually installed (ARCHITECTURE §5.3, §11.2, P2.6 · risk
// R14, found during P11.10).
//
// **What was wrong.** P2.6 built `KnowledgePolicyGate` and proved it with
// eleven tests that fire through a real `ToolGateway`. The app then built
// `HookChain(stageGate:)` and took the default `NoPolicyGate`. So every one of
// those tests was true and, in the shipping app, **no rule in the `policy`
// scope had ever stopped anything** — D6 for the seventh time, and the first
// time on a safety gate rather than a feature.
//
// `KnowledgePolicyGate` takes a `PolicyLibrary` by value, which is why it never
// got wired: at the moment the chain is built, at boot, there is no library
// yet, and a policy document ingested five minutes later would not be in one
// anyway. This type is the missing half — a gate that reads the scope when it
// is asked, and forgets what it read when the scope changes.
//
// Three choices worth stating:
//
// 1. **Cached, with explicit invalidation, not read-per-call.** A DB round trip
//    inside every tool call is a cost paid on the hot path forever to catch a
//    change that happens rarely. Ingest tells it to forget instead.
// 2. **A read that fails is not an empty policy set.** If the store cannot be
//    reached, the gate says so and the chain treats it as a hard stop rather
//    than as "no rules apply" — an unavailable rulebook must not read as
//    permission. This is the same shape as "no channel to ask is a refusal,
//    not an approval" (P1.8).
// 3. **The narrow matching from P2.6 is kept exactly.** Every content term of
//    a rule has to appear in the action. A gate that fires loosely gets worked
//    around, and then it protects nothing.
// ─────────────────────────────────────────────────────────────

/// Holds the parsed rulebook and drops it when the scope changes.
public actor PolicyLibrarySource {
    private let reader: any PolicyChunkReading
    private let parser = PolicyDocumentParser()
    private var cached: PolicyLibrary?
    private let log = AppLog.logger("policy")

    public init(reader: any PolicyChunkReading) {
        self.reader = reader
    }

    /// The rulebook, parsed once until something invalidates it.
    /// Throws when the scope cannot be read — the caller must not turn that
    /// into an empty library.
    public func library() async throws -> PolicyLibrary {
        if let cached { return cached }
        let chunks = try await reader.policyChunks()
        // One chunk can hold more than one rule; the parser splits on lines and
        // keeps each rule's own provenance, which is what the human is shown.
        let rules = chunks.flatMap { chunk in
            parser.rules(in: chunk.text, provenance: chunk.provenance)
        }
        let library = PolicyLibrary(rules: rules)
        cached = library
        log.info("policy library loaded — \(rules.count, privacy: .public) rules")
        return library
    }

    /// Called after anything writes to the `policy` scope.
    public func invalidate() {
        cached = nil
    }

    /// How many rules are in force, for the status screen. `nil` when the scope
    /// could not be read — which is a different thing from zero and has to look
    /// different on screen.
    public func ruleCount() async -> Int? {
        try? await library().count
    }
}

/// The gate the app installs.
public struct StoredPolicyGate: PolicyGate {
    private let source: PolicyLibrarySource
    private let log = AppLog.logger("policy")

    public init(source: PolicyLibrarySource) {
        self.source = source
    }

    public func conflict(with call: PendingToolCall, risk: RiskAssessment) async -> String? {
        let library: PolicyLibrary
        do {
            library = try await source.library()
        } catch {
            // Choice 2. Saying nothing here would let a database hiccup do what
            // no autonomy setting is allowed to do.
            log.error("policy scope unreadable — refusing the call")
            return """
                อ่านนโยบายใน `policy` scope ไม่ได้ (\(error)) — ยังไม่อนุญาตให้ทำงานนี้
                นโยบายที่อ่านไม่ได้ ไม่เท่ากับไม่มีนโยบาย
                """
        }

        let action = PolicyAction(toolName: call.toolName,
                                  detail: "\(call.toolDescription) \(call.argumentsJSON)")
        guard let rule = library.hardConstraint(broken: action) else { return nil }
        // Verbatim, with where it came from — P2.6's promise, unchanged.
        return "\(rule.text)\n— \(rule.provenance.title)"
    }
}
