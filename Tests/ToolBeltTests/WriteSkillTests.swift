import Testing
import Foundation
import AgentKit
import CoreEngine
import Roster
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// `write_skill` (ARCHITECTURE §7.3, P8.5).
//
// The Done-when is "skill ที่ agent เขียน โหลดกลับมาใช้ได้", so the first test
// writes one *through the gate* — the way an agent would — and then loads the
// directory with `ManifestParser`, the same loader the app uses at boot. Not a
// check that a file appeared: a check that the roster has it.
//
// §7.3's other requirement is that this is not a backdoor. That is tested by
// the ordinary gate behaviour: no approval channel, no skill on disk.
// ─────────────────────────────────────────────────────────────

private func skillsDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "coai-skills-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private struct AlwaysApproves: ApprovalRequesting {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision { .approved }
}

private let toolsOnThisMachine: Set<String> = ["run_shell", "kb_search", "web_search"]

private func tool(_ directory: URL) -> WriteSkillTool {
    WriteSkillTool(directory: directory, knownTools: { toolsOnThisMachine })
}

private func gateway(_ directory: URL,
                     approver: (any ApprovalRequesting)? = AlwaysApproves()) async -> ToolGateway {
    let gateway = ToolGateway(approver: approver)
    await gateway.register(tool(directory))
    return gateway
}

private func context() -> ToolContext { ToolContext(scope: .central, conversationID: "c1") }

@Suite("write_skill", .serialized)
struct WriteSkillTests {

    /// **The Done-when.** Written by an agent, through the gate, and then read
    /// back by the loader the app boots with.
    @Test("a skill an agent writes loads back into the roster and can be used")
    func writtenSkillLoadsBack() async throws {
        let directory = skillsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = await gateway(directory)

        let outcome = try await gate.call("write_skill", argumentsJSON: """
        {"name": "thai-ocr-cleanup",
         "description": "ใช้เมื่อข้อความจาก OCR ภาษาไทยมีสระลอยหรือวรรณยุกต์ผิดตำแหน่ง",
         "tools": ["run_shell", "kb_search"],
         "definition_of_done": "ข้อความผ่านการตรวจด้วยตาหนึ่งรอบและไม่มีสระลอย",
         "body": "1. แยกบรรทัดที่มีสระลอย\\n2. รวมกลับด้วย normalization form C\\n3. ตรวจซ้ำ"}
        """, context: context())

        guard case .executed(let output, _, _) = outcome else {
            Issue.record("ไม่ได้รัน: \(outcome)")
            return
        }
        #expect(output.text.contains("thai-ocr-cleanup"))

        // The loader the app uses at boot, not our own reading of the file.
        let parser = ManifestParser(knownTools: toolsOnThisMachine,
                                    toolRisks: ["run_shell": .high, "kb_search": .low])
        let loaded = parser.load(directory: directory, kind: .skill)
        #expect(loaded.errors.isEmpty, "\(loaded.errors)")
        let skill = try #require(loaded.manifests.first)
        #expect(skill.name == "thai-ocr-cleanup")
        #expect(skill.tools == ["run_shell", "kb_search"])
        #expect(skill.definitionOfDone?.contains("สระลอย") == true)
        #expect(skill.body.contains("normalization form C"))

        // And it is a usable roster entry, with the ceiling P8.2 computes from
        // its tools rather than from anything the file said.
        #expect(parser.entry(for: skill).riskCeiling == .high)
    }

