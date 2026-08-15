import Testing
import Foundation
import AgentKit
import Knowledge
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// Risk R14 — the policy gate the app actually installs.
//
// `PolicyGateTests` already proves the rule matching. These are about the half
// that was missing for seven phases: reading the scope at call time, noticing
// when it changes, and refusing rather than allowing when it cannot be read.
// ─────────────────────────────────────────────────────────────

private func chunk(_ text: String, title: String = "นโยบายข้อมูลผู้ป่วย") -> IndexedChunk {
    IndexedChunk(id: "c_\(UUID().uuidString)", text: text, scope: .policy,
                 provenance: Provenance(documentID: "doc_policy", title: title,
                                        origin: .upload(filename: "policy.md"), tier: .t1),
                 embedding: nil, embeddingProfileID: nil, contentHash: UUID().uuidString)
}

private actor FakeReader: PolicyChunkReading {
    private var chunks: [IndexedChunk]
    private var failing: Bool
    private(set) var reads = 0

    init(_ chunks: [IndexedChunk], failing: Bool = false) {
        self.chunks = chunks
        self.failing = failing
    }

    struct Unreachable: Error {}

    func policyChunks() async throws -> [IndexedChunk] {
        reads += 1
        if failing { throw Unreachable() }
        return chunks
    }

    func replace(with chunks: [IndexedChunk]) { self.chunks = chunks }
}

private func pendingCall(_ tool: String, arguments: String) -> PendingToolCall {
    PendingToolCall(toolName: tool, toolDescription: "รันคำสั่งเชลล์",
                    declaredRisk: .high, parametersJSON: "{}",
                    argumentsJSON: arguments, context: ToolContext(scope: .central))
}

private let risk = RiskAssessment(level: .high, reasons: [])

@Suite("Stored policy gate — R14")
struct StoredPolicyGateTests {

    @Test("a hard constraint in the policy scope stops the call, quoting the rule")
    func stopsOnHardConstraint() async {
        let reader = FakeReader([chunk("- ห้ามลบฐานข้อมูลผลการทดลอง")])
        let gate = StoredPolicyGate(source: PolicyLibrarySource(reader: reader))

        let conflict = await gate.conflict(
            with: pendingCall("run_shell", arguments: #"{"command":"ลบฐานข้อมูลผลการทดลอง ทั้งหมด"}"#),
            risk: risk)

        #expect(conflict?.contains("ห้ามลบฐานข้อมูลผลการทดลอง") == true)
        // Where it came from, so a person can judge whether it really applies.
        #expect(conflict?.contains("นโยบายข้อมูลผู้ป่วย") == true)
    }

    @Test("an action no rule covers is not stopped")
    func passesUnrelatedWork() async {
        let reader = FakeReader([chunk("- ห้ามลบฐานข้อมูลผลการทดลอง")])
        let gate = StoredPolicyGate(source: PolicyLibrarySource(reader: reader))

        let conflict = await gate.conflict(
            with: pendingCall("run_shell", arguments: #"{"command":"swift build"}"#), risk: risk)
        #expect(conflict == nil)
    }

    // Choice 2 in the header, and the reason this is not just a convenience:
    // a database hiccup must not be able to do what no autonomy setting can.
    @Test("a policy scope that cannot be read refuses the call instead of allowing it")
    func unreadableScopeRefuses() async {
        let reader = FakeReader([], failing: true)
        let gate = StoredPolicyGate(source: PolicyLibrarySource(reader: reader))

        let conflict = await gate.conflict(
            with: pendingCall("run_shell", arguments: #"{"command":"swift build"}"#), risk: risk)

        #expect(conflict != nil, "an unreadable rulebook read as permission")
        #expect(conflict?.contains("ไม่เท่ากับไม่มีนโยบาย") == true)
    }

    // The reason `KnowledgePolicyGate` could not be wired: a library captured at
    // boot cannot know about a policy ingested afterwards.
    @Test("a rule ingested after boot takes effect once the source is invalidated")
    func picksUpNewRules() async {
        let reader = FakeReader([])
        let source = PolicyLibrarySource(reader: reader)
        let gate = StoredPolicyGate(source: source)
        let call = pendingCall("run_shell", arguments: #"{"command":"ลบฐานข้อมูลผลการทดลอง"}"#)

        #expect(await gate.conflict(with: call, risk: risk) == nil, "no rules yet")

        await reader.replace(with: [chunk("- ห้ามลบฐานข้อมูลผลการทดลอง")])
        await source.invalidate()

        #expect(await gate.conflict(with: call, risk: risk) != nil,
                "the newly ingested rule never took effect")
    }

    @Test("the scope is read once and cached until something invalidates it")
    func cachesBetweenCalls() async {
        let reader = FakeReader([chunk("- ห้ามลบฐานข้อมูลผลการทดลอง")])
        let source = PolicyLibrarySource(reader: reader)
        let gate = StoredPolicyGate(source: source)
        let call = pendingCall("run_shell", arguments: #"{"command":"swift build"}"#)

        for _ in 0..<5 { _ = await gate.conflict(with: call, risk: risk) }
        #expect(await reader.reads == 1, "the policy scope was read on every tool call")

        await source.invalidate()
        _ = await gate.conflict(with: call, risk: risk)
        #expect(await reader.reads == 2)
    }

    // "Zero rules" and "could not read the rules" must not look the same on the
    // status screen, for the same reason they do not look the same to the gate.
    @Test("the rule count is nil when the scope is unreadable, not zero")
    func countDistinguishesUnreadableFromEmpty() async {
        let empty = PolicyLibrarySource(reader: FakeReader([]))
        #expect(await empty.ruleCount() == 0)

        let broken = PolicyLibrarySource(reader: FakeReader([], failing: true))
        #expect(await broken.ruleCount() == nil)
    }
}

@Suite("Stored policy gate — through the real gateway")
struct StoredPolicyGateThroughGatewayTests {

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private struct ShellTool: AgentTool {
        let name = "run_shell"
        let toolDescription = "รันคำสั่งเชลล์"
        let riskLevel: RiskLevel = .high
        let parametersJSON = #"{"type":"object","properties":{"command":{"type":"string"}}}"#
        let ran: Counter

        func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
            await ran.increment()
            return ToolOutput(text: "ran")
        }
    }

    // The claim that matters is "the tool did not run", not "a function
    // returned a refusal" — P1.7's rule, and the only version of this test that
    // would have caught R14 if it had existed at the gateway level.
    @Test("full autonomy cannot wave through a hard constraint from the stored scope")
    func fullAutonomyStillStops() async throws {
        let ran = Counter()
        let reader = FakeReader([chunk("- ห้ามลบฐานข้อมูลผลการทดลอง")])
        let gateway = ToolGateway(
            chain: HookChain(policyGate: StoredPolicyGate(source: PolicyLibrarySource(reader: reader))),
            modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register(ShellTool(ran: ran))

        let outcome = try await gateway.call(
            "run_shell",
            argumentsJSON: #"{"command":"ลบฐานข้อมูลผลการทดลอง ทั้งหมด"}"#,
            context: ToolContext(scope: .central))

        #expect(await ran.value == 0, "the tool ran despite a hard constraint")
        guard case .blockedByPolicy = outcome else {
            Issue.record("expected a policy block, got \(outcome)")
            return
        }
    }
}
