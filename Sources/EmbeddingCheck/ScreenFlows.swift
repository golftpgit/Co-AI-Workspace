import Foundation
import AgentKit
import Knowledge
import Persistence
import EmbeddingRuntime
import CoreEngine
import LLMProviders
import Analysis

// ─────────────────────────────────────────────────────────────
// Driving the screens' logic the way a person would, against the real
// database and the real embedding model.
//
// This is not a substitute for using the app. It cannot see a view, so it
// cannot catch what half of P1.10's eight defects were — a banner that filled
// the window, a card drawn twice. What it does catch is the other half, which
// were wiring: an edit that never reached storage, a store that was never
// attached, a screen showing state that no longer exists.
//
// It lives here rather than in a test target because it needs MLX, and MLX
// cannot load its Metal kernels under `swift test` (ARCHITECTURE E.13).
// ─────────────────────────────────────────────────────────────

struct ScreenFlows {
    let embedder: MLXEmbedder

    /// Everything the knowledge screen does, in the order a person does it:
    /// add a document, search for it, correct an entity, search again, delete.
    func run(check: (String, () async throws -> String) async -> Void) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coai-flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var index = KnowledgeIndex(profile: embedder.profile)
        let pipeline = IngestionPipeline()

        let file = directory.appendingPathComponent("รายงาน.md")
        let text = """
        รายงานประจำปีของหน่วยงานด้านสาธารณสุขเรื่องการควบคุมโรคเบาหวานในชุมชน.
        การให้อินซูลินร่วมกับการปรับพฤติกรรมช่วยลดภาวะแทรกซ้อนได้อย่างมีนัยสำคัญ.
        """
        try? text.write(to: file, atomically: true, encoding: .utf8)

        var firstChunkID = ""

        // §19.2 / P10.12 — the Workbench's second Done-when: General can query a
        // database without anybody creating a project first. General is not the
        // leftovers, it is a place to work, and the app-wide analysis store is
        // what makes that true.
        await check("[โต๊ะทำงาน · General] query ฐานข้อมูลได้โดยไม่ต้องสร้างโปรเจกต์") {
            let folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "coai-general-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = try AnalysisStore(fileURL: folder.appending(path: "analysis.duckdb"))
            // Through the same guard the screen runs statements through, because
            // a query path that skips it is not the path the person uses.
            let create = "CREATE TABLE burnout (site TEXT, alpha DOUBLE)"
            guard SQLGuard.assess(create).effect >= .write else {
                throw CheckFailure("guard ไม่ถือว่า CREATE TABLE เป็นการเปลี่ยนข้อมูล")
            }
            _ = try await store.query(create)
            _ = try await store.query("INSERT INTO burnout VALUES ('รพ. ก', 0.74)")

            let read = "SELECT site, alpha FROM burnout"
            guard SQLGuard.assess(read).effect == .read else {
                throw CheckFailure("guard ถือว่า SELECT เปลี่ยนข้อมูล")
            }
            let result = try await store.query(read)
            guard result.rows.count == 1, result.rows[0].first == "รพ. ก" else {
                throw CheckFailure("อ่านค่ากลับมาไม่ตรง: \(result.rows)")
            }
            guard try await store.tables().contains("burnout") else {
                throw CheckFailure("ตารางที่สร้างไม่โผล่ในรายชื่อตาราง")
            }
            return "สร้าง · เขียน · อ่าน ครบใน General"
        }

        await check("[หน้าคลังความรู้] เพิ่มเอกสารแล้วค้นเจอ") {
            let report = try await pipeline.ingest(file, into: &index, scope: .central,
                                                   tier: .t3, embedder: embedder)
            guard report.chunksAdded > 0 else { throw CheckFailure("ingest ไม่ได้เพิ่มอะไร") }
            let hits = index.search("อินซูลิน", scope: .central)
            guard let first = hits.first else { throw CheckFailure("ค้นไม่เจอหลัง ingest") }
            firstChunkID = first.chunk.id
            guard first.provenance.tier == .t3 else { throw CheckFailure("tier หาย") }
            return "\(report.chunksAdded) ส่วน"
        }

