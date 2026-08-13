import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The three reports (ARCHITECTURE §19.13, P10.11).
//
// The standards ask for reporting at three rhythms — a status report while a
// stage runs, one at each boundary, one at the end — and the interesting design
// question is not which sections they have. It is where the sentences come from.
//
// Here they come from rows. Every line below is a restatement of something the
// system already recorded: the plan for what was delivered, the ledger for what
// it cost, the registers for what went wrong, the baseline for what changed, the
// benefit ledger for whether it was worth it. Nothing is passed to a model and
// nothing is summarised by one, which is the whole of the Done-when: change the
// source and the report changes, because there is no second copy of the facts.
//
// `ReportBuilder` is a pure function of (kind, inputs, now) for the same reason
// `ToleranceCheck` is: a report is the thing people quote in meetings, and a
// report that cannot be reproduced from stored data is a report nobody can
// check afterwards.
// ─────────────────────────────────────────────────────────────

public enum ReportKind: String, Sendable, Codable, CaseIterable {
    /// While a stage runs, on a cycle or on request.
    case highlight
    /// At a stage boundary, asking to go on.
    case endStage
    /// At closing.
    case endProject

    public var label: String {
        switch self {
        case .highlight: "รายงานความคืบหน้า"
        case .endStage: "รายงานปิดขั้น"
        case .endProject: "รายงานปิดโครงการ"
        }
    }
}

public struct ReportSection: Sendable, Codable, Equatable {
    public let heading: String
    /// Already-formatted lines. Empty is not allowed to happen silently — a
    /// section with nothing in it says so, because a heading with no body reads
    /// as "nothing to report" when it often means "nothing was recorded".
    public let lines: [String]

    public init(heading: String, lines: [String]) {
        self.heading = heading
        self.lines = lines.isEmpty ? ["— ไม่มีรายการที่ระบบบันทึกไว้ —"] : lines
    }
}

public struct ProjectReport: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    public let kind: ReportKind
    public let title: String
    /// The stage the project was in when this was written. Kept because a
    /// boundary report read a year later is meaningless without it — and named
    /// so it cannot be mistaken for the project's current stage, which only
    /// `ProjectService.advance` may set (§19.15 invariant 1).
    public let stageAtIssue: ProjectStage
    public let generatedAt: Date
    public let sections: [ReportSection]

    public init(id: String = OpaqueID.make(OpaqueID.report),
                projectID: ProjectID,
                kind: ReportKind,
                title: String,
                stageAtIssue: ProjectStage,
                generatedAt: Date,
                sections: [ReportSection]) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.title = title
        self.stageAtIssue = stageAtIssue
        self.generatedAt = generatedAt
        self.sections = sections
    }

    /// The report as text, which is what a channel sends and what the document
    /// writer turns into a file. One rendering, so the version on somebody's
    /// phone is the version in the .docx.
    public var rendered: String {
        var lines = [title, ""]
        lines.append("ขั้น\(stageAtIssue.label) · \(generatedAt.formatted(date: .abbreviated, time: .shortened))")
        for section in sections {
            lines.append("")
            lines.append(section.heading)
            lines.append(contentsOf: section.lines.map { "• \($0)" })
        }
        lines.append("")
        // The line that makes the rest checkable. Without it a reader has no way
        // to tell this from a summary a model wrote.
        lines.append("รายงานนี้ประกอบจากข้อมูลที่ระบบบันทึกไว้ (แผนงาน · ทะเบียน · span · baseline · ทะเบียนประโยชน์) ไม่มีประโยคที่โมเดลแต่งขึ้น")
        return lines.joined(separator: "\n")
    }
}

