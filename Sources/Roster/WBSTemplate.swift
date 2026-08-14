import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// The plan a project starts with (ARCHITECTURE §20.2, P11.1).
//
// A project type names a template — `research-5-chapter` — and this is what that
// name resolves to. Templates are here, in code, rather than in the manifest for
// one reason: a work package has an `acceptanceCriteria` that cannot be empty and
// a `deliverableType` that has to say what is handed over, and expressing that in
// flat frontmatter would be inventing the nested format §7.2 refused.
//
// What the template gives is deliberately **a draft, not a plan**. Every package
// arrives without a `scopeRef` and without RACI, which means G2 refuses to pass
// until a person has said what each one is for and who answers for it. A starting
// WBS that could pass the gate on its own would be a plan nobody wrote.
// ─────────────────────────────────────────────────────────────

public enum WBSTemplate {

    /// The templates this build knows. A name a manifest asks for and this does
    /// not have is reported rather than silently ignored, the same as an unknown
    /// tool: a project that quietly starts empty looks like a bug in the app.
    public static let names = ["research-5-chapter", "analysis-report", "software-increment"]

    /// Lays down a starting breakdown for a project.
    ///
    /// Returns an empty list for `nil`, which is what `blank` asks for and a
    /// legitimate answer rather than a failure.
    public static func packages(_ template: String?, project: ProjectID) -> [WorkPackage] {
        guard let template else { return [] }
        switch template {
        case "research-5-chapter": return researchFiveChapter(project)
        case "analysis-report": return analysisReport(project)
        case "software-increment": return softwareIncrement(project)
        default: return []
        }
    }

    public static func isKnown(_ template: String?) -> Bool {
        guard let template else { return true }
        return names.contains(template)
    }

    // MARK: - templates

    /// The shape a Thai thesis is examined in: five chapters, with the
    /// instrument and its content validity standing between chapter 3 and any
    /// data at all (§20.1).
    private static func researchFiveChapter(_ project: ProjectID) -> [WorkPackage] {
        var packages: [WorkPackage] = []
        func group(_ title: String, _ deliverable: String) -> String {
            let package = WorkPackage(projectID: project, title: title,
                                      deliverableType: deliverable,
                                      acceptanceCriteria: [])
            packages.append(package)
            return package.id
        }
        func leaf(_ title: String, _ deliverable: String, under parent: String,
                  _ criteria: [(String, String)], role: Role? = nil) {
            packages.append(WorkPackage(projectID: project, parent: parent, title: title,
                                        deliverableType: deliverable,
                                        acceptanceCriteria: criteria.map { Criterion(text: $0.0, evidenceRequired: $0.1) },
                                        role: role))
        }

        let one = group("บทที่ 1 บทนำ", "เอกสารบทที่ 1")
        leaf("ความเป็นมาและความสำคัญ", "ข้อความบทที่ 1.1", under: one,
             [("อ้างอิงแหล่งที่ตรวจสอบได้อย่างน้อย 5 แหล่ง", "รายการอ้างอิงที่เปิดอ่านต้นทางได้ทุกรายการ"),
              ("ระบุช่องว่างของความรู้ชัดเจน", "ย่อหน้าที่บอกว่างานเดิมยังไม่ตอบอะไร")],
             role: .researcher)
        leaf("คำถามวิจัยและวัตถุประสงค์", "รายการคำถามวิจัย", under: one,
             [("ทุกคำถามวิจัยตอบได้ด้วยข้อมูลที่วางแผนจะเก็บ", "ตารางจับคู่คำถามวิจัยกับข้อคำถามที่จะเก็บ")], role: .researcher)

        let two = group("บทที่ 2 ทบทวนวรรณกรรม", "เอกสารบทที่ 2")
        leaf("กรอบแนวคิด", "ผังกรอบแนวคิด", under: two,
             [("ทุก construct ในกรอบผูกกับคำถามวิจัยข้อใดข้อหนึ่ง", "ผังที่ลากเส้นจาก construct ไปคำถามวิจัย")], role: .researcher)
        leaf("สังเคราะห์งานที่เกี่ยวข้อง", "ตารางสังเคราะห์วรรณกรรม", under: two,
             [("ทุกแถวมี citation ที่ชี้กลับถึงเอกสารต้นทางได้", "ตารางสังเคราะห์ที่กดที่ citation แล้วเปิดเอกสารได้")], role: .researcher)

        let three = group("บทที่ 3 วิธีดำเนินการวิจัย", "เอกสารบทที่ 3")
        leaf("ออกแบบเครื่องมือ", "แบบสอบถามฉบับร่าง", under: three,
             [("ทุกข้อผูกกับ construct หรือติดป้ายข้อมูลพื้นฐาน", "ผังข้อคำถามในแท็บเก็บข้อมูลที่ไม่มีข้อสีส้มเหลือ")], role: .researcher)
        leaf("ตรวจความตรงเชิงเนื้อหา", "ผล IOC/CVI จากผู้เชี่ยวชาญ", under: three,
             [("ผู้เชี่ยวชาญอย่างน้อย 3 คน", "รายชื่อผู้ให้คะแนนในหน้าความตรงเชิงเนื้อหา"),
              ("IOC ≥ 0.50 ทุกข้อ", "ตาราง IOC รายข้อที่คำนวณจากคะแนนจริง")], role: .researcher)
        leaf("ขอจริยธรรมการวิจัยในมนุษย์", "เลขรับรองจริยธรรม หรือคำประกาศว่าไม่เข้าข่าย", under: three,
             [("มีเอกสารที่มีเลขรับรอง หรือคำประกาศพร้อมชื่อผู้แจ้ง", "บันทึกจริยธรรมในแท็บเก็บข้อมูล")])
        leaf("เก็บข้อมูล", "ฐานข้อมูลคำตอบ", under: three,
             [("ปิดรอบเก็บข้อมูลพร้อมวันที่", "รอบที่ปิดแล้วพร้อมวันเปิด-วันปิดในหน้าคำตอบ"),
              ("จำนวนผู้ตอบถึงเกณฑ์ที่วางไว้", "จำนวนชุดคำตอบในรอบนั้น")])

        let four = group("บทที่ 4 ผลการวิจัย", "เอกสารบทที่ 4")
        leaf("ตรวจความเที่ยงของเครื่องมือ", "ค่า Cronbach's α ต่อ subscale", under: four,
             [("α ≥ 0.70 ทุก subscale หรือมีคำอธิบายที่บันทึกไว้", "ผลคำนวณ α พร้อม item-total ต่อข้อ")], role: .analyst)
        leaf("วิเคราะห์ตามคำถามวิจัย", "ตารางผลในบทที่ 4", under: four,
             [("ทุกตัวเลขในตารางผูกกลับถึง cell ในสมุดงานที่รันจริง", "สมุดงานที่รันแล้วพร้อมผลของแต่ละเซลล์")], role: .analyst)

        let five = group("บทที่ 5 สรุปและอภิปรายผล", "เอกสารบทที่ 5")
        leaf("อภิปรายผลเทียบวรรณกรรม", "ข้อความบทที่ 5", under: five,
             [("ทุกข้ออภิปรายอ้างผลในบทที่ 4 หรือวรรณกรรมในบทที่ 2", "ข้อความที่มีการอ้างอิงกำกับทุกย่อหน้า")], role: .writer)
        leaf("ข้อจำกัดและข้อเสนอแนะ", "ข้อความบทที่ 5.3", under: five,
             [("ระบุข้อจำกัดที่รู้ตัวอย่างน้อยหนึ่งข้อพร้อมผลกระทบต่อการตีความ", "ย่อหน้าข้อจำกัดที่บอกผลกระทบ ไม่ใช่แค่ชื่อข้อจำกัด")], role: .writer)

        return packages
    }

