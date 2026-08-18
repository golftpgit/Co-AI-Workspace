import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// The three reports (ARCHITECTURE §19.13, P10.11).
//
// The Done-when is a property, not a section list: "เปลี่ยนข้อมูลต้นทางแล้ว
// รายงานเปลี่ยนตาม (ไม่ใช่ข้อความที่โมเดลแต่ง)". So the tests below change one
// row at a time and assert the report moved with it — which is the only way to
// tell a report assembled from data apart from one that merely mentions the
// right nouns.
//
// The second thing under test is what a report says when it does *not* know:
// an unmeasured tolerance and an unmeasured benefit have to print as unmeasured.
// A report is quoted in meetings, so a zero in one is worse than a zero on a
// screen — nobody can see the store it came from.
// ─────────────────────────────────────────────────────────────

actor MemoryReportStore: ReportPersisting {
    private(set) var rows: [ProjectReport] = []
    func save(_ report: ProjectReport) async throws { rows.append(report) }
    func all(project: ProjectID) async throws -> [ProjectReport] {
        rows.filter { $0.projectID == project }
    }
}

private let done = [Criterion(text: "α ≥ 0.70", evidenceRequired: "ผลรัน")]

private func project(_ stage: ProjectStage = .execution) -> Project {
    var project = Project(name: "ความเครียดพยาบาล", kind: .research,
                          brief: "วัดความชุก",
                          statement: ScopeStatement(inScope: ["ความชุก"],
                                                    outOfScope: ["ข้ามวิชาชีพ"],
                                                    acceptanceCriteria: ["ส่งวารสารได้"]),
                          board: [BoardRole(seat: .executive, person: "ผู้ใช้")])
    project.stage = stage
    return project
}

@Suite("Project reports")
struct ReportingTests {

    @Test("finishing a work package changes the next highlight report")
    func reportFollowsThePlan() {
        let project = project()
        var leaf = WorkPackage(projectID: project.id, title: "ตารางที่ 2",
                               scopeRef: "ความชุก", acceptanceCriteria: done,
                               raci: RACI(accountable: .teamLead))
        leaf.status = .inProgress

        let before = ReportBuilder.build(.highlight,
                                         from: ReportInputs(project: project,
                                                            wbs: WorkBreakdown([leaf])))
        #expect(before.rendered.contains("in progress"))
        #expect(!before.rendered.contains("α = 0.74"))

        leaf.status = .done
        leaf.evidence = [Evidence(kind: .statisticalCheck, summary: "α = 0.74", passed: true)]
        let after = ReportBuilder.build(.highlight,
                                       from: ReportInputs(project: project,
                                                          wbs: WorkBreakdown([leaf])))
        // The same builder, the same project, one row changed — and the report
        // moved. Nothing here was written by hand or by a model.
        #expect(after.rendered.contains("α = 0.74"))
        #expect(after != before)
    }

    @Test("a highlight report reports new risks, not every risk ever raised")
    func onlyWhatIsNew() {
        let project = project()
        let old = RegisterEntry(projectID: project.id, title: "ตัวอย่างน้อย",
                                detail: .risk(probability: 3, impact: 3, response: .reduce),
                                origin: .agent(.analyst),
                                createdAt: Date(timeIntervalSince1970: 1_000))
        let new = RegisterEntry(projectID: project.id, title: "โรงพยาบาลที่สองถอนตัว",
                                detail: .issue(severity: 4, kind: .problem),
                                origin: .human("ผู้ใช้"),
                                createdAt: Date(timeIntervalSince1970: 3_000))

        let first = ReportBuilder.build(.highlight, from: ReportInputs(
            project: project, registers: [old, new]))
        #expect(first.rendered.contains("ตัวอย่างน้อย"))

        // With a previous report on record, "ใหม่" means since that report —
        // otherwise every fortnightly report repeats the whole register and
        // stops being read.
        let second = ReportBuilder.build(.highlight, from: ReportInputs(
            project: project, registers: [old, new],
            since: Date(timeIntervalSince1970: 2_000)))
        #expect(!second.rendered.contains("ตัวอย่างน้อย"))
        #expect(second.rendered.contains("โรงพยาบาลที่สองถอนตัว"))
    }

    @Test("a risk raised in the same second as the last report is still reported")
    func sameSecondIsStillNew() {
        // Found by driving it, not by a test: both timestamps pass through
        // ISO-8601 without fractional seconds on the way to the database, so
        // things that happened in the same second come back equal — and a strict
        // `>` meant a risk raised in that second was never reported at all.
        let project = project()
        let boundary = Date(timeIntervalSince1970: 5_000)
        let entry = RegisterEntry(projectID: project.id, title: "ทันวินาทีเดียวกัน",
                                  detail: .risk(probability: 2, impact: 2, response: .accept),
                                  origin: .agent(.analyst), createdAt: boundary)

        let report = ReportBuilder.build(.highlight, from: ReportInputs(
            project: project, registers: [entry], since: boundary))
        #expect(report.rendered.contains("ทันวินาทีเดียวกัน"))
    }

    @Test("what nobody measured is printed as unmeasured, not as zero")
    func unmeasuredStaysUnmeasured() {
        let project = project()
        let tolerances = ToleranceCheck.evaluate(project.tolerances, readings: ToleranceReadings())
        let report = ReportBuilder.build(.highlight, from: ReportInputs(
            project: project, tolerances: tolerances, measured: [.scope]))

        #expect(report.rendered.contains("not measured yet"))
        // Cost is not in `measured`, so the money line must not claim a number.
        #expect(report.rendered.contains("Spending: not connected to the ledger yet"))
        // And the provenance line, which is what makes the rest checkable.
        #expect(report.rendered.contains("No sentence in it was written by a model"))
    }