        await check("[หน้าคลังความรู้] แก้ entity แล้วผลค้นหาเปลี่ยนจริง") {
            guard index.search("กรมควบคุมโรค", scope: .central).isEmpty else {
                throw CheckFailure("เจอก่อนแก้ ทั้งที่ยังไม่มี entity นี้")
            }
            guard index.updateEntities(of: firstChunkID, to: ["กรมควบคุมโรค"]) else {
                throw CheckFailure("แก้ entity ไม่สำเร็จ")
            }
            guard !index.search("กรมควบคุมโรค", scope: .central).isEmpty else {
                throw CheckFailure("แก้แล้วแต่ค้นยังไม่เจอ — P2.7 Done-when ไม่ผ่าน")
            }
            return ""
        }

        await check("[หน้าคลังความรู้] ค้นแบบ hybrid ใช้ฝั่ง vector จริง") {
            let fused = try await index.search("การรักษาโรคเบาหวาน", scope: .central,
                                               embedder: embedder)
            guard fused.contains(where: { $0.semanticRank != nil }) else {
                throw CheckFailure("ไม่มีผลจากฝั่ง vector เลย")
            }
            return "\(fused.count) ผล"
        }

        // Both directions of the same line. Only checking that nonsense returns
        // nothing would pass with a floor so high the library answers nothing
        // at all.
        await check("[หน้าคลังความรู้] คำค้นที่ไม่เกี่ยวข้องต้องไม่คืนอะไรเลย") {
            let relevant = try await index.search("การรักษาเบาหวานด้วยอินซูลิน", scope: .central,
                                                  embedder: embedder)
            guard !relevant.isEmpty else {
                throw CheckFailure("เกณฑ์สูงเกินไป — คำค้นที่ตรงเรื่องยังไม่คืนผล")
            }
            let unrelated = try await index.search("ตารางเดินรถไฟฟ้าสายสีม่วงช่วงเช้า",
                                                   scope: .central, embedder: embedder)
            guard unrelated.isEmpty else {
                throw CheckFailure("คำค้นคนละเรื่องยังได้ \(unrelated.count) ผล — "
                                   + "คลังที่มีเอกสารเดียวจะตอบทุกคำถามด้วยเอกสารนั้น")
            }
            return "ตรงเรื่อง \(relevant.count) ผล · ไม่เกี่ยว 0 ผล"
        }

        await check("[หน้าคลังความรู้] ลบเอกสารแล้วหายทั้งฉบับ") {
            let documentID = index.documents().first?.documentID ?? ""
            let removed = index.removeDocument(documentID)
            guard removed > 0, index.documents().isEmpty else {
                throw CheckFailure("ลบแล้วยังเหลือ \(index.count) ส่วน")
            }
            return "\(removed) ส่วน"
        }

        // The path the screen actually uses: write through on every change,
        // then reload from the database as a fresh launch would.
        await check("[persistence] ingest → เขียนลง DB → โหลดใหม่แล้วยังอยู่") {
            guard let server = try await TestDatabase.start(port: 18_492) else {
                throw CheckFailure("เริ่มฐานข้อมูลไม่ได้")
            }
            defer { Task { await server.stop() } }

            let store = KnowledgeStore(client: server.client)
            var live = KnowledgeIndex(profile: embedder.profile)
            let report = try await pipeline.ingest(file, into: &live, scope: .central,
                                                   tier: .t3, embedder: embedder)
            try await store.save(live.allChunks)

            // A new launch: nothing in memory, everything from storage.
            var reopened = KnowledgeIndex(profile: embedder.profile)
            try reopened.insert(contentsOf: try await store.load(scope: .central))

            guard reopened.count == report.chunksAdded else {
                throw CheckFailure("โหลดกลับได้ \(reopened.count) จาก \(report.chunksAdded)")
            }
            guard !reopened.search("อินซูลิน", scope: .central).isEmpty else {
                throw CheckFailure("โหลดกลับแล้วค้นไม่เจอ")
            }
            let hit = reopened.search("อินซูลิน", scope: .central).first
            guard hit?.chunk.embedding?.count == 1_024 else {
                throw CheckFailure("vector ไม่รอดข้ามการบันทึก")
            }
            return "\(reopened.count) ส่วนกลับมาครบพร้อม vector"
        }