    /// §7.3: through the normal gate, not around it. Nothing about this tool
    /// is exempt, and the proof is that it behaves like every other tool when
    /// there is no way to ask a human.
    @Test("with no approval channel, no skill is written")
    func theGateAppliesLikeAnyOtherTool() async throws {
        let directory = skillsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Medium risk needs approval under the strictest setting; there is no
        // approver, and §5.3 says that is a denial rather than a default to
        // running.
        let gate = ToolGateway(approver: nil, modes: OperatingModes(autonomy: .approvalRequired))
        await gate.register(tool(directory))

        let outcome = try await gate.call("write_skill", argumentsJSON: """
        {"name": "sneaky", "description": "d", "body": "b"}
        """, context: context())

        if case .denied = outcome {} else { Issue.record("ไม่ได้ถูกปฏิเสธ: \(outcome)") }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)).isEmpty)
    }

    /// The rule that makes the Done-when true rather than hoped for: a file
    /// that would not load is not written, and the agent is told why while
    /// there is still somebody to tell.
    @Test("a skill naming a tool that does not exist is refused, and nothing is written")
    func unknownToolsAreRefusedBeforeWriting() async throws {
        let directory = skillsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = await gateway(directory)

        await #expect(throws: ToolError.self) {
            try await gate.call("write_skill", argumentsJSON: """
            {"name": "wishful", "description": "d", "tools": ["run_shel"], "body": "b"}
            """, context: context())
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)).isEmpty)
    }

    /// P8.2, reached from a new direction: a skill cannot grade itself, and
    /// the writer has no parameter that would let it try. The check is that
    /// the field cannot arrive through the body either.
    @Test("a skill cannot give itself a risk level")
    func riskIsNotWritable() async throws {
        let directory = skillsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = await gateway(directory)

        // The body is written below the frontmatter fence, so text that looks
        // like a field is text, not a field.
        _ = try await gate.call("write_skill", argumentsJSON: """
        {"name": "tries", "description": "d", "body": "risk: low\\nbypass_gate: true"}
        """, context: context())

        let parser = ManifestParser(knownTools: toolsOnThisMachine)
        let loaded = parser.load(directory: directory, kind: .skill)
        let skill = try #require(loaded.manifests.first)
        #expect(loaded.errors.isEmpty)
        // It loaded, with no tools, and therefore the lowest ceiling — the
        // words in its body bought it nothing.
        #expect(skill.tools.isEmpty)
        #expect(parser.entry(for: skill).riskCeiling == .low)
    }

    /// Replacing a skill somebody wrote is a different act from adding one.
    @Test("an existing skill is not overwritten unless the agent says so")
    func overwriteIsExplicit() async throws {
        let directory = skillsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = await gateway(directory)
        let first = """
        {"name": "notes", "description": "รุ่นแรก", "body": "เนื้อหาเดิม"}
        """
        _ = try await gate.call("write_skill", argumentsJSON: first, context: context())

        // Sent back to the model rather than thrown: a refusal the model can
        // read and act on is a normal outcome of a turn (§5.3).
        let refused = try await gate.call("write_skill", argumentsJSON: """
        {"name": "notes", "description": "รุ่นสอง", "body": "เนื้อหาใหม่"}
        """, context: context())
        if case .sentBack(let reason) = refused {
            #expect(reason.contains("overwrite"))
        } else {
            Issue.record("ควรถูกส่งกลับ: \(refused)")
        }
        var text = try String(contentsOf: directory.appending(path: "notes.md"), encoding: .utf8)
        #expect(text.contains("เนื้อหาเดิม"))

        _ = try await gate.call("write_skill", argumentsJSON: """
        {"name": "notes", "description": "รุ่นสอง", "body": "เนื้อหาใหม่", "overwrite": true}
        """, context: context())
        text = try String(contentsOf: directory.appending(path: "notes.md"), encoding: .utf8)
        #expect(text.contains("เนื้อหาใหม่"))
    }

    /// A name is a filename, and a filename that climbs out of the directory
    /// is how a "skill" becomes a write to somewhere else.
    @Test("a name that would escape the skills directory is refused")
    func namesCannotEscape() async throws {
        let directory = skillsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = await gateway(directory)

        for name in ["../evil", "..", "sub/dir", ".", "a:b"] {
            let outcome = try await gate.call("write_skill", argumentsJSON: """
            {"name": "\(name)", "description": "d", "body": "b"}
            """, context: context())
            // Refused, and refused *by name* — not quietly saved as something
            // else, which is what sanitising the name into "---evil" would be.
            if case .sentBack = outcome {} else {
                Issue.record("ควรปฏิเสธชื่อ '\(name)': \(outcome)")
            }
        }
        let written = try FileManager.default.subpathsOfDirectory(
            atPath: directory.path(percentEncoded: false))
        #expect(written.isEmpty, "\(written)")
        #expect(!FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent()
                .appending(path: "evil.md").path(percentEncoded: false)))
    }

    /// The description is what the router picks from, and in a flat
    /// frontmatter format a newline in it silently truncates the field.
    @Test("a description that would break the format is refused")
    func malformedFieldsAreRefused() async throws {
        let directory = skillsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = await gateway(directory)

        for arguments in [
            #"{"name": "a", "description": "บรรทัดแรก\nบรรทัดสอง", "body": "b"}"#,
            #"{"name": "b", "description": "", "body": "x"}"#,
            #"{"name": "c", "description": "d", "body": "   "}"#,
        ] {
            let outcome = try await gate.call("write_skill", argumentsJSON: arguments,
                                              context: context())
            if case .sentBack = outcome {} else { Issue.record("ควรถูกส่งกลับ: \(outcome)") }
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)).isEmpty)
    }

    /// The tool list is read when the tool runs, not when it was built: an MCP
    /// server or a plugin can arrive while the app is running, and a skill
    /// naming one of its tools must not be refused for that reason.
    @Test("a tool that arrived after boot can be named in a skill")
    func toolListIsReadAtCallTime() async throws {
        let directory = skillsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = LiveTools(names: ["kb_search"])
        let gate = ToolGateway(approver: AlwaysApproves())
        await gate.register(WriteSkillTool(directory: directory,
                                           knownTools: { await live.names }))

        await #expect(throws: ToolError.self) {
            try await gate.call("write_skill", argumentsJSON: """
            {"name": "later", "description": "d", "tools": ["mcp__weather__forecast"], "body": "b"}
            """, context: context())
        }

        // A plugin is installed. Nothing was rebuilt.
        await live.add("mcp__weather__forecast")
        let outcome = try await gate.call("write_skill", argumentsJSON: """
        {"name": "later", "description": "d", "tools": ["mcp__weather__forecast"], "body": "b"}
        """, context: context())
        #expect(outcome.didExecute)
    }
}

private actor LiveTools {
    private(set) var names: Set<String>
    init(names: Set<String>) { self.names = names }
    func add(_ name: String) { names.insert(name) }
}
