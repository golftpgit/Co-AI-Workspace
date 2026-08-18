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
            sections: [Section(heading: localised("When this report was written", "A report section heading."),
                               paragraphs: [.bullets([
                                   localised("stage: \(stageAtIssue.label)", "The project stage at the time of the report. Placeholder: the stage."),
                                   generatedAt.formatted(date: .long, time: .shortened),
                                   localised("report type: \(kind.label)", "The kind of report. Placeholder: the kind."),
                               ])])]
                + sections.map { Section(heading: $0.heading, paragraphs: [.bullets($0.lines)]) }
                + [Section(heading: localised("Where the numbers in this report come from", "A report section heading."),
                           paragraphs: [.plain(
                               localised("every line above is assembled from what the system recorded — the plan and the evidence QA accepted · ", "Explains the report's provenance.")
                               + localised("the risk, issue, change-request and lesson registers · the spans tied to each work item · ", "Continues the provenance note.")
                               + localised("the frozen baseline · the benefits register ", "Continues the provenance note.")
                               + localised("no sentence here was invented by a model, and changing the source data changes the next report", "Ends the provenance note."))])])
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
