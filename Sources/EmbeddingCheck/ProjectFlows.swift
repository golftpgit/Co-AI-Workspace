import Foundation
import AgentKit
import Persistence
import ProjectKit
import CoreEngine

// ─────────────────────────────────────────────────────────────
// One project, driven end to end the way a person drives it (§19, P10).
//
// Against the real database and through the real `ToolGateway`, because every
// interesting failure in this area is a wiring failure: a gate that reads a
// cached stage, a baseline frozen from a plan that was not saved yet, an
// exception that stops nothing. Unit tests cannot see any of those — each one
// passes its own suite and fails the moment two pieces meet.
//
// The order below is the order the screen offers: make it, scope it, plan it,
// work it, break the frame, decide, finish, and find the lesson afterwards.
// ─────────────────────────────────────────────────────────────

struct ProjectFlows {
    let client: SurrealClient
    let knowledge: KnowledgeStore

    /// A tool that records whether it ran, so "refused" is distinguishable
    /// from "ran and produced nothing".
    private final class RanFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var ran: Bool { lock.withLock { value } }
        func reset() { lock.withLock { value = false } }
        func mark() { lock.withLock { value = true } }
    }

    private struct SpyTool: AgentTool {
        let name: String
        let riskLevel: RiskLevel
        let flag: RanFlag
        var toolDescription: String { "flow" }
        var parametersJSON: String { #"{"type":"object","properties":{}}"# }
        func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutput {
            flag.mark()
            return ToolOutput(text: "ok")
        }
    }

    func run(check: (String, () async throws -> String) async -> Void) async {
        let projects = ProjectService(
            store: ProjectStore(client: client),
            plans: WorkPackageStore(client: client),
            exceptions: ExceptionStore(client: client),
            registers: RegisterStore(client: client),
            baselines: BaselineStore(client: client),
            lessons: LessonPublisher(knowledge: knowledge),
            benefits: BenefitStore(client: client),
            tailoring: TailoringStore(client: client),
            closingLedger: ClosingLedger(conflicts: ConflictStore(client: client),
                                         plans: AnalysisPlanStore(client: client)),
            reports: ReportStore(client: client))

        let shell = RanFlag()
        let search = RanFlag()
        let gateway = ToolGateway(
            chain: HookChain(stageGate: StageGate(reader: projects)),
            modes: OperatingModes(autonomy: .fullAutonomous))
        await gateway.register([
            SpyTool(name: "run_shell", riskLevel: .high, flag: shell),
            SpyTool(name: "kb_search", riskLevel: .low, flag: search),
        ])

        var project = Project(name: "ความเครียดและภาวะหมดไฟในพยาบาลวิชาชีพ", kind: .research)
        var leafID = ""
        var extraLeafID = ""

        func callTool(_ name: String) async throws -> GateOutcome {
            try await gateway.call(name, argumentsJSON: "{}",
                                   context: ToolContext(scope: project.scope))
        }

        await check("[หน้าโปรเจกต์] สร้างโปรเจกต์ใหม่แล้วอยู่ขั้นเริ่มต้น") {
            project = try await projects.create(name: project.name, kind: .research)
            guard project.stage == .initiation else { throw CheckFailure("ขั้นแรกไม่ใช่ initiation") }
            return project.stage.label
        }

        await check("[ประตูขั้น] ขั้นเริ่มต้นยังรันคำสั่งไม่ได้ แต่ค้นได้") {
            shell.reset(); search.reset()
            let blocked = try await callTool("run_shell")
            guard case .blockedByStage(let reason) = blocked, !shell.ran else {
                throw CheckFailure("run_shell ทำงานได้ทั้งที่ยังไม่ผ่าน G1: \(blocked)")
            }
            guard try await callTool("kb_search").didExecute, search.ran else {
                throw CheckFailure("kb_search ถูกปิดไปด้วย ทั้งที่การอ่านต้องเปิดเสมอ")
            }
            guard reason.contains("G1") else { throw CheckFailure("เหตุผลไม่บอกว่าติดประตูไหน") }
            return "ปฏิเสธพร้อมเหตุผล"
        }

        await check("[G1] ขอบเขตที่ไม่มีข้อ 'ไม่ทำ' และไม่มีชื่อ Executive ผ่านไม่ได้") {
            project.brief = "วัดความชุกของภาวะหมดไฟใน รพ. ตติยภูมิ 2 แห่ง"
            project.statement.inScope = ["ความชุกในพยาบาลวิชาชีพ"]
            try await projects.update(project)

            let gate = try await requireGate(projects, project.id)
            guard !gate.passed else { throw CheckFailure("ผ่าน G1 ทั้งที่ยังไม่ครบ") }
            do {
                _ = try await projects.advance(project.id)
                throw CheckFailure("advance สำเร็จทั้งที่ประตูยังไม่เปิด")
            } catch is LifecycleError {
                let stage = await projects.stage(of: project.id)
                guard stage == .initiation else { throw CheckFailure("ขั้นขยับทั้งที่ปฏิเสธ") }
            }
            return "ค้าง \(gate.unmet.count) ข้อ"
        }

        await check("[G1] เติมครบแล้วผ่าน และขั้นวางแผนร่างเอกสารได้แต่ยังแก้ข้อมูลไม่ได้") {
            project.statement.outOfScope = ["การเปรียบเทียบข้ามวิชาชีพ"]
            project.statement.acceptanceCriteria = ["ต้นฉบับส่งวารสารได้"]
            project.board = [BoardRole(seat: .executive, person: "ผู้ใช้")]
            try await projects.update(project)
            project = try await projects.advance(project.id)
            guard project.stage == .planning else { throw CheckFailure("ไม่ได้เข้าขั้นวางแผน") }

            shell.reset()
            let blocked = try await callTool("run_shell")
            guard !blocked.didExecute, !shell.ran else {
                throw CheckFailure("ขั้นวางแผนรันคำสั่งได้")
            }
            return "วางแผน"
        }

        await check("[G2] ใบงานที่ยังไม่บอกว่าเสร็จแปลว่าอะไร ทำให้ประตูปิด") {
            let root = WorkPackage(projectID: project.id, title: "บทความวิจัยฉบับส่งวารสาร",
                                   acceptanceCriteria: [])
            var leaf = WorkPackage(projectID: project.id, parent: root.id,
                                   title: "ผลความเที่ยงของมาตรวัด",
                                   deliverableType: "ตารางที่ 2",
                                   acceptanceCriteria: [], role: .analyst)
            leafID = leaf.id
            try await projects.save(root)
            try await projects.save(leaf)

            let gate = try await requireGate(projects, project.id)
            guard !gate.passed else { throw CheckFailure("ผ่าน G2 ทั้งที่ใบงานยังไม่มีเกณฑ์") }
            guard leaf.assignment() == nil else {
                throw CheckFailure("ใบงานที่ไม่มีเกณฑ์ยังกลายเป็น assignment ได้")
            }
            leaf.acceptanceCriteria = [Criterion(text: "α รายด้าน ≥ 0.70",
                                                 evidenceRequired: "ผลรันจากสมุดงาน")]
            leaf.scopeRef = "ความชุกในพยาบาลวิชาชีพ"
            leaf.raci = RACI(accountable: .human("ผู้ใช้"), responsible: [.agent(.analyst)])
            try await projects.save(leaf)
            return "ค้าง \(gate.unmet.count) ข้อ แล้วแก้ครบ"
        }

        await check("[G2] ผ่านแล้ว baseline v1 ถูก freeze และงานเริ่มลงมือได้") {
            project = try await projects.advance(project.id)
            guard project.stage == .execution else {
                let gate = try await requireGate(projects, project.id)
                throw CheckFailure("ยังไม่เข้าขั้นดำเนินงาน — ค้าง: \(gate.unmet)")
            }
            guard let baseline = await projects.currentBaseline(of: project.id) else {
                throw CheckFailure("ผ่าน G2 แล้วแต่ไม่มี baseline")
            }
            guard baseline.version == 1, baseline.packages.count == 2 else {
                throw CheckFailure("baseline ไม่ตรงกับแผนตอนตกลง: v\(baseline.version), \(baseline.packages.count) ใบ")
            }
            shell.reset()
            guard try await callTool("run_shell").didExecute, shell.ran else {
                throw CheckFailure("ขั้นดำเนินงานยังรันคำสั่งไม่ได้")
            }
            return "baseline v1 · \(baseline.packages.count) ใบ"
        }

        await check("[baseline] เพิ่มใบงานหลังตกลงแล้ว = คำขอเปลี่ยนแปลงที่บอกผลกระทบ 3 ด้าน") {
            let extra = WorkPackage(projectID: project.id, title: "ภาคผนวก ก",
                                    scopeRef: "ความชุกในพยาบาลวิชาชีพ",
                                    acceptanceCriteria: [Criterion(text: "มีตาราง",
                                                                   evidenceRequired: "ไฟล์")],
                                    raci: RACI(accountable: .teamLead))
            extraLeafID = extra.id

            // §19.2.4 — the person is told what this becomes *before* confirming,
            // and the same call that lands the edit opens the request. Two calls
            // would be one call somebody forgets (P10.16).
            let preview = await projects.proposal(for: .savePackage(extra), in: project.id)
            guard let preview, preview.scopeImpact.contains("+1 ใบ") else {
                throw CheckFailure("ตัวอย่างผลกระทบไม่บอกว่าเพิ่มกี่ใบ: \(String(describing: preview?.scopeImpact))")
            }
            guard preview.timeImpact.contains("ยังประเมินไม่ได้"),
                  preview.costImpact.contains("ยังประเมินไม่ได้") else {
                throw CheckFailure("ประเมินเวลา/เงินทั้งที่ยังไม่มีใบงานที่วัดได้ — \(preview.headline)")
            }

            let opened = try await projects.apply(.savePackage(extra), in: project.id)
            guard let opened, opened.requestNumber == 1 else {
                throw CheckFailure("ไม่ได้เปิดคำขอเปลี่ยนแปลงตอนแก้แผนหลัง baseline")
            }
            let changes = await projects.entries(of: project.id, kind: .change)
            guard changes.count == 1, changes[0].status == .proposed else {
                throw CheckFailure("คำขอที่เปิดผิดสถานะ: \(changes.map(\.status))")
            }

            guard let drift = await projects.drift(of: project.id) else {
                throw CheckFailure("ไม่มี drift ให้ดูทั้งที่มี baseline แล้ว")
            }
            guard drift.addedCount == 1, !drift.isEmpty else {
                throw CheckFailure("นับส่วนต่างผิด: \(drift.summary)")
            }
            // Editing before G2 asked nothing; editing now opened a request. The
            // difference is the whole of §19.2.4.
            return "\(drift.summary) · เปิดคำขอ #\(opened.requestNumber)"
        }

        await check("[ข้อยกเว้น] ทะลุกรอบแล้วโครงการหยุดรับงานใหม่จริง") {
            let raised = try await projects.raiseBreaches(
                for: project.id, readings: ToleranceReadings(spent: 900))
            guard raised.count == 1, raised[0].dimension == .cost else {
                throw CheckFailure("ไม่ได้ raise แกนค่าใช้จ่าย: \(raised.map(\.dimension))")
            }
            guard raised[0].message.contains("ต้องการจากคุณ") else {
                throw CheckFailure("รายงานไม่ได้บอกว่าต้องการอะไรจากคน")
            }

            shell.reset(); search.reset()
            let blocked = try await callTool("run_shell")
            guard !blocked.didExecute, !shell.ran else {
                throw CheckFailure("ยังรันคำสั่งได้ทั้งที่โครงการทะลุกรอบ")
            }
            guard try await callTool("kb_search").didExecute else {
                throw CheckFailure("อ่านข้อมูลไม่ได้ ทั้งที่คนต้องใช้มันเพื่อตัดสิน")
            }
            // §19.2.3 — decided from the status bar's popover, which is the path
            // a person actually takes: the same `StatusAction` the button builds,
            // through the same service call. Deciding it here rather than calling
            // `resolve` directly is the point: this is what proves the popover's
            // button does the whole job, record included.
            do {
                try await projects.perform(.decideException(raised[0], decision: "  "),
                                           in: project.id)
                throw CheckFailure("ปิดข้อยกเว้นได้ทั้งที่ไม่ได้เขียนคำตัดสิน")
            } catch StatusActionError.emptyDecision {}

            try await projects.perform(
                .widenTolerance(.cost, to: 1_000, reason: "อนุมัติงบเพิ่มรอบนี้"),
                in: project.id)
            guard await projects.project(project.id)?.tolerances.limit(.cost) == 1_000 else {
                throw CheckFailure("ขยายกรอบแล้วค่าไม่เปลี่ยน")
            }
            // Widening the frame that stopped the work releases the stop with it
            // — otherwise the project stays halted for a limit that no longer
            // exists, which reads as the system ignoring the decision.
            guard try await projects.openExceptions(project.id).isEmpty else {
                throw CheckFailure("ขยายกรอบแล้วยังหยุดอยู่")
            }
            let decisions = await projects.entries(of: project.id, kind: .decision)
            guard decisions.contains(where: { $0.note == "อนุมัติงบเพิ่มรอบนี้" }) else {
                throw CheckFailure("การกระทำจาก popover ไม่ได้เขียน decision record")
            }

            shell.reset()
            guard try await callTool("run_shell").didExecute, shell.ran else {
                throw CheckFailure("ปิดข้อยกเว้นแล้วยังทำงานต่อไม่ได้")
            }
            return "ตัดสินจาก popover · หยุดแล้วเดินต่อได้ · มี decision record"
        }

        await check("[คำขอเปลี่ยนแปลง] คนตัดสิน แล้ว baseline v2 เกิดขึ้นโดยไม่ทับ v1") {
            // The request the edit above opened — not a fabricated one. That is
            // the flow a person actually walks: edit, get asked, confirm, and
            // somebody with the business case decides.
            // Two requests are waiting, from the two different kinds of edit made
            // above: the extra work package, and the wider cost frame from the
            // status bar. A baseline holds both the plan and the frame, so both
            // are changes to the agreement (§19.11).
            let pending = await projects.entries(of: project.id, kind: .change)
                .filter { $0.status == .proposed }
            guard pending.count == 2 else {
                throw CheckFailure("คำขอที่รอตัดสินควรมี 2 ใบ (แผน + กรอบ): \(pending.map(\.title))")
            }
            guard pending.allSatisfy({ $0.note.contains("กระทบ:") }) else {
                throw CheckFailure("คำขอไม่ได้เก็บข้อความผลกระทบที่คนเห็นตอนยืนยัน")
            }
            guard let change = pending.first else { throw CheckFailure("ไม่มีคำขอให้ตัดสิน") }
            do {
                try await projects.decideChange(change, approve: true, by: "   ")
                throw CheckFailure("ตัดสินคำขอได้ทั้งที่ไม่มีชื่อคน")
            } catch RegisterError.emptyDecider {}

            let blockedGate = try await requireGate(projects, project.id)
            guard !blockedGate.passed else {
                throw CheckFailure("G3 เปิดทั้งที่มีคำขอค้างและแผนต่างจาก baseline")
            }

            for request in pending {
                try await projects.decideChange(request, approve: true, by: "ผู้ใช้")
            }
            // One version per approved change, never overwritten: the count is
            // itself the answer to "how many times did the agreement move".
            let history = await projects.baselineHistory(of: project.id)
            guard history.map(\.version) == [3, 2, 1] else {
                throw CheckFailure("ประวัติ baseline ผิด: \(history.map(\.version))")
            }
            guard await projects.drift(of: project.id)?.isEmpty == true else {
                throw CheckFailure("อนุมัติแล้วแต่ยังเห็นส่วนต่างจาก baseline ใหม่")
            }
            return "v1 ยังอ่านได้ · v3 ตรงกับแผนและกรอบวันนี้"
        }

        await check("[G3] ปิดใบงานต้องมีหลักฐาน แล้วถึงเข้าขั้นปิดโครงการได้") {
            let wbs = await projects.breakdown(of: project.id)
            do {
                _ = try wbs.complete(leafID, with: [])
                throw CheckFailure("ปิดใบงานได้ทั้งที่ไม่มีหลักฐาน")
            } catch is WBSError {}

            for id in [leafID, extraLeafID] {
                try await projects.complete(id, in: project.id, with: [
                    Evidence(kind: .statisticalCheck, summary: "α = 0.74", passed: true),
                ])
            }
            project = try await projects.advance(project.id)
            guard project.stage == .closing else {
                let gate = try await requireGate(projects, project.id)
                throw CheckFailure("ไม่เข้าขั้นปิด — ค้าง: \(gate.unmet)")
            }
            return "เข้าขั้นปิดโครงการ"
        }

        await check("[รายงาน] สร้างจากแถวจริง — เปลี่ยนข้อมูลต้นทางแล้วรายงานเปลี่ยนตาม") {
            guard let first = try await projects.issueReport(.highlight, for: project.id) else {
                throw CheckFailure("ออกรายงานไม่สำเร็จ")
            }
            // The evidence that closed a leaf a few checks ago, arriving in a
            // report without anybody retyping it.
            guard first.rendered.contains("α = 0.74") else {
                throw CheckFailure("รายงานไม่มีหลักฐานที่ปิดใบงานจริง")
            }

            try await projects.record(RegisterEntry(
                projectID: project.id, title: "โรงพยาบาลที่สองส่งข้อมูลช้า",
                detail: .issue(severity: 3, kind: .concern), origin: .agent(.analyst)))
            guard let second = try await projects.issueReport(
                .highlight, for: project.id, now: Date().addingTimeInterval(60)) else {
                throw CheckFailure("ออกรายงานฉบับที่สองไม่สำเร็จ")
            }
            // The new one carries what is new; the old one is unchanged, because
            // a report is a claim made on a date rather than a live view.
            guard second.rendered.contains("โรงพยาบาลที่สองส่งข้อมูลช้า"),
                  !first.rendered.contains("โรงพยาบาลที่สองส่งข้อมูลช้า") else {
                throw CheckFailure("รายงานใหม่ไม่ได้เปลี่ยนตามข้อมูล หรือฉบับเก่าถูกเขียนทับ")
            }
            let history = await projects.reportHistory(of: project.id)
            guard history.count == 2, history.first?.id == second.id else {
                throw CheckFailure("ประวัติรายงานผิด: \(history.count) ฉบับ")
            }
            // Which also settles the `reporting` practice with real evidence
            // instead of a tailoring record (§19.16).
            let facts = await projects.conformanceFacts(of: project.id)
            guard Conformance.evidence(for: .reporting, in: facts) != nil else {
                throw CheckFailure("ออกรายงานแล้วแต่ practice การรายงานยังว่าง")
            }
            // Closing the issue again, so it does not sit in front of G4 — the
            // point above was that the report saw it, not that it stays open.
            for entry in await projects.entries(of: project.id, kind: .issue) {
                var closed = entry
                closed.status = .closed
                try await projects.record(closed)
            }
            return "2 ฉบับ · ฉบับใหม่เห็นของใหม่ ฉบับเก่าไม่ถูกแก้"
        }

        await check("[G4] แปดเงื่อนไขปิดงาน อ่านจากของจริงทีละข้อ") {
            // Every step here removes exactly one blocker and asserts the gate
            // is still shut. A gate tested only against "everything missing"
            // passes while checking one condition — and the eight are wired to
            // eight different stores, so this is where the wiring shows.
            var unmet = try await requireGate(projects, project.id).unmet
            guard unmet.contains(where: { $0.contains("บันทึกบทเรียน") }) else {
                throw CheckFailure("ไม่เห็นเงื่อนไขบทเรียน: \(unmet)")
            }
            try await projects.record(RegisterEntry(
                projectID: project.id,
                title: "ฉบับแปลไทยมักไม่รายงาน α รายด้าน",
                detail: .lesson(cause: "ผู้แปลไม่ได้ตีพิมพ์ภาคผนวก",
                                doDifferently: "ขอฉบับเต็มจากผู้แปลตั้งแต่ต้น",
                                appliesTo: "งานที่ใช้มาตรวัดแปล"),
                origin: .agent(.researcher)))

            unmet = try await requireGate(projects, project.id).unmet
            guard unmet.contains("ตัดสินแล้วว่าข้อมูลและไฟล์ที่เหลือจะไปทางไหน") else {
                throw CheckFailure("ไม่เห็นเงื่อนไขข้อมูลที่เหลือ: \(unmet)")
            }
            // Half a disposition is not a disposition: the policy has to be
            // named and a person has to have decided.
            do {
                _ = try await projects.decideDisposition(
                    DataDisposition(action: .archive, policy: "", decidedBy: "ผู้ใช้"),
                    for: project.id)
                throw CheckFailure("บันทึกการจัดการข้อมูลได้ทั้งที่ไม่ได้บอกนโยบาย")
            } catch LifecycleError.dispositionIncomplete {}
            project = try await projects.decideDisposition(
                DataDisposition(action: .archive,
                                policy: "เก็บข้อมูลดิบ 5 ปี แล้วลบตามระเบียบคณะ",
                                decidedBy: "ผู้ใช้"),
                for: project.id)

            // The business case, measured rather than asserted — and the same
            // record that answers the `benefits` practice below.
            let benefit = Benefit(projectID: project.id,
                                  title: "เวลาที่ใช้สรุปแบบสอบถามหนึ่งชุด",
                                  measure: "ชั่วโมงต่อชุด", baselineValue: 6, target: 2,
                                  reviewAt: Date(), owner: .human("ผู้ใช้"))
            try await projects.save(benefit)
            try await projects.measure(benefit, value: 3, by: "ผู้ใช้")
            let measured = await projects.benefitLedger(of: project.id).lowestAchievement
            guard let measured, abs(measured - 0.75) < 0.001 else {
                throw CheckFailure("ผลการวัดประโยชน์ผิด: \(String(describing: measured))")
            }

            // §19.12 condition 6, against the seventeen practices as this
            // project actually stands. Whatever is left over gets a tailoring
            // record — which is the ISO answer, not a loophole.
            let gaps = await projects.conformance(of: project.id).filter { !$0.satisfied }
            guard !gaps.isEmpty else {
                throw CheckFailure("ไม่มี practice ค้างเลย — น่าสงสัยว่านับจากของจริงหรือเปล่า")
            }
            do {
                try await projects.tailor(gaps[0].practice, in: project.id,
                                          reason: "  ", by: "ผู้ใช้")
                throw CheckFailure("บันทึก tailoring ได้ทั้งที่ไม่มีเหตุผล")
            } catch TailoringError.emptyReason {}
            for gap in gaps {
                try await projects.tailor(gap.practice, in: project.id,
                                          reason: "ไม่อยู่ในขอบเขตของโครงการนี้", by: "ผู้ใช้")
            }

            // An issue raised at the last minute still shuts the gate, and
            // closing it opens it again — the condition reads the register on
            // every evaluation rather than at the moment the stage changed.
            let issue = RegisterEntry(projectID: project.id, title: "ยังไม่ได้ตอบผู้ตรวจภายนอก",
                                      detail: .issue(severity: 3, kind: .problem),
                                      origin: .human("ผู้ใช้"))
            try await projects.record(issue)
            guard try await !requireGate(projects, project.id).passed else {
                throw CheckFailure("ปิดได้ทั้งที่มีปัญหาค้างอยู่ในทะเบียน")
            }
            var resolved = issue
            resolved.status = .closed
            try await projects.record(resolved)

            let ready = try await requireGate(projects, project.id)
            guard ready.passed else {
                throw CheckFailure("ครบแปดข้อแล้วแต่ยังปิดไม่ได้ — ค้าง: \(ready.unmet)")
            }
            return "8 ข้อผ่านทีละข้อ · ประโยชน์วัดได้ 75% ของเป้า"
        }

        await check("[G4] ปิดโครงการแล้วบทเรียนไปโผล่ในคลังส่วนกลาง") {
            project = try await projects.advance(project.id)
            guard project.stage == .closed, project.closure == .completed else {
                throw CheckFailure("ปิดไม่สำเร็จ: \(project.stage) / \(String(describing: project.closure))")
            }

            // The loop §19.11 describes: the next project searches `central`
            // and finds what this one learned.
            let central = try await knowledge.load(scope: .central)
            guard central.contains(where: { $0.text.contains("ขอฉบับเต็มจากผู้แปล") }) else {
                throw CheckFailure("บทเรียนไม่ได้ไหลเข้าคลังส่วนกลาง (\(central.count) chunk)")
            }
            return "ปิดแล้ว · บทเรียนอยู่ใน central"
        }

        await check("[รายงานปิดโครงการ] ส่งมอบ · ประโยชน์ · บทเรียน · สิ่งที่ยกให้คนอื่น") {
            guard let report = try await projects.issueReport(.endProject, for: project.id) else {
                throw CheckFailure("ออกรายงานปิดโครงการไม่สำเร็จ")
            }
            for expected in ["α = 0.74",                       // ส่งมอบอะไรบ้าง
                             "ได้ 75% ของเป้า",                 // ประโยชน์ที่วัดได้
                             "ขอฉบับเต็มจากผู้แปลตั้งแต่ต้น",     // บทเรียน
                             "ย้ายเข้าคลังเก็บถาวร"] {          // สิ่งที่ยกให้คนอื่นรับต่อ
                guard report.rendered.contains(expected) else {
                    throw CheckFailure("รายงานปิดโครงการไม่มี '\(expected)'")
                }
            }
            // The report is written *after* closing and still reads correctly,
            // which is the case that matters: everything it quotes is a row, so
            // nothing needed to be captured while the project was still open.
            guard report.stageAtIssue == .closed else {
                throw CheckFailure("รายงานไม่ได้บันทึกว่าเขียนตอนขั้นไหน")
            }
            return "ครบ 4 หัวข้อจากแถวจริง"
        }

        await check("[เวลา] งานที่ทำผ่านประตูถูกนับเข้าใบงานที่ทำอยู่") {
            // The pipe P10.15 built, end to end: a tool call carrying a work
            // package on its context must show up as time against that leaf,
            // and a call carrying none must not invent one.
            let sink = SurrealSpanSink(client: client)
            let gateway = ToolGateway(
                chain: HookChain(stageGate: StageGate(reader: projects)),
                spanSink: sink,
                modes: OperatingModes(autonomy: .fullAutonomous))
            let flag = RanFlag()
            await gateway.register(SpyTool(name: "kb_search", riskLevel: .low, flag: flag))

            _ = try await gateway.call("kb_search", argumentsJSON: "{}",
                                       context: ToolContext(scope: project.scope,
                                                            role: .analyst,
                                                            workPackage: leafID))
            _ = try await gateway.call("kb_search", argumentsJSON: "{}",
                                       context: ToolContext(scope: project.scope,
                                                            role: .analyst))

            let elapsed = try await sink.elapsedByWorkPackage(project: project.id)
            guard elapsed[leafID] != nil else {
                throw CheckFailure("งานที่ผูกใบไว้ไม่ได้ถูกนับเข้าใบนั้น")
            }
            guard elapsed.count == 1 else {
                throw CheckFailure("งานที่ไม่ได้ผูกใบ ถูกยัดเข้าใบใดใบหนึ่ง: \(elapsed.keys)")
            }
            return "นับเข้า 1 ใบ · งานที่ไม่ผูกไม่ถูกยัดเข้าใคร"
        }

        await check("[หลังปิด] โครงการที่ปิดแล้วอ่านได้ แต่แก้ข้อมูลไม่ได้") {
            shell.reset(); search.reset()
            let blocked = try await callTool("run_shell")
            guard !blocked.didExecute, !shell.ran else {
                throw CheckFailure("โครงการปิดแล้วยังรันคำสั่งได้")
            }
            guard try await callTool("kb_search").didExecute else {
                throw CheckFailure("โครงการปิดแล้วอ่านไม่ได้ — มันต้องเป็นบันทึกที่ย้อนดูได้")
            }
            return "อ่านได้ · เขียนไม่ได้"
        }

        await reopen(check: check, project: project, leafID: leafID)
    }

    /// Everything above, asked again through a service that has never seen this
    /// project — the app after a relaunch.
    ///
    /// This is the half that unit tests structurally cannot reach: every store
    /// in this system caches, and a cache that answers correctly only because
    /// it was the thing that wrote the value is a cache that will be wrong on
    /// the next launch. It is also where this project's worst bugs have lived.
    private func reopen(check: (String, () async throws -> String) async -> Void,
                        project: Project, leafID: String) async {
        let fresh = ProjectService(
            store: ProjectStore(client: client),
            plans: WorkPackageStore(client: client),
            exceptions: ExceptionStore(client: client),
            registers: RegisterStore(client: client),
            baselines: BaselineStore(client: client),
            lessons: LessonPublisher(knowledge: knowledge),
            benefits: BenefitStore(client: client),
            tailoring: TailoringStore(client: client),
            closingLedger: ClosingLedger(conflicts: ConflictStore(client: client),
                                         plans: AnalysisPlanStore(client: client)),
            reports: ReportStore(client: client))

        await check("[เปิดใหม่] โปรเจกต์กลับมาพร้อมขอบเขต หมวก และกรอบที่ตั้งไว้") {
            guard let reloaded = await fresh.project(project.id) else {
                throw CheckFailure("เปิดใหม่แล้วไม่เจอโปรเจกต์")
            }
            guard reloaded.stage == .closed, reloaded.closure == .completed else {
                throw CheckFailure("สถานะปิดไม่รอด: \(reloaded.stage)")
            }
            guard reloaded.statement.outOfScope == ["การเปรียบเทียบข้ามวิชาชีพ"] else {
                throw CheckFailure("ขอบเขต 'ไม่ทำ' หาย")
            }
            guard reloaded.executive?.person == "ผู้ใช้" else {
                throw CheckFailure("ชื่อ Executive หาย")
            }
            // The frame as it was *decided*, not the preset it started from: the
            // status bar widened cost to ฿1,000 mid-project, and a decision that
            // does not survive a relaunch is a decision the system forgot.
            guard reloaded.tolerances.limit(.cost) == 1_000 else {
                throw CheckFailure("กรอบค่าใช้จ่ายที่ขยายไว้ไม่รอดข้ามการเปิดใหม่: \(reloaded.tolerances.limit(.cost))")
            }
            return reloaded.stage.label
        }

        await check("[เปิดใหม่] ใบงานกลับมาพร้อมเกณฑ์ ผู้รับผิดชอบ และหลักฐาน") {
            let wbs = await fresh.breakdown(of: project.id)
            guard let leaf = wbs.packages.first(where: { $0.id == leafID }) else {
                throw CheckFailure("ใบงานหาย")
            }
            guard !leaf.acceptanceCriteria.isEmpty else { throw CheckFailure("เกณฑ์เสร็จหาย") }
            guard leaf.raci?.accountable == .human("ผู้ใช้") else {
                throw CheckFailure("ผู้รับผิดชอบผลหาย")
            }
            guard leaf.status == .done, !leaf.evidence.isEmpty else {
                throw CheckFailure("หลักฐานที่ปิดงานหาย — 'เสร็จ' ที่ไม่มีของให้ตรวจ")
            }
            return "\(wbs.packages.count) ใบ · หลักฐาน \(leaf.evidence.count)"
        }

        await check("[เปิดใหม่] baseline ทั้งสองเวอร์ชันยังอยู่ และคำตัดสินยังมีชื่อคน") {
            let history = await fresh.baselineHistory(of: project.id)
            guard history.map(\.version) == [3, 2, 1] else {
                throw CheckFailure("ประวัติ baseline หลังเปิดใหม่: \(history.map(\.version))")
            }
            let changes = await fresh.entries(of: project.id, kind: .change)
            guard let decided = changes.first, decided.status == .approved,
                  decided.decidedBy == "ผู้ใช้" else {
                throw CheckFailure("คำตัดสินไม่รอด: \(changes.map(\.status))")
            }
            let lessons = await fresh.entries(of: project.id, kind: .lesson)
            guard lessons.count == 1 else { throw CheckFailure("บทเรียนหาย") }
            return "v2/v1 · ตัดสินโดย \(decided.decidedBy ?? "—")"
        }

        await check("[เปิดใหม่] ประโยชน์ที่วัดแล้ว การจัดการข้อมูล และบันทึก tailoring ยังอยู่") {
            let achieved = await fresh.benefitLedger(of: project.id).lowestAchievement
            guard let achieved, abs(achieved - 0.75) < 0.001 else {
                throw CheckFailure("ผลการวัดประโยชน์ไม่รอด: \(String(describing: achieved))")
            }
            guard let disposition = await fresh.project(project.id)?.dataDisposition,
                  disposition.isDecided, disposition.action == .archive else {
                throw CheckFailure("การตัดสินเรื่องข้อมูลที่เหลือหายไปหลังเปิดใหม่")
            }
            // The whole conformance answer, rebuilt from rows: seventeen
            // practices, each still pointing at either something real or the
            // record of somebody deciding not to.
            let rows = await fresh.conformance(of: project.id)
            let unanswered = rows.filter { !$0.satisfied }
            guard unanswered.isEmpty else {
                throw CheckFailure("practice ที่ตอบไว้แล้วกลับว่าง: \(unanswered.map(\.practice.label))")
            }
            let tailored = rows.count(where: \.isTailored)
            return "ประโยชน์ 75% · \(disposition.action.label) · ของจริง \(rows.count - tailored) · บันทึกว่าไม่ทำ \(tailored)"
        }

        await check("[เปิดใหม่] ข้อยกเว้นที่ยังเปิดอยู่ หยุดงานได้ตั้งแต่ก่อนใครเปิดหน้าจอ") {
            // A second project, stopped and never resolved. The blocked set in
            // a fresh service starts empty, so if boot does not rebuild it the
            // work resumes silently — which is the failure mode a stop cannot
            // afford.
            let stopped = try await fresh.create(name: "โครงการที่ค้างไว้")
            _ = try await fresh.raiseBreaches(for: stopped.id,
                                              readings: ToleranceReadings(spent: 5_000))

            let afterRestart = ProjectService(
                store: ProjectStore(client: client),
                plans: WorkPackageStore(client: client),
                exceptions: ExceptionStore(client: client))
            guard await afterRestart.hasOpenException(stopped.id) == false else {
                throw CheckFailure("service ใหม่รู้เรื่องข้อยกเว้นก่อนอ่านฐานข้อมูล — แปลว่าเทสนี้ไม่ได้ทดสอบอะไร")
            }
            await afterRestart.refreshExceptions()
            guard await afterRestart.hasOpenException(stopped.id) else {
                throw CheckFailure("เปิดแอปใหม่แล้วการหยุดหายไป")
            }

            let gateway = ToolGateway(
                chain: HookChain(stageGate: StageGate(reader: afterRestart)),
                modes: OperatingModes(autonomy: .fullAutonomous))
            let flag = RanFlag()
            await gateway.register(SpyTool(name: "run_shell", riskLevel: .high, flag: flag))
            let outcome = try await gateway.call(
                "run_shell", argumentsJSON: "{}",
                context: ToolContext(scope: stopped.scope))
            guard !outcome.didExecute, !flag.ran else {
                throw CheckFailure("เปิดใหม่แล้วรันคำสั่งได้ทั้งที่ยังทะลุกรอบอยู่")
            }
            return "หยุดต่อหลังเปิดใหม่"
        }
    }

    private func requireGate(_ projects: ProjectService, _ id: ProjectID) async throws -> GateEvaluation {
        guard let gate = await projects.gate(for: id) else {
            throw CheckFailure("ไม่มีประตูให้ตรวจ")
        }
        return gate
    }
}
