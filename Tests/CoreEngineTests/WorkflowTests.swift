import Testing
import Foundation
import AgentKit
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// Workflow Builder (§14.2, P8.6). Every test here is one of the two things v1
// got wrong with this feature: execution that skipped the gate (found in Phase
// F), and ids that collided after a load (bug B3).
//
// The runner is always exercised through a real `ToolGateway`, never by calling
// a tool directly — same reason P1.7 and P2.6 are written that way: the claim
// worth checking is "the tool did not run", not "a function returned a
// refusal".
// ─────────────────────────────────────────────────────────────

private actor Recorder {
    private(set) var calls: [String] = []
    func add(_ name: String) { calls.append(name) }
}

private struct RecordingTool: AgentTool {
    let name: String
    let toolDescription = "เครื่องมือสำหรับเทส"
    let riskLevel: RiskLevel
    let parametersJSON = #"{"type":"object","properties":{}}"#
    let recorder: Recorder
    var fails = false

    func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        await recorder.add(name)
        if fails { throw ToolError.invalidArguments("ตั้งใจให้ล้ม") }
        return ToolOutput(text: "\(name) เสร็จแล้ว")
    }
}

private func gateway(_ tools: [RecordingTool],
                     modes: OperatingModes = OperatingModes(autonomy: .fullAutonomous))
    async -> ToolGateway {
    let gateway = ToolGateway(chain: HookChain(), modes: modes)
    for tool in tools { await gateway.register(tool) }
    return gateway
}

private func tempFile() -> URL {
    URL.temporaryDirectory.appending(path: "wf-\(UUID().uuidString).json")
}

@Suite("Workflow — the gate is not optional")
struct WorkflowGateTests {

    // The Phase F hole, pinned: v1's workflow engine ran tools without the
    // chain. Here the runner holds a gateway and nothing else, so the only way
    // this could regress is somebody handing it a tool directly.
    @Test("every step runs through the gateway, in order")
    func stepsRunInOrder() async throws {
        let recorder = Recorder()
        let gate = await gateway([
            RecordingTool(name: "kb_search", riskLevel: .low, recorder: recorder),
            RecordingTool(name: "web_search", riskLevel: .low, recorder: recorder),
        ])
        let workflow = Workflow(name: "ค้นสองชั้น", steps: [
            WorkflowStep(tool: "kb_search"),
            WorkflowStep(tool: "web_search"),
        ])

        let run = await WorkflowRunner(gateway: gate)
            .run(workflow, context: ToolContext(scope: .central))

        #expect(await recorder.calls == ["kb_search", "web_search"])
        #expect(run.completed)
        #expect(run.outcomes.count == 2)
    }

    // "The workflow failed" is the message that made v1's runs unreadable.
    @Test("a run stops at the first failure and names the step that stopped it")
    func stopsAtFirstFailure() async throws {
        let recorder = Recorder()
        let gate = await gateway([
            RecordingTool(name: "kb_search", riskLevel: .low, recorder: recorder),
            RecordingTool(name: "run_shell", riskLevel: .low, recorder: recorder, fails: true),
            RecordingTool(name: "save_document", riskLevel: .low, recorder: recorder),
        ])
        let workflow = Workflow(name: "สามขั้น", steps: [
            WorkflowStep(tool: "kb_search"),
            WorkflowStep(tool: "run_shell"),
            WorkflowStep(tool: "save_document"),
        ])

        let run = await WorkflowRunner(gateway: gate)
            .run(workflow, context: ToolContext(scope: .central))

        // The third step must not have run: it was written on the assumption
        // that the second one worked.
        #expect(await recorder.calls == ["kb_search", "run_shell"])
        #expect(run.completed == false)
        #expect(run.stoppedAt?.tool == "run_shell")
        #expect(run.stoppedAt?.stop == .toolFailed)
    }

    // A person saying no is the gate working, not the tool breaking, and a
    // report that calls it "failed" tells them to go fix something that is not
    // wrong. §5.4.
    @Test("a step a human declines is recorded as declined, not as a failure")
    func declinedIsNotFailure() async throws {
        let recorder = Recorder()
        // No channel can answer, and "no way to ask" is a refusal (P1.8).
        let gate = await gateway([RecordingTool(name: "run_shell", riskLevel: .high,
                                                recorder: recorder)],
                                 modes: OperatingModes(autonomy: .approvalRequired))
        let workflow = Workflow(name: "ขั้นเสี่ยง",
                                steps: [WorkflowStep(tool: "run_shell")])

        let run = await WorkflowRunner(gateway: gate)
            .run(workflow, context: ToolContext(scope: .central))

        #expect(await recorder.calls.isEmpty, "the tool ran without an approval")
        #expect(run.completed == false)
        #expect(run.stoppedAt?.stop == .declined)
    }

    // Plan-only means nothing runs (§5.5). A workflow is exactly the surface
    // where somebody would expect the switch to be quietly ignored.
    @Test("plan-only stops the workflow instead of running it")
    func planOnlyStops() async throws {
        let recorder = Recorder()
        let gate = await gateway([RecordingTool(name: "kb_search", riskLevel: .low,
                                                recorder: recorder)],
                                 modes: OperatingModes(autonomy: .fullAutonomous,
                                                       planOnly: true))
        let run = await WorkflowRunner(gateway: gate)
            .run(Workflow(name: "อะไรก็ตาม", steps: [WorkflowStep(tool: "kb_search")]),
                 context: ToolContext(scope: .central))

        #expect(await recorder.calls.isEmpty)
        #expect(run.stoppedAt?.stop == .planOnly)
    }
}

