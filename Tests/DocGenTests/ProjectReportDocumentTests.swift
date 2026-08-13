import Testing
import Foundation
import AgentKit
import ProjectKit
@testable import DocGen

// ─────────────────────────────────────────────────────────────
// A project report as a file (ARCHITECTURE §19.13, P10.11).
//
// The mapping has one job — carry every line the builder produced into the
// document — and one hazard: a section quietly dropped on the way to the file.
// A report that is complete on screen and short in the .docx is worse than no
// file at all, because the file is the copy that gets sent.
//
// The bytes are checked with `unzip -t` rather than against our own
// expectations, the same standard as the rest of this suite: our writer agreeing
// with our reader proves nothing about Word.
// ─────────────────────────────────────────────────────────────

@Suite("Project report documents")
struct ProjectReportDocumentTests {

    private func report() -> ProjectReport {
        var project = Project(name: "ความเครียดพยาบาล", kind: .research, brief: "วัดความชุก",
                              statement: ScopeStatement(inScope: ["ความชุก"],
                                                        outOfScope: ["ข้ามวิชาชีพ"]))
        project.stage = .closing
        var leaf = WorkPackage(projectID: project.id, title: "ตารางที่ 2",
                               scopeRef: "ความชุก",
                               acceptanceCriteria: [Criterion(text: "α ≥ 0.70",
                                                              evidenceRequired: "ผลรัน")],
                               raci: RACI(accountable: .teamLead))
        leaf.status = .done
        leaf.evidence = [Evidence(kind: .statisticalCheck, summary: "α = 0.74", passed: true)]
        return ReportBuilder.build(.endProject, from: ReportInputs(
            project: project, wbs: WorkBreakdown([leaf])))
    }

    @Test("every section of the report reaches the document")
    func nothingIsDroppedOnTheWayToTheFile() {
        let report = report()
        let draft = report.documentDraft

        for section in report.sections {
            #expect(draft.sections.contains { $0.heading == section.heading },
                    "หัวข้อ \(section.heading) หายไปจากเอกสาร")
        }
        // Plus the two the document adds: when it was written, and where the
        // numbers came from.
        #expect(draft.sections.count == report.sections.count + 2)
        #expect(draft.title == report.title)
        // A report carries no citations by construction, which is exactly why it
        // is safe to generate unread — §14.1's rule is about sentences taken from
        // the knowledge base, and there are none here.
        #expect(draft.citations.isEmpty)
    }

    @Test("the file is a valid archive with the report's own lines in it")
    func writesARealDocx() throws {
        let report = report()
        let data = try ReportDocument.docx(report)
        let file = FileManager.default.temporaryDirectory
            .appending(path: ReportDocument.filename(report) + ".docx")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", file.path(percentEncoded: false)]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = pipe
        try unzip.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0, "\(output)")

        let rendered = try DocumentBuilder.render(report.documentDraft)
        #expect(rendered.plainText.contains("α = 0.74"))
        // The filename has to sort and not collide: two reports of the same kind
        // on the same day are normal.
        #expect(ReportDocument.filename(report).hasPrefix("endProject-"))
    }
}
