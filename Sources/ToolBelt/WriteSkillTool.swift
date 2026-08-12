import Foundation
import AgentKit
import Roster
import Observability

// ─────────────────────────────────────────────────────────────
// `write_skill` (ARCHITECTURE §7.3, §10, P8.5) — the agent writing down what
// it worked out, so the next run does not work it out again.
//
// §7.3 is explicit that this goes "ผ่าน risk/approval gate ปกติ ไม่ใช่
// backdoor", and the way that is guaranteed here is by not doing anything
// special: this is an `AgentTool` like `run_shell`, the gateway is the only
// thing that can call it (`check.sh` enforces that), and §5.3 already grades
// it Medium. There is no code in this file that could skip a gate, because
// there is no code in this file that knows one exists.
//
// **The rule that makes the Done-when true.** "A skill the agent wrote loads
// back" is not something to hope for — so the file is validated by the same
// parser that will load it, before it is written, and the write is abandoned
// if it would not load. Otherwise the agent is told it succeeded and the skill
// quietly does not exist at the next launch, which is the failure this project
// has already met three times under other names.
//
// The tool list it validates against is read at call time, not captured at
// construction: tools arrive while the app runs (an MCP server, a plugin), and
// a skill naming one of them must not be rejected because this tool was built
// before that server connected.
// ─────────────────────────────────────────────────────────────

public struct WriteSkillTool: AgentTool {
    public let name = "write_skill"
    public let toolDescription = """
    บันทึกวิธีทำงานที่ใช้ได้ผลไว้เป็น skill เพื่อให้รอบต่อไปหยิบไปใช้ได้เลย \
    ใช้เมื่อเพิ่งหาวิธีทำอะไรบางอย่างสำเร็จและมันน่าจะเจออีก — เขียนเป็นขั้นตอนที่คนหรือ agent อ่านแล้วทำตามได้ \
    ไม่ใช่บันทึกสิ่งที่เพิ่งทำไป
    """
    public let riskLevel: RiskLevel = .medium
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "name": { "type": "string", "description": "ชื่อ skill สั้น ๆ เช่น thai-ocr-cleanup" },
        "description": { "type": "string",
          "description": "หนึ่งบรรทัดว่าใช้เมื่อไหร่ — เป็นสิ่งที่ระบบใช้เลือกว่าจะหยิบ skill นี้มาใช้ไหม" },
        "body": { "type": "string", "description": "เนื้อหา: ขั้นตอนที่ทำตามได้จริง" },
        "tools": { "type": "array", "items": { "type": "string" },
          "description": "ชื่อเครื่องมือที่ skill นี้ต้องใช้ (ต้องเป็นชื่อที่มีอยู่จริง)" },
        "definition_of_done": { "type": "string",
          "description": "เกณฑ์ว่างานที่ใช้ skill นี้ถือว่าเสร็จเมื่อไหร่" },
        "overwrite": { "type": "boolean",
          "description": "เขียนทับ skill ชื่อเดิม (ค่าเริ่มต้น false)" }
      },
      "required": ["name", "description", "body"]
    }
    """

    private let directory: URL
    /// Read at call time — see the note above.
    private let knownTools: @Sendable () async -> Set<String>
    private let log = AppLog.logger("roster")

    public init(directory: URL, knownTools: @escaping @Sendable () async -> Set<String>) {
        self.directory = directory
        self.knownTools = knownTools
    }

    /// Everything that can be decided before a person is asked.
    ///
    /// All of it goes here rather than in `call` for the reason §5.3 gives: an
    /// approval spent on a write that was never going to happen is attention
    /// taken for nothing, and the second time that happens the approval stops
    /// being read. Only the check that needs the live tool list is left for
    /// `call`, because that one cannot be answered synchronously.
    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        let request = try Request(argumentsJSON)
        _ = try destination(for: request)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let request = try Request(argumentsJSON)
        let (file, fileName) = try destination(for: request)

        let text = ManifestParser.text(name: request.name,
                                       description: request.description,
                                       tools: request.tools,
                                       definitionOfDone: request.definitionOfDone,
                                       body: request.body)

        // Parsed with the loader before it is written. A skill that would be
        // rejected at load time must be rejected now, while there is still
        // somebody to tell.
        let parser = ManifestParser(knownTools: await knownTools())
        do {
            _ = try parser.parse(text, kind: .skill, source: file)
        } catch let error as ManifestError {
            throw ToolError.invalidArguments("\(error)")
        }

        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw ToolError.executionFailed("เขียนไฟล์ไม่ได้: \(error)")
        }

        log.info("skill '\(request.name, privacy: .public)' written")
        return ToolOutput(
            text: "บันทึก skill '\(request.name)' แล้วที่ \(fileName)"
                + (request.tools.isEmpty ? "" : " (ใช้เครื่องมือ: \(request.tools.joined(separator: ", ")))"),
            artifacts: [file.path(percentEncoded: false)])
    }

    /// Where this skill would go, and whether it may.
    private func destination(for request: Request) throws -> (file: URL, name: String) {
        guard let fileName = ManifestParser.fileName(for: request.name) else {
            throw ToolError.invalidArguments(
                "ชื่อ skill ใช้เป็นชื่อไฟล์ไม่ได้: '\(request.name)' — ห้ามมี / \\ : หรือขึ้นบรรทัดใหม่")
        }
        let file = directory.appending(path: fileName)
        // Replacing a skill somebody wrote is a different act from adding one,
        // and an agent has to say which it means.
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
           !request.overwrite {
            throw ToolError.notPermitted(
                "มี skill ชื่อ '\(request.name)' อยู่แล้ว — ถ้าตั้งใจเขียนทับให้ส่ง overwrite: true")
        }
        return (file, fileName)
    }

    // MARK: - arguments

    private struct Request {
        let name: String
        let description: String
        let body: String
        let tools: [String]
        let definitionOfDone: String?
        let overwrite: Bool

        init(_ json: String) throws {
            struct Payload: Decodable {
                let name: String
                let description: String
                let body: String
                let tools: [String]?
                let definition_of_done: String?
                let overwrite: Bool?
            }
            guard let payload = try? JSONDecoder().decode(Payload.self,
                                                          from: Data(json.utf8)) else {
                throw ToolError.invalidArguments("ต้องมี name, description และ body")
            }
            name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            description = payload.description.trimmingCharacters(in: .whitespacesAndNewlines)
            body = payload.body
            tools = payload.tools ?? []
            definitionOfDone = payload.definition_of_done
            overwrite = payload.overwrite ?? false

            guard !name.isEmpty else { throw ToolError.invalidArguments("ชื่อ skill ว่างไม่ได้") }
            guard !description.isEmpty else {
                throw ToolError.invalidArguments(
                    "ต้องมี description — เป็นสิ่งที่ระบบใช้เลือกว่าจะหยิบ skill นี้มาใช้ไหม")
            }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError.invalidArguments("skill ที่ไม่มีเนื้อหาไม่มีประโยชน์")
            }
            // A description with a newline in it silently truncates the field
            // in a flat frontmatter format — caught here rather than producing
            // a file that parses into something the author did not write.
            guard !description.contains("\n"), !name.contains("\n") else {
                throw ToolError.invalidArguments("ชื่อและ description ต้องอยู่บรรทัดเดียว")
            }
        }
    }
}