@Suite("Workflow — refused before it is saved")
struct WorkflowValidationTests {

    // The P8.1/P8.5 rule: a sequence that dies halfway on a typo has already
    // done the first half. Catch it while it is still text on a screen.
    @Test("a step naming a tool that does not exist is refused, and says which")
    func unknownToolRefused() async throws {
        let gate = await gateway([RecordingTool(name: "kb_search", riskLevel: .low,
                                                recorder: Recorder())])
        let runner = WorkflowRunner(gateway: gate)
        let known = await runner.knownTools()

        let refusal = runner.refusal(for: Workflow(name: "พิมพ์ผิด", steps: [
            WorkflowStep(tool: "kb_search"),
            WorkflowStep(tool: "kb_serch"),
        ]), known: known)

        #expect(refusal?.contains("kb_serch") == true, "did not name the bad tool: \(refusal ?? "nil")")
        #expect(refusal?.contains("kb_search") == true, "did not list what does exist")
    }

    @Test("a nameless or empty workflow is refused, each with its own reason")
    func namelessAndEmptyRefused() async throws {
        let gate = await gateway([RecordingTool(name: "kb_search", riskLevel: .low,
                                                recorder: Recorder())])
        let runner = WorkflowRunner(gateway: gate)
        let known = await runner.knownTools()

        #expect(runner.refusal(for: Workflow(name: "  ", steps: [WorkflowStep(tool: "kb_search")]),
                               known: known) != nil)
        #expect(runner.refusal(for: Workflow(name: "ว่างเปล่า"), known: known)?
            .contains("ยังไม่มีขั้นตอน") == true)
    }

    // Tools arrive while the app runs — an MCP server, a plugin. A workflow
    // naming one must not be refused because the runner was built first.
    @Test("the tool list is read when asked, not captured when the runner is made")
    func toolListIsLive() async throws {
        let gate = ToolGateway(chain: HookChain(),
                               modes: OperatingModes(autonomy: .fullAutonomous))
        let runner = WorkflowRunner(gateway: gate)
        #expect(await runner.knownTools().isEmpty)

        await gate.register(RecordingTool(name: "mcp__later__thing", riskLevel: .low,
                                          recorder: Recorder()))

        let known = await runner.knownTools()
        #expect(known.contains("mcp__later__thing"))
        #expect(runner.refusal(for: Workflow(name: "มาทีหลัง",
                                             steps: [WorkflowStep(tool: "mcp__later__thing")]),
                               known: known) == nil)
    }
}

@Suite("Workflow — saved and loaded")
struct WorkflowStoreTests {

    // Bug B3: v1 numbered nodes, so two workflows loaded together collided.
    @Test("step ids are generated, never positional")
    func idsAreNotPositional() {
        let a = WorkflowStep(tool: "kb_search")
        let b = WorkflowStep(tool: "kb_search")
        #expect(a.id != b.id, "two identical steps share an id — this is bug B3")
        #expect(a.id.hasPrefix("wfs_"))
        // And the id survives a round trip, so reordering cannot renumber it.
        let workflow = Workflow(name: "สอง", steps: [a, b])
        let data = try! JSONEncoder().encode(workflow)
        let back = try! JSONDecoder().decode(Workflow.self, from: data)
        #expect(back.steps.map(\.id) == [a.id, b.id])
    }

    @Test("a saved workflow comes back with its steps in order")
    func roundTrips() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkflowStore(file: file)

        let workflow = Workflow(name: "รอบเก็บข้อมูลรายเดือน", steps: [
            WorkflowStep(tool: "kb_search", argumentsJSON: #"{"q":"ก"}"#, note: "หาเอกสารเดิม"),
            WorkflowStep(tool: "save_document", note: "ออกรายงาน"),
        ])
        try store.upsert(workflow)

        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "รอบเก็บข้อมูลรายเดือน")
        #expect(loaded[0].steps.map(\.tool) == ["kb_search", "save_document"])
        #expect(loaded[0].steps[0].note == "หาเอกสารเดิม")
    }

    @Test("saving the same workflow again replaces it rather than duplicating")
    func upsertReplaces() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkflowStore(file: file)

        var workflow = Workflow(name: "หนึ่ง", steps: [WorkflowStep(tool: "kb_search")])
        try store.upsert(workflow)
        workflow.name = "หนึ่ง (แก้แล้ว)"
        try store.upsert(workflow)

        #expect(store.load().count == 1)
        #expect(store.load()[0].name == "หนึ่ง (แก้แล้ว)")
    }

    // The P9.2 rule, in the newest list file: a file that will not decode is
    // copied aside *before* anything can save an empty list over it. The
    // failure that costs work is not the corrupt file, it is the overwrite.
    @Test("an unreadable file is kept aside instead of being overwritten")
    func keepsUnreadableFile() throws {
        let file = tempFile()
        defer {
            try? FileManager.default.removeItem(at: file)
            for url in (try? FileManager.default.contentsOfDirectory(
                at: file.deletingLastPathComponent(),
                includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try "นี่ไม่ใช่ JSON".write(to: file, atomically: true, encoding: .utf8)

        let store = WorkflowStore(file: file)
        #expect(store.load().isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let kept = siblings.filter {
            $0.lastPathComponent.hasPrefix(file.lastPathComponent) && $0 != file
        }
        #expect(!kept.isEmpty, "the unreadable file was not preserved")
    }
}