/// Everything the three reports read. Assembled by `ProjectService`, which is
/// the only object holding all of these stores.
public struct ReportInputs: Sendable {
    public var project: Project
    public var wbs: WorkBreakdown
    public var registers: [RegisterEntry]
    public var benefits: BenefitLedger
    public var baselines: [Baseline]
    public var drift: BaselineDiff?
    public var tolerances: [ToleranceStatus]
    /// Which tolerance dimensions the app is actually reading. The rest print as
    /// "ยังไม่ได้วัด" — a number nobody measured is worse in a report than in a
    /// status strip, because the report gets quoted.
    public var measured: Set<ToleranceDimension>
    public var elapsedSeconds: TimeInterval
    public var exceptions: [ExceptionReport]
    public var gate: GateEvaluation?
    public var conformance: [PracticeStatus]
    /// When the previous report of this kind was written. "New since last time"
    /// is the only honest reading of "issue/risk ใหม่"; without it a highlight
    /// report repeats every risk ever raised.
    public var since: Date?

    public init(project: Project,
                wbs: WorkBreakdown = WorkBreakdown(),
                registers: [RegisterEntry] = [],
                benefits: BenefitLedger = BenefitLedger(),
                baselines: [Baseline] = [],
                drift: BaselineDiff? = nil,
                tolerances: [ToleranceStatus] = [],
                measured: Set<ToleranceDimension> = [],
                elapsedSeconds: TimeInterval = 0,
                exceptions: [ExceptionReport] = [],
                gate: GateEvaluation? = nil,
                conformance: [PracticeStatus] = [],
                since: Date? = nil) {
        self.project = project
        self.wbs = wbs
        self.registers = registers
        self.benefits = benefits
        self.baselines = baselines
        self.drift = drift
        self.tolerances = tolerances
        self.measured = measured
        self.elapsedSeconds = elapsedSeconds
        self.exceptions = exceptions
        self.gate = gate
        self.conformance = conformance
        self.since = since
    }
}

public enum ReportBuilder {

    public static func build(_ kind: ReportKind, from inputs: ReportInputs,
                             now: Date = Date()) -> ProjectReport {
        ProjectReport(projectID: inputs.project.id,
                      kind: kind,
                      title: "\(kind.label): \(inputs.project.name)",
                      stageAtIssue: inputs.project.stage,
                      generatedAt: now,
                      sections: sections(kind, inputs, now))
    }

    private static func sections(_ kind: ReportKind, _ inputs: ReportInputs,
                                 _ now: Date) -> [ReportSection] {
        switch kind {
        case .highlight: highlight(inputs, now)
        case .endStage: endStage(inputs)
        case .endProject: endProject(inputs)
        }
    }

    // MARK: - highlight (§19.13)

    private static func highlight(_ inputs: ReportInputs, _ now: Date) -> [ReportSection] {
        let leaves = inputs.wbs.leaves
        let done = leaves.filter { $0.status == .done }
        let running = leaves.filter { $0.status == .inProgress || $0.status == .inReview }
        let next = Schedule.ready(inputs.wbs)
        let fresh = inputs.registers.filter { entry in
            guard [RegisterKind.risk, .issue].contains(entry.kind) else { return false }
            guard let since = inputs.since else { return true }
            // `>=`, not `>`. Both timestamps have been through ISO-8601 without
            // fractional seconds on the way to the database, so two things that
            // happened in the same second come back equal — and with a strict
            // comparison a risk raised in the same second as the previous report
            // is never reported at all. Driving it found exactly that. Repeating
            // one entry is noise; dropping a new one is a missed escalation.
            return entry.createdAt >= since
        }
        return [
            ReportSection(heading: "ทำเสร็จแล้ว", lines: done.map(delivered)),
            ReportSection(heading: "กำลังทำและจะทำต่อ",
                          lines: running.map { "\($0.title) — \($0.status.label)" }
                              + next.map { "\($0.title) — พร้อมเริ่ม" }),
            ReportSection(heading: "กรอบที่ตกลงไว้ ตอนนี้อยู่ที่ไหน",
                          lines: toleranceLines(inputs)),
            ReportSection(heading: inputs.since == nil
                          ? "ความเสี่ยงและปัญหาที่บันทึกไว้"
                          : "ความเสี่ยงและปัญหาใหม่ตั้งแต่รายงานฉบับก่อน",
                          lines: fresh.map { "[\($0.kind.label)] \($0.title) — \($0.status.label) · เสนอโดย \($0.origin.label)" }),
            ReportSection(heading: "เวลาและค่าใช้จ่ายที่ใช้ไป", lines: spendLines(inputs)),
        ]
    }

