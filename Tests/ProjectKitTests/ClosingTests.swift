import Testing
import Foundation
import AgentKit
@testable import ProjectKit

// ─────────────────────────────────────────────────────────────
// Benefits, the closing gate, and conformance (§19.12, §19.15–§19.16,
// P10.10/P10.13).
//
// The Done-when for the gate is "ปิดโปรเจกต์ที่ยังมีรายการค้างข้อใดข้อหนึ่งใน
// 8 ข้อ ไม่ได้ — ทดสอบครบทั้ง 8 กรณี", so that is what `eachOfTheEight` does:
// one project that satisfies all eight, then eight copies with exactly one thing
// wrong. Testing them one at a time is the point — a gate tested only against
// "everything missing" passes while checking a single condition.
//
// Two conditions are also tested in their *unchecked* state, which is a
// different failure from being violated: a store nobody wired must not read as
// a clean bill of health (the rule the stage gate already uses for a project it
// cannot see).
// ─────────────────────────────────────────────────────────────

actor MemoryBenefitStore: BenefitPersisting {
    private var rows: [String: Benefit] = [:]
    func save(_ benefit: Benefit) async throws { rows[benefit.id] = benefit }
    func all(project: ProjectID) async throws -> [Benefit] {
        rows.values.filter { $0.projectID == project }
    }
    func delete(_ id: String, project: ProjectID) async throws { rows.removeValue(forKey: id) }
}

actor MemoryTailoringStore: TailoringPersisting {
    private(set) var rows: [TailoringRecord] = []
    func save(_ record: TailoringRecord) async throws { rows.append(record) }
    func all(project: ProjectID) async throws -> [TailoringRecord] {
        rows.filter { $0.projectID == project }
    }
}

/// A ledger with nothing outstanding, and one with something in each half.
struct StubClosingLedger: ClosingLedgerReading {
    let conflicts: Int
    let assumptions: Int
    func openConflictCount(scope: Scope) async -> Int { conflicts }
    func unconfirmedAssumptionCount(scope: Scope) async -> Int { assumptions }
}

private let criteria = [Criterion(text: "ตรวจได้", evidenceRequired: "exit 0")]

/// A project sitting at the closing gate with every one of the eight satisfied.
private func closingProject() -> Project {
    var project = Project(
        name: "ความเครียดพยาบาล",
        kind: .research,
        brief: "วัดความชุกของภาวะหมดไฟ",
        statement: ScopeStatement(inScope: ["ความชุกในพยาบาลวิชาชีพ"],
                                  outOfScope: ["เปรียบเทียบข้ามวิชาชีพ"]),
        board: [BoardRole(seat: .executive, person: "ผู้ใช้")])
    project.stage = .closing
    project.dataDisposition = DataDisposition(
        action: .archive, policy: "เก็บข้อมูลดิบ 5 ปีตามระเบียบคณะ", decidedBy: "ผู้ใช้")
    return project
}

/// A delivered leaf with evidence QA accepted.
private func deliveredLeaf(_ project: Project) -> WorkPackage {
    var leaf = WorkPackage(projectID: project.id, title: "ตารางที่ 2",
                           scopeRef: project.statement.inScope[0],
                           acceptanceCriteria: criteria,
                           raci: RACI(accountable: .teamLead),
                           evidence: [Evidence(kind: .statisticalCheck,
                                               summary: "α = 0.74", passed: true)])
    leaf.status = .done
    return leaf
}

private func facts() -> ClosingFacts {
    ClosingFacts(openRegisterEntries: 0, openConflicts: 0, pendingAssumptions: 0,
                 conformanceGaps: [], dataDisposition: closingProject().dataDisposition)
}

/// Everything a fully-run project would have. Used to prove the conformance
/// switch has a real answer for all seventeen practices.
private func fullFacts() -> ConformanceFacts {
    ConformanceFacts(leafCount: 3, benefitCount: 1, inScopeCount: 2, outOfScopeCount: 1,
                     staffedLeaves: 3, dependencyCount: 2, measuredSeconds: 3_600,
                     spent: 120, riskCount: 1, issueCount: 1, changeCount: 1,
                     decisionCount: 1, lessonCount: 1, baselineVersions: 2,
                     evidenceCount: 3, boardSeats: 1, messagesSent: 2, reportsIssued: 1,
                     dataDispositionDecided: true, procurementRecorded: true,
                     orgChangeRecorded: true)
}

@Suite("Closing gate and benefits")
struct ClosingTests {