    private static func analysisReport(_ project: ProjectID) -> [WorkPackage] {
        var packages: [WorkPackage] = []
        let root = WorkPackage(projectID: project, title: "รายงานผลวิเคราะห์",
                               deliverableType: "เอกสารรายงาน", acceptanceCriteria: [])
        packages.append(root)
        let steps: [(String, String, [(String, String)], Role?)] = [
            ("ทำความเข้าใจข้อมูลต้นทาง", "บันทึกโครงสร้างข้อมูลและที่มา",
             [("ระบุที่มาของทุกตารางที่จะใช้", "บันทึกที่มาต่อหนึ่งตาราง")], .analyst),
            ("ทำความสะอาดและเตรียมข้อมูล", "สคริปต์ + log การรัน",
             [("รันซ้ำได้ผลเดิม", "log การรันสองครั้งที่ผลตรงกัน"),
              ("บันทึกจำนวนแถวที่ถูกตัดออกพร้อมเหตุผล", "ตารางสรุปแถวที่ถูกตัดต่อเงื่อนไข")], .analyst),
            ("วิเคราะห์และตรวจ assumption", "ตารางผล + ผลตรวจ assumption",
             [("ทุกการทดสอบมีผลตรวจ assumption กำกับ", "ผลตรวจ assumption ที่ออกมาพร้อมผลทดสอบ")], .analyst),
            ("สรุปข้อค้นพบ", "ข้อความสรุป", [("ทุกข้อสรุปชี้กลับถึงตารางผล", "ข้อความสรุปที่อ้างเลขตารางทุกข้อ")], .writer),
        ]
        for (title, deliverable, criteria, role) in steps {
            packages.append(WorkPackage(projectID: project, parent: root.id, title: title,
                                        deliverableType: deliverable,
                                        acceptanceCriteria: criteria.map { Criterion(text: $0.0, evidenceRequired: $0.1) },
                                        role: role))
        }
        return packages
    }

    private static func softwareIncrement(_ project: ProjectID) -> [WorkPackage] {
        var packages: [WorkPackage] = []
        let root = WorkPackage(projectID: project, title: "รอบส่งมอบแรก",
                               deliverableType: "ซอฟต์แวร์ที่ใช้งานได้", acceptanceCriteria: [])
        packages.append(root)
        let steps: [(String, String, [(String, String)], Role?)] = [
            ("ตกลงขอบเขตของรอบนี้", "รายการสิ่งที่จะส่งมอบ",
             [("ทุกข้อมีเกณฑ์ยอมรับที่ทดสอบได้", "รายการสิ่งส่งมอบที่แต่ละข้อมีเกณฑ์กำกับ")], nil),
            ("ลงมือพัฒนา", "โค้ดที่ merge แล้ว",
             [("ผ่านเทสทั้งชุด", "ผลรันเทสที่เขียวทั้งชุด"),
              ("มีคนรีวิวอย่างน้อยหนึ่งคน", "ชื่อผู้รีวิวและความเห็น")], .engineer),
            ("ทดสอบกับผู้ใช้จริง", "บันทึกผลการทดลองใช้",
             [("มีผู้ใช้จริงกดใช้อย่างน้อยหนึ่งคน พร้อมบันทึกสิ่งที่เจอ", "บันทึกการทดลองใช้พร้อมรายการสิ่งที่เจอ")], nil),
        ]
        for (title, deliverable, criteria, role) in steps {
            packages.append(WorkPackage(projectID: project, parent: root.id, title: title,
                                        deliverableType: deliverable,
                                        acceptanceCriteria: criteria.map { Criterion(text: $0.0, evidenceRequired: $0.1) },
                                        role: role))
        }
        return packages
    }
}
