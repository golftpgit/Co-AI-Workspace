import Testing
import Foundation
import AgentKit
import Execution
import CoreEngine
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// `run_shell` end to end: the tool itself, and — the point of P1.7 — the fact
// that reaching it means passing the gate first.
// ─────────────────────────────────────────────────────────────

private func scratch() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coai-shell-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct Approver: ApprovalRequesting {
    let decision: ApprovalDecision
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision { decision }
}

@Suite("run_shell")
struct RunShellToolTests {
    @Test("runs a real command and reports exit code and both streams")
    func runsRealCommand() async throws {
        let root = scratch()
        let tool = RunShellTool(registry: ProcessRegistry())
        let output = try await tool.call(
            argumentsJSON: #"{"command":"echo สวัสดี; echo พลาด >&2; exit 2"}"#,
            context: ToolContext(scope: .central, workingDirectory: root))

        #expect(output.text.contains("สวัสดี"))
        #expect(output.text.contains("[stderr]"))
        #expect(output.text.contains("พลาด"))
        #expect(output.text.contains("[exit 2"))
    }

    /// §13: a failing build's output goes back to the model raw. A summary
    /// loses the file, the line and the fix-it.
    @Test("compiler output comes back unsummarised")
    func returnsRawOutput() async throws {
        let root = scratch()
        let tool = RunShellTool(registry: ProcessRegistry())
        let output = try await tool.call(
            argumentsJSON: #"{"command":"printf 'a.swift:12:5: error: cannot find X in scope\n' >&2; exit 1"}"#,
            context: ToolContext(scope: .central, workingDirectory: root))
        #expect(output.text.contains("a.swift:12:5: error: cannot find X in scope"))
    }

    @Test("an empty or missing command is an argument error, not an empty run")
    func rejectsEmptyCommand() async {
        let tool = RunShellTool(registry: ProcessRegistry())
        let context = ToolContext(scope: .central, workingDirectory: scratch())
        await #expect(throws: ToolError.self) {
            _ = try await tool.call(argumentsJSON: #"{"command":"   "}"#, context: context)
        }
        await #expect(throws: ToolError.self) {
            _ = try await tool.call(argumentsJSON: "{}", context: context)
        }
    }

    @Test("a working directory that does not exist says so instead of running somewhere else")
    func rejectsMissingDirectory() async {
        let tool = RunShellTool(registry: ProcessRegistry())
        await #expect(throws: ToolError.self) {
            _ = try await tool.call(
                argumentsJSON: #"{"command":"pwd","working_directory":"/definitely/not/here"}"#,
                context: ToolContext(scope: .central))
        }
    }

    @Test("the declared risk is high and the schema requires a command")
    func contractIsDeclared() {
        let tool = RunShellTool(registry: ProcessRegistry())
        #expect(tool.riskLevel == .high)
        #expect(tool.name == "run_shell")
        #expect(tool.parametersJSON.contains("\"required\""))
    }
}

@Suite("run_shell through the gate")
struct GatedShellTests {
    /// The Done-when of P1.7 and P1.9 together: a real, destructive-looking
    /// command reaches the shell only after a human says yes.
    @Test("a denied approval means the command never executes")
    func deniedCommandNeverRuns() async throws {
        let root = scratch()
        let marker = root.appending(path: "ran.txt")
        let gateway = ToolGateway(approver: Approver(decision: .rejected(reason: "ไม่")),
                                  modes: OperatingModes(autonomy: .balanced))
        await gateway.register(RunShellTool(registry: ProcessRegistry()))

        let outcome = try await gateway.call(
            "run_shell",
            argumentsJSON: #"{"command":"echo ran > ran.txt"}"#,
            context: ToolContext(scope: .central, workingDirectory: root))

        #expect(!outcome.didExecute)
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)),
                "the command ran despite being denied")
    }

    @Test("an approved command executes and its output reaches the transcript")
    func approvedCommandRuns() async throws {
        let root = scratch()
        let gateway = ToolGateway(approver: Approver(decision: .approved),
                                  modes: OperatingModes(autonomy: .balanced))
        await gateway.register(RunShellTool(registry: ProcessRegistry()))

        let outcome = try await gateway.call(
            "run_shell",
            argumentsJSON: #"{"command":"echo ผ่านประตูแล้ว"}"#,
            context: ToolContext(scope: .central, workingDirectory: root))

        #expect(outcome.didExecute)
        #expect(outcome.transcriptText.contains("ผ่านประตูแล้ว"))
    }

    /// A shell command is High no matter what, so full-autonomous is the only
    /// mode in which it runs unattended — and the scorer, not the tool, decides.
    @Test("balanced autonomy asks about run_shell every time")
    func shellAlwaysAsksUnlessFullyAutonomous() async throws {
        let root = scratch()
        let gateway = ToolGateway(approver: nil, modes: OperatingModes(autonomy: .balanced))
        await gateway.register(RunShellTool(registry: ProcessRegistry()))

        let outcome = try await gateway.call("run_shell", argumentsJSON: #"{"command":"echo hi"}"#,
                                             context: ToolContext(scope: .central, workingDirectory: root))
        guard case .denied = outcome else { Issue.record("expected a denial, got \(outcome)"); return }
    }
}