    @Test("an end-stage report shows the gate it is asking to pass")
    func endStageAsksForTheGate() throws {
        let project = project(.planning)
        let leaf = WorkPackage(projectID: project.id, title: "ตารางที่ 2",
                               scopeRef: "ความชุก", acceptanceCriteria: done,
                               raci: RACI(accountable: .teamLead))
        let wbs = WorkBreakdown([leaf])
        let gate = try #require(ProjectLifecycle.evaluate(project, wbs: wbs))
        let report = ReportBuilder.build(.endStage, from: ReportInputs(
            project: project, wbs: wbs, gate: gate))

        #expect(report.rendered.contains("G2"))
        // Every condition, with its state — the report is the request to move on,
        // so it has to carry what the decision rests on.
        #expect(report.rendered.contains("✓"))
        #expect(report.rendered.contains("No baseline yet"))
    }

    @Test("an end-project report hands over what is still open")
    func endProjectHandsOver() {
        var project = project(.closing)
        project.dataDisposition = DataDisposition(action: .archive, policy: "เก็บ 5 ปี",
                                                  decidedBy: "ผู้ใช้")
        let openIssue = RegisterEntry(projectID: project.id, title: "รอผู้ตรวจตอบ",
                                      detail: .issue(severity: 2, kind: .concern),
                                      origin: .human("ผู้ใช้"),
                                      owner: .human("หัวหน้าภาค"))
        let lesson = RegisterEntry(projectID: project.id, title: "ขอฉบับเต็มตั้งแต่ต้น",
                                   detail: .lesson(cause: "ภาคผนวกไม่ตีพิมพ์",
                                                   doDifferently: "ขอจากผู้แปล",
                                                   appliesTo: "มาตรวัดแปล"),
                                   origin: .agent(.researcher))
        let later = Benefit(projectID: project.id, title: "เวลาสรุปแบบสอบถาม",
                            measure: "ชั่วโมง", baselineValue: 6, target: 2,
                            reviewAt: Date(timeIntervalSince1970: 9_000_000),
                            owner: .human("ผู้ใช้"))

        let report = ReportBuilder.build(.endProject, from: ReportInputs(
            project: project, registers: [openIssue, lesson],
            benefits: BenefitLedger([later])))

        #expect(report.rendered.contains("รอผู้ตรวจตอบ"))
        #expect(report.rendered.contains("หัวหน้าภาค"))
        // The most commonly dropped handover item there is: a benefit whose
        // review date is after the project ends.
        #expect(report.rendered.contains("Still to be measured: เวลาสรุปแบบสอบถาม"))
        #expect(report.rendered.contains("moved to the archive"))
        #expect(report.rendered.contains("ขอจากผู้แปล"))
    }

    @Test("a section with nothing in it says so rather than reading as fine")
    func emptySectionsAreHonest() {
        let report = ReportBuilder.build(.highlight, from: ReportInputs(project: project()))
        #expect(report.rendered.contains("nothing recorded"))
    }

    @Test("issuing a report keeps it, and makes reporting a practice with evidence")
    func issuingIsRecorded() async throws {
        let reports = MemoryReportStore()
        let service = ProjectService(store: MemoryProjectStore(), plans: MemoryPlanStore(),
                                     registers: MemoryRegisterStore(),
                                     benefits: MemoryBenefitStore(),
                                     tailoring: MemoryTailoringStore(),
                                     reports: reports)
        let created = try await service.create(name: "ออกรายงาน")

        // Before: nothing has been reported, so the practice has no evidence and
        // the only honest way to close over it is a tailoring record.
        #expect(Conformance.evidence(for: .reporting,
                                     in: await service.conformanceFacts(of: created.id)) == nil)

        let first = try #require(try await service.issueReport(.highlight, for: created.id))
        #expect(first.title.contains("report"))
        #expect(Conformance.evidence(for: .reporting,
                                     in: await service.conformanceFacts(of: created.id)) != nil)

        // The second one knows when the first was written, which is what makes
        // "new since last time" mean anything.
        let second = try #require(try await service.issueReport(
            .highlight, for: created.id, now: Date(timeIntervalSinceNow: 60)))
        #expect(second.id != first.id)
        #expect(await service.reportHistory(of: created.id).count == 2)
        // Newest first, so the screen and the "since" lookup agree.
        #expect(await service.reportHistory(of: created.id).first?.id == second.id)
    }

    @Test("the report reads the same numbers the status strip does")
    func oneSetOfNumbers() async throws {
        let service = ProjectService(store: MemoryProjectStore(), plans: MemoryPlanStore(),
                                     registers: MemoryRegisterStore(),
                                     reports: MemoryReportStore())
        let created = try await service.create(name: "ตัวเลขชุดเดียว")
        var readings = ToleranceReadings()
        readings.spent = 240
        await service.observe(ObservedFacts(readings: readings, measured: [.cost, .scope],
                                            measuredSeconds: 1_800))

        let report = try #require(try await service.issueReport(.highlight, for: created.id))
        #expect(report.rendered.contains("$240"))
        #expect(report.rendered.contains("30 minutes"))
        // Time is not in `measured`, but elapsed seconds are a count of spans
        // rather than a ratio — the ratio is what needs history, and the report
        // says minutes because that is what was actually recorded.
        #expect(report.rendered.contains("Time: 1.5 / 1.50") == false)
    }
}