    // MARK: - end of stage (§19.13)

    private static func endStage(_ inputs: ReportInputs) -> [ReportSection] {
        let approved = inputs.registers.filter { $0.kind == .change && $0.status == .approved }
        var agreement: [String] = []
        if let latest = inputs.baselines.max(by: { $0.version < $1.version }) {
            agreement.append("แผนที่ตกลงไว้: v\(latest.version) (\(latest.reason)) · \(latest.packages.count) ใบงาน")
            agreement.append(inputs.drift.map { $0.isEmpty
                ? "แผนวันนี้ตรงกับ v\(latest.version)"
                : "ต่างจาก v\(latest.version): \($0.summary)" } ?? "ยังอ่านส่วนต่างไม่ได้")
        } else {
            // Before G2 there is no agreement to compare against, and saying so
            // is more useful than printing a variance of zero.
            agreement.append("ยังไม่มี baseline — แผนยังไม่ได้ถูก freeze เป็นข้อตกลง")
        }
        return [
            ReportSection(heading: "ผลเทียบกับแผนที่ตกลงไว้", lines: agreement),
            ReportSection(heading: "ส่วนต่างและเหตุผล",
                          lines: approved.map { entry in
                              var line = "\(entry.title) — อนุมัติโดย \(entry.decidedBy ?? "—")"
                              if case .change(let scope, let time, let cost) = entry.detail {
                                  line += " · ขอบเขต: \(scope) · เวลา: \(time) · เงิน: \(cost)"
                              }
                              return line
                          }),
            ReportSection(heading: "business case ยังคุ้มไหม", lines: benefitLines(inputs)),
            ReportSection(heading: "ขอเข้าขั้นถัดไป", lines: gateLines(inputs)),
        ]
    }

    // MARK: - end of project (§19.13)

    private static func endProject(_ inputs: ReportInputs) -> [ReportSection] {
        let leaves = inputs.wbs.leaves
        let lessons = inputs.registers.filter { $0.kind == .lesson }
        let stillOpen = inputs.registers.filter {
            [RegisterKind.risk, .issue, .change].contains($0.kind) && $0.status.isOpen
        }
        var handover = stillOpen.map {
            "[\($0.kind.label)] \($0.title) — ยังเปิดอยู่ · เจ้าของ \($0.owner?.label ?? "ยังไม่มีใครรับ")"
        }
        // A benefit whose review date is after closing is the most commonly
        // dropped handover item there is, so it is listed as one.
        handover += inputs.benefits.unmeasured.map {
            "ยังต้องวัด: \($0.title) — กำหนด \($0.reviewAt.formatted(date: .abbreviated, time: .omitted)) · \($0.owner.label)"
        }
        if let disposition = inputs.project.dataDisposition, disposition.isDecided {
            handover.append("ข้อมูลและไฟล์: \(disposition.action.label) ตามนโยบาย “\(disposition.policy)” · ตัดสินโดย \(disposition.decidedBy)")
        }
        let tailored = inputs.conformance.filter(\.isTailored)
        var variance: [String] = []
        if let first = inputs.baselines.min(by: { $0.version < $1.version }) {
            variance.append("แผนแรกที่ตกลงกัน: v\(first.version) · \(first.packages.count) ใบงาน")
            variance.append("แผนตอนปิด: \(leaves.count) ใบงาน · เปลี่ยนข้อตกลง \(inputs.baselines.count) ครั้ง")
        }
        variance.append(contentsOf: spendLines(inputs))
        return [
            ReportSection(heading: "ส่งมอบอะไรบ้าง",
                          lines: leaves.filter { $0.status == .done }.map(delivered)),
            ReportSection(heading: "ประโยชน์ที่วัดได้", lines: benefitLines(inputs)),
            ReportSection(heading: "ส่วนต่างรวม", lines: variance),
            ReportSection(heading: "บทเรียน", lines: lessons.map { entry in
                var line = entry.title
                if case .lesson(let cause, let differently, let appliesTo) = entry.detail {
                    line += " — สาเหตุ: \(cause) · ครั้งหน้า: \(differently)"
                    if !appliesTo.isEmpty { line += " · ใช้กับ: \(appliesTo)" }
                }
                return line
            }),
            ReportSection(heading: "สิ่งที่ยกให้คนอื่นรับต่อ", lines: handover),
            ReportSection(heading: "practice ที่ตัดสินว่าไม่ทำ (tailoring)",
                          lines: tailored.map {
                              "\($0.practice.label) — \($0.tailoring?.reason ?? "")"
                                  + " · ตัดสินโดย \($0.tailoring?.decidedBy ?? "—")"
                          }),
        ]
    }