        await check("[persistence] แก้ entity แล้วรอดข้ามการเปิดใหม่") {
            guard let server = try await TestDatabase.start(port: 18_493) else {
                throw CheckFailure("เริ่มฐานข้อมูลไม่ได้")
            }
            defer { Task { await server.stop() } }

            let store = KnowledgeStore(client: server.client)
            var live = KnowledgeIndex(profile: embedder.profile)
            _ = try await pipeline.ingest(file, into: &live, scope: .central,
                                          tier: .t3, embedder: embedder)
            try await store.save(live.allChunks)

            guard let target = live.allChunks.first else { throw CheckFailure("ไม่มี chunk") }
            try await store.updateEntities(chunkID: target.id, to: ["กรมควบคุมโรค"])

            var reopened = KnowledgeIndex(profile: embedder.profile)
            try reopened.insert(contentsOf: try await store.load(scope: .central))
            guard !reopened.search("กรมควบคุมโรค", scope: .central).isEmpty else {
                throw CheckFailure("แก้ entity แล้วหายตอนเปิดใหม่ — editor โกหกผู้ใช้")
            }
            return ""
        }

        await check("[หน้าข้อขัดแย้ง] ตัดสินแล้วรอดข้ามการเปิดใหม่ และไม่ถามซ้ำ") {
            guard let server = try await TestDatabase.start(port: 18_494) else {
                throw CheckFailure("เริ่มฐานข้อมูลไม่ได้")
            }
            defer { Task { await server.stop() } }

            let store = ConflictStore(client: server.client)
            var ledger = ConflictLedger()
            let a = ConflictSide(text: "ค่ามาตรฐานคือ 5",
                                 provenance: Provenance(documentID: "ก", title: "งานวิจัย ก",
                                                        origin: .upload(filename: "a.pdf"),
                                                        tier: .t2, year: 2025))
            let b = ConflictSide(text: "ค่ามาตรฐานคือ 7",
                                 provenance: Provenance(documentID: "ข", title: "งานวิจัย ข",
                                                        origin: .upload(filename: "b.pdf"),
                                                        tier: .t2, year: 2024))
            let conflict = ledger.record(question: "ค่ามาตรฐาน", a: a, b: b, scope: .central)
            guard conflict.needsHuman else { throw CheckFailure("ควรยกให้คนตัดสิน") }
            try await store.save(conflict, scope: .central)

            guard try await store.open(scope: .central).count == 1 else {
                throw CheckFailure("การ์ดที่รอตัดสินไม่โผล่")
            }

            _ = ledger.decide(conflict.id, .bothInContext(condition: "ต่างกันตามช่วงอายุ"),
                              scope: .central)
            guard let decided = ledger.all.first else { throw CheckFailure("ไม่มีคำตัดสิน") }
            try await store.save(decided, scope: .central)

            // Reopened: the decision is there and the card is no longer asking.
            guard try await store.open(scope: .central).isEmpty else {
                throw CheckFailure("ตัดสินแล้วยังถามซ้ำ — §11.6 ผิดคำสัญญา")
            }
            let restored = try await store.load(scope: .central).first
            guard case .bothInContext(let condition)? = restored?.decision?.resolution,
                  condition == "ต่างกันตามช่วงอายุ" else {
                throw CheckFailure("เงื่อนไขของคำตัดสินหาย")
            }
            return ""
        }

