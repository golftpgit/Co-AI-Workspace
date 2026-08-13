import Foundation
import AgentKit
import ProjectKit

// ─────────────────────────────────────────────────────────────
// A project report as a document (ARCHITECTURE §19.13, P10.11).
//
// The mapping is deliberately dull, and that is the point: `ReportBuilder` has
// already decided every line out of stored rows, so this file only chooses
// headings and bullets. There is nowhere here for a sentence to be invented,
// which is the property §19.13 asks for — a report that changes when its source
// data changes, and cannot change any other way.
//
// It lives in DocGen rather than ProjectKit because the direction matters:
// ProjectKit does not know what a `.docx` is, and should not learn.
// ─────────────────────────────────────────────────────────────

extension ProjectReport {
    /// The report as a draft the writers understand. Bullets rather than
    /// paragraphs because every line is already one fact.
    public var documentDraft: DocumentDraft {
        DocumentDraft(
            title: title,
            authors: [],
            sections: [Section(heading: "รายงานนี้เขียนเมื่อไร",
                               paragraphs: [.bullets([
                                   "ขั้น\(stageAtIssue.label)",
                                   generatedAt.formatted(date: .long, time: .shortened),
                                   "ชนิดรายงาน: \(kind.label)",
                               ])])]
                + sections.map { Section(heading: $0.heading, paragraphs: [.bullets($0.lines)]) }
                + [Section(heading: "ที่มาของตัวเลขในรายงานนี้",
                           paragraphs: [.plain(
                               "ทุกบรรทัดข้างต้นประกอบจากข้อมูลที่ระบบบันทึกไว้ — แผนงานและหลักฐานที่ QA รับ · "
                               + "ทะเบียนความเสี่ยง/ปัญหา/คำขอเปลี่ยนแปลง/บทเรียน · span ที่ผูกกับใบงาน · "
                               + "baseline ที่ freeze ไว้ · ทะเบียนประโยชน์ "
                               + "ไม่มีประโยคใดที่โมเดลแต่งขึ้น และเปลี่ยนข้อมูลต้นทางแล้วรายงานฉบับถัดไปเปลี่ยนตาม")])])
    }
}

public enum ReportDocument {
    /// The report as a Word file. Cannot fail on citations — a report has none,
    /// which is exactly why it is safe to generate without anybody proof-reading
    /// it (§14.1's rule is about sentences taken from the knowledge base).
    public static func docx(_ report: ProjectReport) throws -> Data {
        OfficeWriter.docx(try DocumentBuilder.render(report.documentDraft))
    }

    /// A filename that sorts and does not collide: kind, then the date it covers.
    public static func filename(_ report: ProjectReport) -> String {
        let stamp = report.generatedAt.formatted(.iso8601
            .year().month().day()
            .dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        return "\(report.kind.rawValue)-\(stamp)"
    }
}
