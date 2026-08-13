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
            lessons: LessonPublisher(knowledge: knowledge))

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

        await check("[baseline] เพิ่มใบงานหลังตกลงแล้ว = drift ที่มองเห็น") {
            let extra = WorkPackage(projectID: project.id, title: "ภาคผนวก ก",
                                    scopeRef: "ความชุกในพยาบาลวิชาชีพ",
                                    acceptanceCriteria: [Criterion(text: "มีตาราง",
                                                                   evidenceRequired: "ไฟล์")],
                                    raci: RACI(accountable: .teamLead))
            extraLeafID = extra.id
            try await projects.save(extra)

            guard let drift = await projects.drift(of: project.id) else {
                throw CheckFailure("ไม่มี drift ให้ดูทั้งที่มี baseline แล้ว")
            }
            guard drift.addedCount == 1, !drift.isEmpty else {
                throw CheckFailure("นับส่วนต่างผิด: \(drift.summary)")
            }
            return drift.summary
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
            try await projects.resolve(raised[0], decision: "ขยายเพดานเป็น ฿1,000")
            shell.reset()
            guard try await callTool("run_shell").didExecute, shell.ran else {
                throw CheckFailure("ปิดข้อยกเว้นแล้วยังทำงานต่อไม่ได้")
            }
            return "หยุดแล้วเดินต่อได้"
        }

        await check("[คำขอเปลี่ยนแปลง] คนตัดสิน แล้ว baseline v2 เกิดขึ้นโดยไม่ทับ v1") {
            let change = RegisterEntry(
                projectID: project.id, title: "เพิ่มภาคผนวก ก",
                detail: .change(scopeImpact: "+1 ใบงาน", timeImpact: "+0.5 วัน",
                                costImpact: "+฿40"),
                origin: .agent(.teamLead))
            try await projects.record(change)

            let blockedGate = try await requireGate(projects, project.id)
            guard !blockedGate.passed else {
                throw CheckFailure("G3 เปิดทั้งที่มีคำขอค้างและแผนต่างจาก baseline")
            }

            try await projects.decideChange(change, approve: true, by: "ผู้ใช้")
            let history = await projects.baselineHistory(of: project.id)
            guard history.map(\.version) == [2, 1] else {
                throw CheckFailure("ประวัติ baseline ผิด: \(history.map(\.version))")
            }
            guard await projects.drift(of: project.id)?.isEmpty == true else {
                throw CheckFailure("อนุมัติแล้วแต่ยังเห็นส่วนต่างจาก baseline ใหม่")
            }
            return "v1 ยังอ่านได้ · v2 ตรงกับแผนวันนี้"
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

        await check("[G4] ปิดโครงการแล้วบทเรียนไปโผล่ในคลังส่วนกลาง") {
            let gateBefore = try await requireGate(projects, project.id)
            guard !gateBefore.passed else {
                throw CheckFailure("ปิดได้ทั้งที่ยังไม่มีบทเรียน")
            }

            try await projects.record(RegisterEntry(
                projectID: project.id,
                title: "ฉบับแปลไทยมักไม่รายงาน α รายด้าน",
                detail: .lesson(cause: "ผู้แปลไม่ได้ตีพิมพ์ภาคผนวก",
                                doDifferently: "ขอฉบับเต็มจากผู้แปลตั้งแต่ต้น",
                                appliesTo: "งานที่ใช้มาตรวัดแปล"),
                origin: .agent(.researcher)))

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
            lessons: LessonPublisher(knowledge: knowledge))

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
            guard reloaded.tolerances.limit(.cost) == Tolerances.balanced.limit(.cost) else {
                throw CheckFailure("กรอบค่าใช้จ่ายเพี้ยนหลังโหลดใหม่")
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
            guard history.map(\.version) == [2, 1] else {
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