    // MARK: - lines shared by more than one report

    private static func delivered(_ package: WorkPackage) -> String {
        let accepted = package.evidence.filter(\.passed)
        let evidence = accepted.isEmpty
            ? "ยังไม่มีหลักฐานที่ QA รับ"
            : accepted.map(\.summary).joined(separator: " · ")
        return "\(package.title) — \(evidence)"
    }

    private static func toleranceLines(_ inputs: ReportInputs) -> [String] {
        inputs.tolerances.map { status in
            guard inputs.measured.contains(status.dimension) else {
                return "\(status.dimension.label): กรอบ \(number(status.limit)) · ยังไม่ได้วัด"
            }
            return "\(status.dimension.label): \(number(status.current)) / \(number(status.limit))"
                + (status.breached ? " — ทะลุกรอบ" : "")
        }
        + inputs.exceptions.filter(\.isOpen).map {
            "หยุดรอคำตัดสิน: ทะลุกรอบ\($0.dimension.label) — \($0.needsFromHuman)"
        }
    }

    private static func benefitLines(_ inputs: ReportInputs) -> [String] {
        guard !inputs.benefits.isEmpty else { return [] }
        return inputs.benefits.benefits.map { benefit in
            guard let achieved = benefit.achievement, let result = benefit.result else {
                return "\(benefit.title): ยังไม่ได้วัด (กำหนด \(benefit.reviewAt.formatted(date: .abbreviated, time: .omitted)))"
            }
            return "\(benefit.title): \(number(result.value)) \(benefit.measure)"
                + " · จาก \(number(benefit.baselineValue)) เป้า \(number(benefit.target))"
                + " · ได้ \(Int(achieved * 100))% ของเป้า · วัดโดย \(result.measuredBy)"
        }
    }

    private static func gateLines(_ inputs: ReportInputs) -> [String] {
        guard let gate = inputs.gate else { return ["โครงการปิดแล้ว — ไม่มีขั้นถัดไป"] }
        return ["\(gate.gate): \(gate.from.label) → \(gate.to.label) — "
                + (gate.passed ? "ผ่านครบทุกเงื่อนไข" : "ยังไม่ผ่าน")]
            + gate.conditions.map { "\($0.satisfied ? "✓" : "✗") \($0.text)" }
    }

    private static func spendLines(_ inputs: ReportInputs) -> [String] {
        var lines: [String] = []
        if inputs.elapsedSeconds > 0 {
            lines.append("เวลาที่วัดได้จาก span: \(Int(inputs.elapsedSeconds / 60)) นาที")
        } else {
            lines.append("เวลา: ยังไม่มี span ที่ผูกกับใบงานของโครงการนี้")
        }
        if inputs.measured.contains(.cost) {
            lines.append("ค่าใช้จ่ายที่บันทึกไว้: ฿\(number(inputs.tolerances.first { $0.dimension == .cost }?.current ?? 0))")
        } else {
            lines.append("ค่าใช้จ่าย: ยังไม่ได้ต่อกับบัญชีการใช้จ่าย")
        }
        return lines
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Where issued reports are kept. They are history, so there is no update and no
/// delete: "how often did anybody report" is a question about the past, and a
/// report that can be withdrawn afterwards cannot answer it.
public protocol ReportPersisting: Sendable {
    func save(_ report: ProjectReport) async throws
    func all(project: ProjectID) async throws -> [ProjectReport]
}
