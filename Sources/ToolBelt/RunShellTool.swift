import Foundation
import AgentKit
import Execution

// ─────────────────────────────────────────────────────────────
// `run_shell` (ARCHITECTURE §10) — the first real tool, and the one the whole
// gate exists for. It declares itself High, but that declaration is not what
// protects anything: the hook chain re-scores it independently (§5.3), so a
// custom manifest cannot register a "low risk" shell and walk past HITL.
//
// Output goes back raw. §13 is explicit that a summarised compiler error is
// worth less than the error, so the tool returns exactly what ran, its exit
// code, and both streams.
// ─────────────────────────────────────────────────────────────

public struct RunShellTool: AgentTool {
    public let name = "run_shell"
    public let toolDescription = """
    รันคำสั่ง shell ในเครื่อง (macOS, /bin/sh) แล้วคืน stdout/stderr และ exit code ดิบ \
    ใช้กับงาน build/test/lint/git หรือคำสั่งระบบอื่น ๆ — คำสั่งจะรันใน sandbox ที่เขียนไฟล์ได้เฉพาะในโฟลเดอร์โปรเจกต์
    """
    public let riskLevel: RiskLevel = .high
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "command": { "type": "string", "description": "คำสั่งที่จะรัน" },
        "working_directory": { "type": "string", "description": "โฟลเดอร์ที่ใช้รัน (ไม่ระบุ = โฟลเดอร์ของโปรเจกต์)" },
        "timeout_seconds": { "type": "integer", "description": "เวลาสูงสุด (ค่าเริ่มต้น 120)" }
      },
      "required": ["command"]
    }
    """

    private let registry: ProcessRegistry
    private let allowNetwork: Bool

    /// `allowNetwork` is off by default: a build should not be able to fetch
    /// anything the ingestion pipeline has not seen. `install_package` (P5)
    /// gets its own tool with network on, so the exception is explicit.
    public init(registry: ProcessRegistry, allowNetwork: Bool = false) {
        self.registry = registry
        self.allowNetwork = allowNetwork
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidArguments("run_shell ต้องมี 'command' ที่ไม่ว่าง")
        }

        let requested = (object["working_directory"] as? String).map { URL(fileURLWithPath: $0) }
        let workingDirectory = requested ?? context.workingDirectory
        guard let workingDirectory else {
            throw ToolError.invalidArguments("ไม่รู้ว่าจะรันในโฟลเดอร์ไหน — ระบุ working_directory หรือเปิดโปรเจกต์ก่อน")
        }
        // A path the user did not open is not ours to run in; the App Sandbox
        // would refuse anyway, and failing here says why.
        guard FileManager.default.fileExists(atPath: workingDirectory.path(percentEncoded: false)) else {
            throw ToolError.notPermitted("ไม่มีโฟลเดอร์ \(workingDirectory.path(percentEncoded: false))")
        }

        let seconds = (object["timeout_seconds"] as? Int) ?? 120
        let spec = ProcessSpec.shell(command,
                                     workingDirectory: workingDirectory,
                                     timeout: .seconds(max(1, min(seconds, 1800))),
                                     sandbox: .project(root: workingDirectory, allowNetwork: allowNetwork))

        let outcome: ProcessOutcome
        do {
            outcome = try await registry.run(spec,
                                             label: "run_shell",
                                             conversationID: context.conversationID)
        } catch let error as ExecutionError {
            throw ToolError.executionFailed(error.description)
        }

        return ToolOutput(text: Self.transcript(command: command, outcome: outcome))
    }

    /// Both streams, labelled, plus the exit code — the shape a model can act
    /// on without having to guess whether an empty stdout meant success.
    static func transcript(command: String, outcome: ProcessOutcome) -> String {
        var parts = ["$ \(command)"]
        if !outcome.stdout.isEmpty { parts.append(outcome.stdout.trimmingCharacters(in: .newlines)) }
        if !outcome.stderr.isEmpty {
            parts.append("[stderr]\n" + outcome.stderr.trimmingCharacters(in: .newlines))
        }
        if outcome.outputTruncated { parts.append("[output ถูกตัดเพราะยาวเกินขีดจำกัด]") }
        if !outcome.sandboxApplied {
            parts.append("[หมายเหตุ: seatbelt profile ใช้ไม่ได้ในบริบทนี้ — คำสั่งรันใต้ sandbox ของแอปแทน]")
        }
        parts.append("[exit \(outcome.exitCode) · \(outcome.reason.label) · \(String(format: "%.1fs", outcome.duration))]")
        return parts.joined(separator: "\n")
    }
}