        // The gap that let the bug through: the orchestrator's own tests assert
        // on its in-memory entries, which are correct. Nobody asked what
        // reached storage — and storage still described the first attempt of a
        // run that had since failed three times and escalated.
        await check("[หน้าทีม] บันทึกใน DB ตรงกับสิ่งที่ทีมทำจริง ไม่ใช่แค่รอบแรก") {
            guard let server = try await TestDatabase.start(port: 18_497) else {
                throw CheckFailure("เริ่มฐานข้อมูลไม่ได้")
            }
            defer { Task { await server.stop() } }

            let store = TaskLedgerStore(client: server.client)
            // A UUID-shaped id, because that is what `Assignment` generates by
            // default and therefore what the app actually stores. The first
            // version of this check used "eng-1" and passed while the app was
            // failing — the shape of the id was the whole bug.
            let assignment = Assignment(
                id: UUID().uuidString, role: .engineer, goal: "แก้เทสที่ตก",
                acceptanceCriteria: [Criterion(text: "เทสผ่าน",
                                               evidenceRequired: "คำสั่งที่ exit code 0")],
                deliverableType: "patch")
            let team = TeamOrchestrator(
                router: ModelRouter(executors: []),
                specialists: [.engineer: AlwaysFailingEngineer()],
                retryCap: 3,
                ledgerStore: store,
                scope: .central)

            _ = await team.run(goal: "แก้เทสที่ตก",
                               plan: TeamPlan(goal: "แก้เทสที่ตก", assignments: [assignment]))

            let rows = try await store.rows(scope: .central)
            guard let row = rows.first, rows.count == 1 else {
                throw CheckFailure("คาดว่า 1 แถว ได้ \(rows.count)")
            }
            guard row.attempts == 3 else {
                throw CheckFailure("DB บันทึกว่า \(row.attempts) รอบ แต่ทีมลองจริง 3 รอบ — "
                                   + "คนที่กลับมาอ่านหลังปล่อยงานทิ้งไว้จะได้ภาพผิด")
            }
            guard !row.passed, !row.findings.isEmpty else {
                throw CheckFailure("สถานะสุดท้ายหรือเหตุผลที่ต้องให้คนตัดสินไม่ถูกบันทึก")
            }
            guard try await store.unfinished(scope: .central).count == 1 else {
                throw CheckFailure("งานที่ escalate แล้วไม่ถูกนับว่ายังไม่จบ")
            }
            return "\(row.attempts) รอบ ตรงกับที่รันจริง"
        }

        // §5.5's third switch. "Done" is read off the ledger, so the two kinds
        // of unfinished work have to stay distinguishable: one is picked up
        // again, the other is a decision to involve a person and must survive.
        await check("[Run-until-done] ทำงานค้างต่อได้ แต่ไม่รื้องานที่ escalate ไปแล้ว") {
            guard let server = try await TestDatabase.start(port: 18_498) else {
                throw CheckFailure("เริ่มฐานข้อมูลไม่ได้")
            }
            defer { Task { await server.stop() } }

            let store = TaskLedgerStore(client: server.client)
            let criteria = [Criterion(text: "เทสผ่าน", evidenceRequired: "คำสั่งที่ exit code 0")]

            // Cut short: the app closed mid-run, nobody decided anything.
            try await store.record(LedgerRow(
                assignmentID: OpaqueID.make(OpaqueID.assignment), role: .writer,
                goal: "เขียนสรุปให้จบ", attempts: 1, passed: false, needsHuman: false,
                findings: [], summary: nil,
                acceptanceCriteria: criteria, deliverableType: "เอกสาร"), scope: .central)

            // Escalated: the lead ran out of tries and asked for a person.
            try await store.record(LedgerRow(
                assignmentID: OpaqueID.make(OpaqueID.assignment), role: .engineer,
                goal: "แก้เทสที่ตก", attempts: 3, passed: false, needsHuman: true,
                findings: ["ไม่มีคำสั่งที่ exit code 0"], summary: nil,
                acceptanceCriteria: criteria, deliverableType: "patch"), scope: .central)

            guard try await store.unfinished(scope: .central).count == 2 else {
                throw CheckFailure("ทั้งสองงานควรนับว่ายังไม่จบ")
            }
            let resumable = try await store.resumable(scope: .central)
            guard resumable.count == 1, resumable.first?.role == .writer else {
                throw CheckFailure("คาดว่าต่อได้งานเดียว (งานที่ถูกขัดจังหวะ) "
                                   + "ได้ \(resumable.count) งาน — "
                                   + "ถ้ารวมงานที่ escalate ด้วย แปลว่าเครื่องรื้อคำตัดสินที่จะให้คนดู")
            }
            // Resuming needs the criteria back, or there is nothing to review
            // against and `Assignment` refuses to be rebuilt at all.
            guard let rebuilt = resumable.first?.assignment,
                  rebuilt.acceptanceCriteria.count == 1 else {
                throw CheckFailure("สร้าง Assignment กลับจากบันทึกไม่ได้ — เกณฑ์ตรวจรับไม่ถูกเก็บ")
            }
            return "ต่อได้ 1 · กันไว้ให้คน 1"
        }

