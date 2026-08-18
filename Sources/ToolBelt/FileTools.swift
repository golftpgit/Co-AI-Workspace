import Foundation
import AgentKit
import Observability

// ─────────────────────────────────────────────────────────────
// `read_file` and `write_file` (ARCHITECTURE §M6, decision C6).
//
// Both names have sat in `RiskScorer.baseline` with "ยังไม่มี task ผูก" beside
// them — classified for risk, never built, printed as a reminder on every check
// run that nobody acted on (AUDIT F-9). The decision that unblocked them asked
// for three things: safe, fast, and cheap in memory.
//
// **They are a shell over `WorkspaceFiles`, not a second implementation.** That
// type already refuses paths outside the root *after resolving symlinks*,
// already distinguishes a file it can write back from a rendering it must not,
// already refuses a file too large instead of truncating it, and already holds
// the read-modify-write token that keeps an agent from silently overwriting
// what a person has open. Writing any of that again here would be the second
// copy this project has a rule against — and the copy that drifts is always the
// one guarding the thing that matters (§0.2).
//
// So what is left for this file is the part that is genuinely about tools:
//
//  • **`read_file` does not need approval; `write_file` does.** Reading inside
//    a folder the person chose is not a risk they need to be asked about every
//    time; replacing a file is. Different risk, different level — putting them
//    on one is how one of them ends up wrong.
//  • **A refusal says which rule refused.** `FileAccessError` already carries
//    that; the tool must not flatten it to "failed", which is the shape of
//    silence this project keeps paying for (M5).
//  • **A binary file is refused by name, not read as mojibake.** The person
//    asked for a 7 GB `.safetensors` by accident far more often than on purpose.
// ─────────────────────────────────────────────────────────────

