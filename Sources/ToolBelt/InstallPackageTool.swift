import Foundation
import AgentKit
import Execution
import Observability

// ─────────────────────────────────────────────────────────────
// `install_package` (ARCHITECTURE §10, P8.4) — the one tool that fetches
// somebody else's code and runs it.
//
// The rules it enforces are in `PackageInstall.swift`, where they can be tested
// without a network. What is here is the part that needs a machine: finding a
// real interpreter (the `xcrun` shim problem P9.6 measured), opening the
// network for exactly this call and nothing else, and writing down what came
// back.
//
// **Network is on for this tool and off for every other one.** `RunShellTool`
// defaults to `allowNetwork: false` precisely so that this is the explicit
// exception rather than a setting somebody widened once to make a build work.
// The sandbox still confines writes to the target directory, so a package's
// install script can reach the registry and cannot reach the rest of the disk.
//
// **The gate is not asked to trust the declaration.** `riskLevel` says `.high`
// and `RiskScorer` scores it `.high` independently (§5.3); under anything but
// full autonomy that means a person is asked. P14.4 will make it ask even
// then — a package install is the one action where "the model was confident"
// is not a reason.
// ─────────────────────────────────────────────────────────────

public struct InstallPackageTool: AgentTool {
    public let name = "install_package"
    public let toolDescription = """
    ติดตั้งแพ็กเกจ Python (pip) หรือ Node (npm) ลงในโฟลเดอร์ของโปรเจกต์ \
    (ไม่ใช่ลงเครื่อง) แล้วคืนเวอร์ชันที่ติดตั้งได้จริง — เป็นทูลเดียวที่ต่อเน็ตได้ \
    และติดตั้งเฉพาะไฟล์สำเร็จรูป ไม่คอมไพล์จากซอร์สเว้นแต่จะสั่งให้ทำ
    """
    public let riskLevel: RiskLevel = .high
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "manager": { "type": "string", "enum": ["pip", "npm"],
                     "description": "ตัวจัดการแพ็กเกจ" },
        "package": { "type": "string", "description": "ชื่อแพ็กเกจ (ชื่อล้วน ไม่ใช่พาธ ไม่ใช่ตัวเลือก)" },
        "version": { "type": "string", "description": "เวอร์ชันที่ต้องการ (ไม่ระบุ = ล่าสุด)" },
        "allow_source_build": { "type": "boolean",
                                "description": "ยอมให้คอมไพล์จากซอร์ส ซึ่งจะรันโค้ดของแพ็กเกจตอนติดตั้ง" }
      },
      "required": ["manager", "package"]
    }
    """

    private let registry: ProcessRegistry
    /// Where the project's own packages live. Given rather than derived, so a
    /// test never writes into a real project.
    private let directoryForScope: @Sendable (Scope) -> URL?
    private let log = AppLog.logger("install-package")

    public init(registry: ProcessRegistry,
                directoryForScope: @escaping @Sendable (Scope) -> URL?) {
        self.registry = registry
        self.directoryForScope = directoryForScope
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Self.request(from: argumentsJSON)
        guard directoryForScope(context.scope) != nil else {
            throw ToolError.invalidArguments(
                "ยังไม่รู้ว่าจะติดตั้งลงโฟลเดอร์ไหน — เปิดโปรเจกต์ก่อน "
                    + "แพ็กเกจถูกติดตั้งลงในโปรเจกต์ ไม่ใช่ลงเครื่อง")
        }
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let request = try Self.request(from: argumentsJSON)
        guard let directory = directoryForScope(context.scope) else {
            throw ToolError.invalidArguments("ยังไม่รู้ว่าจะติดตั้งลงโฟลเดอร์ไหน — เปิดโปรเจกต์ก่อน")
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The real interpreter, not the `xcrun` shim that cannot start inside
        // the App Sandbox — the failure P9.6 measured with a signed probe.
        let executable: String
        do {
            executable = try ExecutableSearch.resolve(request.manager == .pip ? "python3" : "npm")
        } catch {
            throw ToolError.executionFailed(
                "ไม่พบ \(request.manager == .pip ? "python3" : "npm") ที่รันได้บนเครื่องนี้: \(error)")
        }

        let spec = ProcessSpec(
            executable: executable,
            arguments: request.arguments(into: directory),
            workingDirectory: directory,
            timeout: .seconds(600),
            // The exception, in one place: network on, writes still confined.
            sandbox: SandboxProfile(writableSubpaths: [directory.path(percentEncoded: false),
                                                       NSTemporaryDirectory()],
                                    allowNetwork: true))

        let outcome: ProcessOutcome
        do {
            outcome = try await registry.run(spec, label: "install_package",
                                             conversationID: context.conversationID)
        } catch let error as ExecutionError {
            throw ToolError.executionFailed(error.description)
        }

        let output = outcome.stdout + "\n" + outcome.stderr
        guard outcome.exitCode == 0 else {
            // The one failure the caller can act on, said as an instruction
            // rather than as a wall of pip output.
            if !request.allowSourceBuild, PackageOutputReader.needsSourceBuild(output) {
                throw ToolError.executionFailed(
                    PackageInstallError.sourceBuildRefused(request.name).description
                        + "\n\n" + output.trimmed(to: 1_200))
            }
            throw ToolError.executionFailed(
                "ติดตั้ง \(request.specifier) ไม่สำเร็จ (exit \(outcome.exitCode))\n"
                    + output.trimmed(to: 2_000))
        }

        let installed = InstalledPackage(
            manager: request.manager,
            name: request.name,
            resolvedVersion: PackageOutputReader.resolvedVersion(of: request.name,
                                                                 manager: request.manager,
                                                                 in: output),
            installedAt: Date(),
            directory: directory.path(percentEncoded: false))
        log.info("installed \(request.specifier, privacy: .public)")

        // `sandboxApplied` is false inside the App Sandbox, where a nested
        // seatbelt profile cannot be hosted. It matters more for this tool than
        // for any other: unconfined means the install script could write
        // outside the project. Saying "installed into the project" without
        // saying that would be a claim about safety that did not hold.
        let confinement = outcome.sandboxApplied
            ? "รันในกรอบ sandbox ที่เขียนได้เฉพาะโฟลเดอร์นี้"
            : "⚠️ **รันโดยไม่มีกรอบ sandbox ซ้อน** (แอปอยู่ใน App Sandbox อยู่แล้วจึงซ้อนอีกชั้นไม่ได้) "
                + "— สคริปต์ติดตั้งของแพ็กเกจเขียนไฟล์นอกโฟลเดอร์นี้ได้ เท่าที่ container ของแอปอนุญาต"

        return ToolOutput(text: """
            ติดตั้งแล้ว: \(installed.summary)
            ลงที่: \(installed.directory)
            แพ็กเกจอยู่ในโปรเจกต์นี้เท่านั้น ไม่ได้ติดตั้งลงเครื่อง — \
            สภาพแวดล้อมของโปรเจกต์อื่นไม่เปลี่ยนตาม
            \(confinement)

            \(output.trimmed(to: 1_500))
            """)
    }

    private static func request(from argumentsJSON: String) throws -> PackageRequest {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidArguments("อ่านอาร์กิวเมนต์ไม่ได้")
        }
        guard let manager = object["manager"] as? String else {
            throw ToolError.invalidArguments("ต้องระบุ manager (pip หรือ npm)")
        }
        guard let package = object["package"] as? String else {
            throw ToolError.invalidArguments("ต้องระบุชื่อแพ็กเกจใน package")
        }
        do {
            return try PackageRequest.checked(
                manager: manager,
                name: package,
                version: object["version"] as? String,
                allowSourceBuild: object["allow_source_build"] as? Bool ?? false)
        } catch let error as PackageInstallError {
            throw ToolError.invalidArguments(error.description)
        }
    }
}

private extension String {
    func trimmed(to limit: Int) -> String {
        count <= limit ? self : String(prefix(limit)) + "\n… (ตัดที่ \(limit) อักขระ)"
    }
}