        // The Team screen reads this table and nothing else. §2.2's promise is
        // that "who is doing what, and how did it go" survives the run — and
        // the moment someone asks is usually after leaving one unattended, so
        // the reasons have to come back with the row.
        await check("[หน้าทีม] งานที่ถูกตีกลับรอดข้ามการเปิดใหม่ พร้อมเหตุผล") {
            guard let server = try await TestDatabase.start(port: 18_496) else {
                throw CheckFailure("เริ่มฐานข้อมูลไม่ได้")
            }
            defer { Task { await server.stop() } }

            let store = TaskLedgerStore(client: server.client)
            // First write: the attempt has only just started.
            try await store.record(LedgerRow(
                assignmentID: "a1", role: .engineer, goal: "แก้บั๊ก parser",
                attempts: 1, passed: false, findings: [], summary: nil), scope: .central)

            // The orchestrator writes on every state change, so the second
            // write has to replace the first. A ledger that only ever records
            // the first attempt looks exactly like one that is up to date.
            try await store.record(LedgerRow(
                assignmentID: "a1", role: .engineer, goal: "แก้บั๊ก parser",
                attempts: 3, passed: false,
                findings: ["ไม่มีคำสั่งที่ exit code 0 ในทรานสคริปต์"],
                summary: "แก้แล้วครับ ทุกอย่างผ่าน"), scope: .central)

            let reopened = try await store.rows(scope: .central)
            guard let row = reopened.first, reopened.count == 1 else {
                throw CheckFailure("โหลดกลับได้ \(reopened.count) แถว")
            }
            guard row.attempts == 3, !row.passed else {
                throw CheckFailure("จำนวนรอบหรือผลตรวจเพี้ยนหลังโหลดกลับ")
            }
            // "ถูกตีกลับ" with no reason is what made v1's loops unreadable.
            guard row.findings.first?.contains("exit code 0") == true else {
                throw CheckFailure("เหตุผลที่ QA ตีกลับหายไป เหลือแต่ผลลัพธ์")
            }
            guard try await store.unfinished(scope: .central).count == 1 else {
                throw CheckFailure("งานที่ยังไม่จบไม่ถูกนับว่ายังไม่จบ")
            }
            return ""
        }