/// Reads a file inside the workspace root.
public struct ReadFileTool: AgentTool {
    public let name = "read_file"
    public let toolDescription = """
    อ่านไฟล์ในโฟลเดอร์งาน แล้วคืนเนื้อหาเป็นข้อความ \
    ใช้กับไฟล์ข้อความและโค้ด · `.docx`/`.pptx`/`.pdf` อ่านได้แต่แก้ไม่ได้ \
    อ่านนอกโฟลเดอร์งานไม่ได้ และไฟล์ที่ใหญ่เกินจะถูกปฏิเสธพร้อมบอกขนาด ไม่ใช่ตัดให้สั้น
    """
    /// Reading inside a folder the person chose is not something to interrupt
    /// them about. The boundary is enforced by the root, not by asking.
    public let riskLevel: RiskLevel = .low
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "path": { "type": "string",
          "description": "ที่อยู่ไฟล์ เทียบกับโฟลเดอร์งาน เช่น notes/plan.md" }
      },
      "required": ["path"]
    }
    """

    private let log = AppLog.logger("read-file")

    public init() {}

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        // The folder the person chose, exactly as `run_shell` takes it. That is
        // what makes "what the agent writes is what a person can open" true, and
        // it is the only directory a sandboxed app has been granted.
        guard let root = context.workingDirectory else {
            throw ToolError.executionFailed("ยังไม่ได้เลือกโฟลเดอร์งาน — เลือกก่อนจึงจะอ่านไฟล์ได้")
        }
        let files = WorkspaceFiles(root: root)
        guard let path = Self.string("path", in: argumentsJSON), !path.isEmpty else {
            throw ToolError.executionFailed("ต้องระบุ path")
        }
        do {
            let url = try files.resolve(files.root.appending(path: path))
            switch try files.open(url) {
            case .editable(let text, _):
                return ToolOutput(text: text)
            case .readOnly(let text, let because):
                // Say it is a rendering. An agent that thinks it read the file
                // will try to write it back.
                return ToolOutput(text: "[อ่านอย่างเดียว — \(because)]\n\n\(text)")
            case .image(_, let name):
                throw ToolError.executionFailed("\(name) เป็นรูปภาพ — ทูลนี้อ่านเป็นข้อความไม่ได้")
            case .cannotShow(let why):
                throw ToolError.executionFailed(why)
            }
        } catch let error as FileAccessError {
            log.error("read_file refused: \(error.description, privacy: .public)")
            throw ToolError.executionFailed(error.description)
        } catch {
            throw ToolError.executionFailed("อ่านไฟล์ไม่ได้: \(error)")
        }
    }

    static func string(_ key: String, in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }
}

/// Writes a file inside the workspace root.
public struct WriteFileTool: AgentTool {
    public let name = "write_file"
    public let toolDescription = """
    เขียนไฟล์ข้อความในโฟลเดอร์งาน (สร้างใหม่หรือเขียนทับ) \
    เขียนนอกโฟลเดอร์งานไม่ได้ · เขียนทับ `.docx`/`.pptx`/`.pdf` ไม่ได้ เพราะข้อความที่อ่านออกมาเป็นแค่คำแปลของไฟล์ ไม่ใช่ตัวไฟล์ \
    ถ้าไฟล์ถูกแก้โดยคนอื่นหลังจากที่อ่านไป จะถูกปฏิเสธ ไม่ใช่เขียนทับเงียบ ๆ
    """
    /// It replaces somebody's file. §5.3's table puts that with the calls a
    /// person is asked about.
    public let riskLevel: RiskLevel = .high
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "path": { "type": "string",
          "description": "ที่อยู่ไฟล์ เทียบกับโฟลเดอร์งาน" },
        "content": { "type": "string", "description": "เนื้อหาทั้งไฟล์" }
      },
      "required": ["path", "content"]
    }
    """

    private let log = AppLog.logger("write-file")

    public init() {}

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        guard let root = context.workingDirectory else {
            throw ToolError.executionFailed("ยังไม่ได้เลือกโฟลเดอร์งาน — เลือกก่อนจึงจะเขียนไฟล์ได้")
        }
        let files = WorkspaceFiles(root: root)
        guard let path = ReadFileTool.string("path", in: argumentsJSON), !path.isEmpty,
              let content = ReadFileTool.string("content", in: argumentsJSON) else {
            throw ToolError.executionFailed("ต้องระบุ path และ content")
        }
        do {
            let url = try files.resolve(files.root.appending(path: path))
            // A new file and an existing one are different operations, and only
            // one of them can lose somebody's work.
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                guard case .editable(_, let token) = try files.open(url) else {
                    throw ToolError.executionFailed("\(url.lastPathComponent) เขียนทับไม่ได้ — "
                                    + "ข้อความที่อ่านออกมาเป็นคำแปลของไฟล์ ไม่ใช่ตัวไฟล์")
                }
                _ = try files.save(content, using: token)
                log.info("write_file แทนที่ \(url.lastPathComponent, privacy: .public)")
                return ToolOutput(text: "เขียนทับ \(url.lastPathComponent) แล้ว (\(content.count) ตัวอักษร)")
            }
            let created = try files.create(named: url.lastPathComponent,
                                           in: url.deletingLastPathComponent())
            guard case .editable(_, let token) = try files.open(created) else {
                throw ToolError.executionFailed("สร้างไฟล์แล้วแต่เขียนเนื้อหาไม่ได้: \(created.lastPathComponent)")
            }
            _ = try files.save(content, using: token)
            log.info("write_file สร้าง \(created.lastPathComponent, privacy: .public)")
            return ToolOutput(text: "สร้าง \(created.lastPathComponent) แล้ว (\(content.count) ตัวอักษร)")
        } catch let error as FileAccessError {
            log.error("write_file refused: \(error.description, privacy: .public)")
            throw ToolError.executionFailed(error.description)
        } catch {
            throw ToolError.executionFailed("เขียนไฟล์ไม่ได้: \(error)")
        }
    }
}