    @Test("all eight satisfied opens G4")
    func eightSatisfiedPasses() throws {
        let project = closingProject()
        let gate = try #require(ProjectLifecycle.evaluate(
            project, wbs: WorkBreakdown([deliveredLeaf(project)]),
            hasLessons: true, closing: facts()))

        #expect(gate.gate == "G4")
        #expect(gate.conditions.count == 8)
        #expect(gate.passed, "ค้าง: \(gate.unmet)")
    }

    @Test("each of the eight conditions blocks closing on its own")
    func eachOfTheEight() throws {
        let project = closingProject()
        let delivered = deliveredLeaf(project)

        // 1 — a work package still open.
        var open = delivered
        open.status = .inProgress
        expectBlocked(project, wbs: WorkBreakdown([open]), closing: facts(),
                      because: "No unfinished work package")

        // 2 — delivered, but QA never accepted anything. Evidence that *failed*
        // is not the same as evidence, which is the whole reason the condition
        // reads `passed` rather than counting the array.
        var rejected = delivered
        rejected.evidence = [Evidence(kind: .commandExit, summary: "exit 1", passed: false)]
        expectBlocked(project, wbs: WorkBreakdown([rejected]), closing: facts(),
                      because: "Every finished package has evidence QA accepted")

        // 3 — a risk, issue or change still open.
        var stillOpen = facts()
        stillOpen.openRegisterEntries = 1
        expectBlocked(project, wbs: WorkBreakdown([delivered]), closing: stillOpen,
                      because: "No open risk, issue or change request")

        // 4 — a contradiction nobody resolved.
        var conflicted = facts()
        conflicted.openConflicts = 2
        expectBlocked(project, wbs: WorkBreakdown([delivered]), closing: conflicted,
                      because: "No conflict left open in the knowledge base")

        // 5 — an assumption the agent made and nobody confirmed.
        var guessed = facts()
        guessed.pendingAssumptions = 1
        expectBlocked(project, wbs: WorkBreakdown([delivered]), closing: guessed,
                      because: "No assumption an agent guessed is still unconfirmed")

        // 6 — a practice with neither a real thing nor a record of skipping it.
        var incomplete = facts()
        incomplete.conformanceGaps = [.procurement, .orgChange]
        let sixth = try #require(ProjectLifecycle.evaluate(
            project, wbs: WorkBreakdown([delivered]), hasLessons: true, closing: incomplete))
        #expect(!sixth.passed)
        // Named, not counted: "conformance ไม่ผ่าน" sends somebody hunting
        // through seventeen rows for the two that are empty.
        #expect(sixth.unmet.contains { $0.contains("Procurement") })

        // 7 — nothing learned, or nothing written down, which are the same thing
        // by the time the next project searches for it.
        expectBlocked(project, wbs: WorkBreakdown([delivered]), hasLessons: false,
                      closing: facts(),
                      because: "At least one lesson recorded (it flows into the shared base at closing)")

        // 8 — nobody decided what happens to the data.
        var undecided = facts()
        undecided.dataDisposition = nil
        expectBlocked(project, wbs: WorkBreakdown([delivered]), closing: undecided,
                      because: "It has been decided where the remaining data and files go")
    }

    @Test("a condition nobody could check does not read as satisfied")
    func uncheckedIsNotClean() throws {
        let project = closingProject()
        let wbs = WorkBreakdown([deliveredLeaf(project)])

        // Default `ClosingFacts` is what a service with no conflict ledger, no
        // analysis plans and no conformance pass produces. Four of the eight are
        // then unknown — and unknown has to fail, or wiring half the gate would
        // quietly turn it into a four-condition gate.
        let unwired = try #require(ProjectLifecycle.evaluate(
            project, wbs: wbs, hasLessons: true, closing: ClosingFacts()))
        #expect(!unwired.passed)
        #expect(unwired.unmet.count == 4)
        // Three of them say why they could not be answered, in the text a person
        // reads — "ค้าง: ไม่มีข้อขัดแย้งค้าง" would read as the opposite of what
        // happened, which is that nobody looked.
        #expect(unwired.unmet.count { $0.contains("cannot be checked") || $0.contains("not checked yet") } == 3)
        #expect(unwired.unmet.contains("It has been decided where the remaining data and files go"))
    }

    @Test("a disposition with no policy or nobody attached does not count")
    func dispositionNeedsBothHalves() throws {
        let project = closingProject()
        let wbs = WorkBreakdown([deliveredLeaf(project)])
        for partial in [DataDisposition(action: .delete, policy: "", decidedBy: "ผู้ใช้"),
                        DataDisposition(action: .delete, policy: "ลบใน 30 วัน", decidedBy: " ")] {
            var half = facts()
            half.dataDisposition = partial
            let gate = try #require(ProjectLifecycle.evaluate(
                project, wbs: wbs, hasLessons: true, closing: half))
            #expect(!gate.passed)
        }
    }

    // MARK: - conformance (§19.16, P10.13)

    @Test("all seventeen practices have an answer, and none is answered by default")
    func seventeenPractices() {
        #expect(Practice.allCases.count == 17)
        // With nothing in the project, every practice is a gap — no practice
        // gets a free pass from a fact nobody recorded.
        #expect(Conformance.gaps(ConformanceFacts()).count == 17)
        // With everything, every practice has evidence. This is the half that
        // catches a case wired to a fact that can never be true: a `switch` arm
        // returning `nil` unconditionally would compile and pass exhaustively.
        let full = Conformance.evaluate(fullFacts())
        #expect(full.allSatisfy { $0.evidence != nil })
        #expect(full.map(\.practice) == Practice.allCases)
    }

    @Test("schedule counts dependencies or measured time, and nothing else")
    func scheduleHasTwoWaysToBeReal() {
        var sequenced = ConformanceFacts()
        sequenced.dependencyCount = 1
        #expect(Conformance.evidence(for: .schedule, in: sequenced) != nil)

        // A one-package project has nothing to sequence but is still timed.
        var timed = ConformanceFacts()
        timed.measuredSeconds = 600
        #expect(Conformance.evidence(for: .schedule, in: timed) != nil)
        #expect(Conformance.evidence(for: .schedule, in: ConformanceFacts()) == nil)
    }

    @Test("a tailoring record closes the gap and still reads as tailored")
    func tailoringIsVisiblyDifferent() throws {
        let id = ProjectID("pj_conf")
        let record = try TailoringRecord.decided(
            projectID: id, practice: .procurement,
            reason: "โครงการนี้ไม่จัดซื้ออะไรเลย", by: "ผู้ใช้")

        let rows = Conformance.evaluate(ConformanceFacts(), tailoring: [record])
        let procurement = try #require(rows.first { $0.practice == .procurement })
        #expect(procurement.satisfied)
        // Seventeen ticks where sixteen are tailoring records is not a strong
        // conformance claim, and the screen has to be able to say so.
        #expect(procurement.isTailored)
        #expect(Conformance.gaps(ConformanceFacts(), tailoring: [record]).count == 16)
    }

    @Test("tailoring needs both a reason and a person")
    func tailoringRefusesBlanks() {
        let id = ProjectID("pj_conf")
        #expect(throws: TailoringError.emptyDecider) {
            try TailoringRecord.decided(projectID: id, practice: .cost,
                                        reason: "ไม่มีค่าใช้จ่าย", by: "  ")
        }
        #expect(throws: TailoringError.emptyReason) {
            try TailoringRecord.decided(projectID: id, practice: .cost,
                                        reason: "", by: "ผู้ใช้")
        }
    }

    @Test("the newest tailoring decision is the one in force")
    func newestTailoringWins() throws {
        let id = ProjectID("pj_conf")
        let old = try TailoringRecord.decided(projectID: id, practice: .procurement,
                                             reason: "ยังไม่ตัดสิน", by: "ก",
                                             at: Date(timeIntervalSince1970: 1_000))
        let new = try TailoringRecord.decided(projectID: id, practice: .procurement,
                                              reason: "ไม่จัดซื้อ", by: "ข",
                                              at: Date(timeIntervalSince1970: 2_000))
        let rows = Conformance.evaluate(ConformanceFacts(), tailoring: [old, new])
        #expect(rows.first { $0.practice == .procurement }?.tailoring?.decidedBy == "ข")
    }

    // MARK: - benefits (§19.12, P10.10)

    @Test("a benefit that improves downwards is measured in the right direction")
    func downwardBenefitsCountUp() {
        // Four hours a month down to one, measured at two: two thirds of the way.
        let benefit = Benefit(projectID: ProjectID("pj_b"), title: "เวลาทำรายงาน",
                              measure: "ชั่วโมงต่อเดือน", baselineValue: 4, target: 1,
                              reviewAt: Date(), owner: .human("ผู้ใช้"),
                              result: BenefitMeasurement(value: 2, measuredBy: "ผู้ใช้"))
        let achieved = benefit.achievement ?? 0
        #expect(abs(achieved - 2.0 / 3.0) < 0.001)

        // The naive `value / target` would call this 200% of target while the
        // number got worse — half of all real benefits are improvements
        // downwards, so this is not an edge case.
        var worse = benefit
        worse.result = BenefitMeasurement(value: 5, measuredBy: "ผู้ใช้")
        #expect((worse.achievement ?? 0) < 0)
    }

    @Test("an unmeasured benefit has no number, and the ledger says so")
    func unmeasuredIsNotZero() {
        let benefit = Benefit(projectID: ProjectID("pj_b"), title: "ความพึงพอใจ",
                              measure: "คะแนน 1–5", baselineValue: 3, target: 4,
                              reviewAt: Date(timeIntervalSince1970: 0),
                              owner: .human("ผู้ใช้"))
        #expect(benefit.achievement == nil)
        #expect(benefit.isDue())
        // A business case that looks healthy because nobody checked is the
        // failure §19.12 exists for, so the ledger returns nothing rather than 1.
        #expect(BenefitLedger([benefit]).lowestAchievement == nil)
        #expect(BenefitLedger([benefit]).due().count == 1)
    }

    @Test("the ledger reports the worst measured benefit")
    func lowestOfTheMeasured() {
        let base = Benefit(projectID: ProjectID("pj_b"), title: "ก", measure: "หน่วย",
                           baselineValue: 0, target: 10, reviewAt: Date(),
                           owner: .agent(.teamLead))
        var good = base
        good.result = BenefitMeasurement(value: 10, measuredBy: "ผู้ใช้")
        var poor = base
        poor.result = BenefitMeasurement(value: 3, measuredBy: "ผู้ใช้")
        #expect(BenefitLedger([good, poor]).lowestAchievement == 0.3)
    }

    @Test("a measurement needs a name, and works after the project is closed")
    func postProjectReview() async throws {
        let store = MemoryBenefitStore()
        let service = ProjectService(store: MemoryProjectStore(), plans: MemoryPlanStore(),
                                    registers: MemoryRegisterStore(), benefits: store)
        let project = try await service.create(name: "ปิดแล้วแต่ยังต้องวัด")
        let benefit = Benefit(projectID: project.id, title: "ต้นทุนต่อเคส",
                              measure: "บาทต่อเคส", baselineValue: 100, target: 80,
                              reviewAt: Date(), owner: .human("ผู้ใช้"))
        try await service.save(benefit)
        _ = try await service.terminate(project.id, reason: "จบรอบ")

        await #expect(throws: BenefitError.emptyMeasurer) {
            try await service.measure(benefit, value: 90, by: "   ")
        }
        // §19.12's post-project review: the date that matters is usually months
        // after closing, and requiring a reopened project to record it means the
        // review never happens.
        try await service.measure(benefit, value: 90, by: "ผู้ใช้", note: "ไตรมาสถัดมา")
        let ledger = await service.benefitLedger(of: project.id)
        #expect(ledger.lowestAchievement == 0.5)
    }

    @Test("the benefit tolerance reads the ledger, not the caller")
    func benefitBreachComesFromTheLedger() async throws {
        let exceptions = MemoryExceptionStore()
        let service = ProjectService(store: MemoryProjectStore(), plans: MemoryPlanStore(),
                                    exceptions: exceptions,
                                    registers: MemoryRegisterStore(),
                                    benefits: MemoryBenefitStore())
        var project = try await service.create(name: "คุ้มไหม")
        project.tolerances = Tolerances(limits: [.benefit: 0.8])
        try await service.update(project)

        // Nothing measured yet: the frame is set, and nothing has left it —
        // the ledger has no number to report, so no exception is raised.
        #expect(try await service.raiseBreaches(for: project.id,
                                               readings: ToleranceReadings()).isEmpty)

        var benefit = Benefit(projectID: project.id, title: "ครึ่งทาง", measure: "หน่วย",
                              baselineValue: 0, target: 10, reviewAt: Date(),
                              owner: .human("ผู้ใช้"))
        benefit.result = BenefitMeasurement(value: 5, measuredBy: "ผู้ใช้")
        try await service.save(benefit)

        // 0.5 against a floor of 0.8. The caller passes a default reading of
        // 1.0 and is overruled, which is the point: the screen must not be able
        // to talk the business case up by not looking at the ledger.
        let raised = try await service.raiseBreaches(for: project.id,
                                                     readings: ToleranceReadings())
        #expect(raised.map(\.dimension) == [.benefit])
        #expect(await service.hasOpenException(project.id))
    }

    // MARK: - the gate as the service assembles it

    @Test("the service reads all eight from its own stores")
    func serviceAssemblesTheEight() async throws {
        let plans = MemoryPlanStore()
        let registers = MemoryRegisterStore()
        let tailoring = MemoryTailoringStore()
        let service = ProjectService(store: MemoryProjectStore(), plans: plans,
                                     exceptions: MemoryExceptionStore(),
                                     registers: registers,
                                     baselines: MemoryBaselineStore(),
                                     benefits: MemoryBenefitStore(),
                                     tailoring: tailoring,
                                     closingLedger: StubClosingLedger(conflicts: 0,
                                                                      assumptions: 0))
        var project = try await service.create(
            name: "ขับผ่าน service",
            brief: "ทดสอบว่าเงื่อนไขมาจาก store จริง",
            statement: ScopeStatement(inScope: ["ก"], outOfScope: ["ข"],
                                      acceptanceCriteria: ["ตรวจได้"]),
            board: [BoardRole(seat: .executive, person: "ผู้ใช้")])
        project.stage = .closing
        project.dataDisposition = DataDisposition(action: .keep, policy: "เก็บ 1 ปี",
                                                  decidedBy: "ผู้ใช้")
        try await service.update(project)

        try await service.save(deliveredLeaf(project))
        try await service.record(RegisterEntry(
            projectID: project.id, title: "ฉบับแปลไม่รายงาน α",
            detail: .lesson(cause: "ไม่ตีพิมพ์ภาคผนวก", doDifferently: "ขอฉบับเต็ม",
                            appliesTo: "มาตรวัดแปล"),
            origin: .human("ผู้ใช้")))

        // Conformance is the condition that is still short, and it names which
        // practices — so the person is told what to do, not that something is
        // wrong somewhere.
        let before = try #require(await service.gate(for: project.id))
        #expect(!before.passed)
        #expect(before.unmet.count == 1)

        for practice in await service.conformance(of: project.id)
        where !practice.satisfied {
            try await service.tailor(practice.practice, in: project.id,
                                     reason: "ไม่เกี่ยวกับโครงการนี้", by: "ผู้ใช้")
        }
        let after = try #require(await service.gate(for: project.id))
        #expect(after.passed, "ยังค้าง: \(after.unmet)")

        let closed = try await service.advance(project.id)
        #expect(closed.stage == .closed)
        #expect(closed.closure == .completed)
    }

    @Test("an open register entry blocks closing through the service too")
    func serviceSeesOpenRegisters() async throws {
        let service = ProjectService(store: MemoryProjectStore(), plans: MemoryPlanStore(),
                                     registers: MemoryRegisterStore(),
                                     benefits: MemoryBenefitStore(),
                                     tailoring: MemoryTailoringStore(),
                                     closingLedger: StubClosingLedger(conflicts: 0,
                                                                      assumptions: 0))
        var project = try await service.create(name: "มีปัญหาค้าง")
        project.stage = .closing
        project.dataDisposition = DataDisposition(action: .keep, policy: "เก็บ",
                                                  decidedBy: "ผู้ใช้")
        try await service.update(project)
        try await service.record(RegisterEntry(
            projectID: project.id, title: "ยังไม่ได้ตอบผู้ตรวจ",
            detail: .issue(severity: 3, kind: .problem), origin: .human("ผู้ใช้")))

        let gate = try #require(await service.gate(for: project.id))
        #expect(gate.unmet.contains("No open risk, issue or change request"))
    }
}

/// One flipped condition, asserted the same way eight times.
private func expectBlocked(_ project: Project,
                           wbs: WorkBreakdown,
                           hasLessons: Bool = true,
                           closing: ClosingFacts,
                           because condition: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
    guard let gate = ProjectLifecycle.evaluate(project, wbs: wbs, hasLessons: hasLessons,
                                               closing: closing) else {
        Issue.record("ไม่มี gate ให้ตรวจ", sourceLocation: sourceLocation)
        return
    }
    #expect(!gate.passed, sourceLocation: sourceLocation)
    #expect(gate.unmet == [condition], "ค้างไม่ตรงกับที่ตั้งใจ: \(gate.unmet)",
            sourceLocation: sourceLocation)
}