        await check("[หน้าข้อขัดแย้ง] ตัดสินแล้วน้ำหนักและข้อเสนอบนการ์ดไม่ถูกเขียนทับ") {
            guard let server = try await TestDatabase.start(port: 18_495) else {
                throw CheckFailure("เริ่มฐานข้อมูลไม่ได้")
            }
            defer { Task { await server.stop() } }

            let store = ConflictStore(client: server.client)
            var ledger = ConflictLedger()
            // Close enough that the ledger hands it to a human — an
            // auto-decided pair never becomes a card anyone reads.
            let a = ConflictSide(text: "ให้ยาต่ออีก 24 ชั่วโมง",
                                 provenance: Provenance(documentID: "ก", title: "แนวทาง ก",
                                                        origin: .upload(filename: "a.txt"),
                                                        tier: .t2, year: 2024))
            let b = ConflictSide(text: "หยุดยาทันทีที่ปิดแผล",
                                 provenance: Provenance(documentID: "ข", title: "แนวทาง ข",
                                                        origin: .upload(filename: "b.txt"),
                                                        tier: .t2, year: 2025))
            let conflict = ledger.record(question: "ให้ยาต่อนานแค่ไหน", a: a, b: b, scope: .central)
            guard conflict.needsHuman else { throw CheckFailure("ควรยกให้คนตัดสิน") }
            try await store.save(conflict, scope: .central)

            // Stand in for a card filed long enough ago that re-weighing it
            // today would not reproduce these numbers. Without this the check
            // passes either way: a conflict saved and re-saved in the same
            // second weighs the same both times, which is exactly why the bug
            // survived — it only shows once time has passed.
            _ = try await server.client.exec("""
                UPDATE conflict SET score_a = 1.25, score_b = 9.75,
                                    weight_a = $reason WHERE uid = $uid
                """,
                vars: ["uid": conflict.id, "reason": "ชั่งไว้ตอนยื่นเรื่อง ปี 2568"])

            guard let card = try await store.open(scope: .central).first else {
                throw CheckFailure("การ์ดที่รอตัดสินไม่โผล่")
            }
            guard card.scoreA == 1.25 else {
                throw CheckFailure("ตั้งค่าเริ่มต้นของเทสไม่ติด")
            }
            // §11.6 puts the system's suggestion on the card. It was being
            // written and never read back, so the card could not name a side.
            guard card.proposal != nil else {
                throw CheckFailure("ข้อเสนอของระบบหายระหว่างทาง — การ์ดบอกไม่ได้ว่าเสนอฝั่งไหน")
            }
            let (shownA, shownB) = (card.scoreA, card.scoreB)
            let shownReasons = card.weightAReasons

            try await store.recordDecision(
                ConflictDecision(resolution: .preferB(reason: "ฉบับใหม่กว่า"),
                                 scope: .central, decidedByHuman: true),
                for: card.id)

            guard try await store.open(scope: .central).isEmpty else {
                throw CheckFailure("ตัดสินแล้วยังถามซ้ำ")
            }
            guard let after = try await store.load(scope: .central).first else {
                throw CheckFailure("คำตัดสินหาย")
            }
            // The record has to keep what was weighed *then*. Deciding used to
            // rebuild the conflict, which re-weighed both sides against the
            // current date and saved those numbers over the ones on the card.
            guard after.scoreA == shownA, after.scoreB == shownB,
                  after.weightAReasons == shownReasons else {
                throw CheckFailure("น้ำหนักถูกคำนวณใหม่ตอนบันทึก — บันทึกไม่ตรงกับการ์ดที่ผู้ใช้อ่าน "
                                   + "(\(shownA)/\(shownB) → \(after.scoreA)/\(after.scoreB))")
            }
            guard after.proposal != nil else {
                throw CheckFailure("ข้อเสนอของระบบหายหลังตัดสิน")
            }
            return ""
        }
    }
}

/// Fails every time, so the lead runs its full retry budget and ends by
/// escalating — the path whose final state was never written down.
private actor AlwaysFailingEngineer: Specialist {
    nonisolated let role = Role.engineer
    nonisolated let definitionOfDone = [
        Criterion(text: "เทสผ่าน", evidenceRequired: "คำสั่งที่ exit code 0"),
    ]

    func execute(_ assignment: Assignment) async throws -> Deliverable {
        throw SpecialistError.modelUnavailable("โมเดลใช้ไม่ได้ในเทสนี้")
    }
}
