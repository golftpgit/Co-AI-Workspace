import Foundation
import AgentKit
import DocGen
import Observability

// ─────────────────────────────────────────────────────────────
// `save_document` (ARCHITECTURE §M6, §14.1, P7.6).
//
// P7.6 built real `.docx` and `.pptx` writing, proved it with Word's own
// reader, and shipped it reachable from exactly one button on the analysis
// screen. Meanwhile the Writer specialist's tool list is `["kb_search"]` — the
// role whose entire job is producing documents could not produce a file. Sixth
// instance of the same gap.
//
// **What this tool deliberately cannot do yet.** §14.1's rule is that a
// sentence taken from the knowledge base carries its source, and that a source
// with no author or year *stops generation*. Honouring that from a tool call
// means the agent has to hand back chunk identifiers, not prose — otherwise the
// citations would be whatever the model typed, which is the failure mode the
// rule exists to prevent. So this writes documents whose paragraphs are the
// agent's own words and bullet lists, with no citation markers, and says so in
// its description. A cited document still goes through the plan screen. Half a
// feature, honestly labelled, beats a tool that invents references.
// ─────────────────────────────────────────────────────────────

public struct SaveDocumentTool: AgentTool {
    public let name = "save_document"
    public let toolDescription = """
    บันทึกเอกสารเป็นไฟล์ .docx หรือ .pptx จากหัวข้อและเนื้อหาที่ให้มา แล้วคืนที่อยู่ไฟล์ \
    ใช้เมื่อผลงานต้องส่งให้คนอื่น (บันทึกข้อความ, สรุปการประชุม, ร่างที่ยังไม่อ้างอิง) \
    **ยังไม่รองรับการอ้างอิงจากคลังความรู้** — เอกสารที่ต้องมี citation ผูก provenance ต้องทำผ่านหน้าแผนวิเคราะห์ \
    เพราะ §14.1 กำหนดว่าการอ้างอิงมาจากแหล่งจริงเท่านั้น ไม่ใช่จากสิ่งที่โมเดลพิมพ์
    """
    /// §5.3's table. It writes a file somebody will send to somebody else.
    public let riskLevel: RiskLevel = .medium
    public let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "title": { "type": "string", "description": "ชื่อเอกสาร" },
        "filename": { "type": "string",
          "description": "ชื่อไฟล์ (ไม่ต้องใส่นามสกุล — ไม่ระบุ = ใช้ชื่อเอกสาร)" },
        "format": { "type": "string", "enum": ["docx", "pptx"],
          "description": "docx = รายงาน, pptx = สไลด์หนึ่งแผ่นต่อหนึ่งหัวข้อ (ค่าเริ่มต้น docx)" },
        "authors": { "type": "array", "items": { "type": "string" } },
        "sections": {
          "type": "array",
          "description": "เรียงตามลำดับที่จะปรากฏในเอกสาร",
          "items": {
            "type": "object",
            "properties": {
              "heading": { "type": "string" },
              "paragraphs": { "type": "array", "items": { "type": "string" },
                "description": "ย่อหน้าปกติ" },
              "bullets": { "type": "array", "items": { "type": "string" },
                "description": "รายการหัวข้อย่อย (ใส่พร้อม paragraphs ได้)" }
            },
            "required": ["heading"]
          }
        }
      },
      "required": ["title", "sections"]
    }
    """

    private let directory: URL
    private let log = AppLog.logger("docgen")

    public init(directory: URL) {
        self.directory = directory
    }

    public func precheck(argumentsJSON: String, context: ToolContext) throws {
        _ = try Request(argumentsJSON)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
        let request = try Request(argumentsJSON)
        let draft = DocumentDraft(
            title: request.title,
            authors: request.authors,
            sections: request.sections.map { section in
                var paragraphs: [Paragraph] = section.paragraphs.map { .plain($0) }
                if !section.bullets.isEmpty { paragraphs.append(.bullets(section.bullets)) }
                return Section(heading: section.heading, paragraphs: paragraphs)
            })

        let rendered: RenderedDocument
        do {
            rendered = try DocumentBuilder.render(draft)
        } catch {
            throw ToolError.invalidArguments("\((error as? DocumentError)?.description ?? "\(error)")")
        }

        let file = directory.appending(path: request.filename + "." + request.format)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let data = request.format == "pptx" ? OfficeWriter.pptx(rendered)
                                                : OfficeWriter.docx(rendered)
            try data.write(to: file, options: .atomic)
        } catch {
            throw ToolError.executionFailed("เขียนไฟล์ไม่ได้: \(error)")
        }
        log.info("saved \(file.lastPathComponent, privacy: .public)")

        return ToolOutput(
            text: "บันทึก \(file.lastPathComponent) แล้ว (\(request.sections.count) หัวข้อ)",
            // The path, not the contents: §2.3's rule about what belongs in a
            // transcript.
            artifacts: [file.path(percentEncoded: false)])
    }

    // MARK: - arguments

    private struct Request {
        struct SectionInput: Decodable {
            let heading: String
            let paragraphs: [String]?
            let bullets: [String]?
        }
        struct Payload: Decodable {
            let title: String
            let filename: String?
            let format: String?
            let authors: [String]?
            let sections: [SectionInput]
        }

        let title: String
        let filename: String
        let format: String
        let authors: [String]
        let sections: [(heading: String, paragraphs: [String], bullets: [String])]

        init(_ json: String) throws {
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
                throw ToolError.invalidArguments("ต้องมี 'title' และ 'sections'")
            }
            title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ToolError.invalidArguments("ชื่อเอกสารว่างไม่ได้") }

            format = (payload.format ?? "docx").lowercased()
            guard format == "docx" || format == "pptx" else {
                throw ToolError.invalidArguments("format ต้องเป็น 'docx' หรือ 'pptx'")
            }

            // A filename is a filename: refused rather than sanitised, the same
            // rule `write_skill` settled on — a writer that quietly renames
            // things cannot be predicted from its input.
            let requested = (payload.filename ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requested.isEmpty,
                  !requested.contains("/"), !requested.contains("\\"), !requested.contains(":"),
                  requested.contains(where: { $0 != "." }) else {
                throw ToolError.invalidArguments(
                    "ชื่อไฟล์ '\(requested)' ใช้ไม่ได้ — ห้ามมี / \\ : หรือเป็นจุดล้วน")
            }
            filename = requested

            authors = payload.authors ?? []
            sections = payload.sections.map {
                ($0.heading, $0.paragraphs ?? [], $0.bullets ?? [])
            }
            guard !sections.isEmpty else {
                throw ToolError.invalidArguments("ต้องมีอย่างน้อยหนึ่งหัวข้อ")
            }
            guard sections.contains(where: { !$0.paragraphs.isEmpty || !$0.bullets.isEmpty }) else {
                throw ToolError.invalidArguments("ทุกหัวข้อว่างเปล่า — เอกสารที่ไม่มีเนื้อหาไม่มีประโยชน์")
            }
        }
    }
}
