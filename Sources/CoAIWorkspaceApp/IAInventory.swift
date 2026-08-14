import SwiftUI

// ─────────────────────────────────────────────────────────────
// Where every screen from §14.2 went (ARCHITECTURE §19.2, P10.12).
//
// Risk R13 names this task's failure mode exactly: "ยุบ 14 หน้าจอเป็น 4 พื้นที่
// แล้วของหาย". It is the same mistake as v1's `Scope.project` — a
// reorganisation that reads as complete because the new structure is tidy, while
// two of the old screens quietly have no home.
//
// So the mapping is data rather than a claim in a commit message: one row per
// §14.2 entry, saying which area and sub-tab it lives in and what state it is
// actually in. `check.sh` parses §14.2's table out of ARCHITECTURE.md and fails
// if a row here is missing — a screen cannot be dropped by being forgotten,
// only by being deleted from the standard it is measured against.
//
// The three states are deliberately distinguished. "ยังไม่ได้ทำ" with a task
// number is an honest answer; a row silently absent is not.
// ─────────────────────────────────────────────────────────────

struct IAEntry: Identifiable {
    enum State {
        /// Everything §14.2 lists for this screen is reachable.
        case done
        /// Reachable, but some of what §14.2 lists is not there yet.
        case partial(String)
        /// Not built. The task that will build it is named.
        case notBuilt(String)

        var label: String {
            switch self {
            case .done: "ครบ"
            case .partial: "บางส่วน"
            case .notBuilt: "ยังไม่ได้ทำ"
            }
        }

        var note: String? {
            switch self {
            case .done: nil
            case .partial(let text), .notBuilt(let text): text
            }
        }
    }

    /// The name as §14.2 spells it. Matched against the document by check.sh, so
    /// this string is not free text.
    let screen: String
    let area: String
    let subTab: String
    let state: State

    var id: String { screen }
}

enum IAInventory {
    /// One row per §14.2 screen, in that table's order.
    static let entries: [IAEntry] = [
        IAEntry(screen: "Chat", area: "สนทนา", subTab: "บทสนทนา",
                state: .done),
        IAEntry(screen: "Team View", area: "สนทนา", subTab: "แถบขวา: เฝ้าดูทีม",
                state: .partial("ส่วน *ตั้งค่า* ทีมย้ายไปอยู่ Plan → ทีม & RACI ตาม §19.2.5 — "
                                + "หน้านี้เหลือเฉพาะการเฝ้าดูและสั่งรายงาน")),
        IAEntry(screen: "Live Monitor", area: "สนทนา", subTab: "แถบขวา: เฝ้าดูทีม",
                state: .partial("การ์ดต่อ step ยังไม่มี — เห็น assignment กับสถานะ QA "
                                + "แต่ยังกดขยายดู raw output ต่อ step ไม่ได้")),
        IAEntry(screen: "Approvals", area: "สนทนา", subTab: "แถบอนุมัติในบทสนทนา",
                state: .partial("อนุมัติ inline ได้จริงในบทสนทนา · ยังไม่มีรายการรวมข้ามบทสนทนา")),
        IAEntry(screen: "Notebook", area: "โต๊ะทำงาน", subTab: "สคริปต์ + คอนโซล",
                state: .done),
        IAEntry(screen: "DB Explorer", area: "โต๊ะทำงาน",
                subTab: "ฐานข้อมูลภายใน · ฐานข้อมูลภายนอก",
                state: .done),
        IAEntry(screen: "Knowledge Base", area: "คลังความรู้", subTab: "เอกสาร",
                state: .partial("กราฟ entity/relation แสดงเป็นรายการต่อส่วน ยังไม่ใช่ภาพกราฟ")),
        IAEntry(screen: "Conflict Ledger", area: "คลังความรู้", subTab: "ข้อขัดแย้ง",
                state: .done),
        IAEntry(screen: "Models", area: "ระบบ", subTab: "โมเดล",
                state: .done),
        IAEntry(screen: "Workflow Builder", area: "โต๊ะทำงาน", subTab: "สคริปต์ + คอนโซล",
                state: .notBuilt("P8.6 — ยังไม่มี node editor · วันนี้เขียนเป็นสคริปต์/สมุดงานแทน")),
        IAEntry(screen: "Templates", area: "โต๊ะทำงาน", subTab: "ผลลัพธ์ + เอกสาร",
                state: .partial("เรียนแม่แบบจากไฟล์ .docx ที่อัปโหลดได้แล้ว · "
                                + "ยังไม่มีหน้าจัดการแม่แบบเป็นของตัวเอง")),
        IAEntry(screen: "File Viewer/Editor", area: "โต๊ะทำงาน", subTab: "สคริปต์ + คอนโซล",
                state: .notBuilt("P8.6 — ยังเปิด/แก้ไฟล์ในแอปไม่ได้")),
        IAEntry(screen: "Processes", area: "สนทนา", subTab: "แถบขวา: โปรเซส",
                state: .partial("เห็นโปรเซสที่รันอยู่และสั่งหยุดได้ · ยังไม่มีตารางข้ามทุกบทสนทนา")),
        IAEntry(screen: "Settings", area: "ระบบ", subTab: "งบ + endpoint · โมเดล · ปลั๊กอิน",
                state: .partial("มีหมวด inference/งบ/โมเดล/ปลั๊กอิน/MCP · หมวดที่เหลือใน §15 "
                                + "ยังไม่มีหน้า (P8.6)")),
        // Not in §14.2 because it did not exist then. Listed so the inventory is
        // the whole app rather than only the parts that were reorganised.
        IAEntry(screen: "Plan", area: "แผนงาน",
                subTab: "ภาพรวม · แผนงาน+ลำดับ · กระดานงาน · ทีม & RACI · ประโยชน์ & ปิดงาน",
                state: .done),
        IAEntry(screen: "เก็บข้อมูล", area: "โต๊ะทำงาน", subTab: "เก็บข้อมูล",
                state: .partial("ออกแบบเครื่องมือ · ประตูก่อนเก็บข้อมูล · เปิดฟอร์มในวงแลน · "
                                + "รอบเก็บข้อมูลที่ปิดแล้วปิดจริง · ตารางคำตอบพร้อมบันทึกการแก้ไข — "
                                + "ยังไม่มี: กรอกต่อทีหลัง (resume token) · รหัสนิรนามสำหรับงานหลายรอบ · "
                                + "materialize เข้า DuckDB (P11.7/P11.7b)")),
        IAEntry(screen: "แหล่งและ tier", area: "คลังความรู้", subTab: "แหล่งและ tier",
                state: .partial("ดูทะเบียนแหล่งและ tier ได้ · เปิด/ปิดรายแหล่งยังไม่บันทึกถาวร (P13)")),
    ]
}

/// The inventory, on screen. R13 asks for a checklist per item, and a checklist
/// only a developer can read is a checklist the person who cares cannot use.
struct IAInventoryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("หน้าจอเดิมอยู่ที่ไหนแล้ว")
                    .font(.headline)
                Text("ตาราง §14.2 ของสถาปัตยกรรมมี 14 หน้า · จัดใหม่เป็น 4 พื้นที่ + ระบบ "
                     + "ตาราง §19.2 · แถวไหนยังไม่ได้ทำจะบอกตรง ๆ พร้อมเลข task "
                     + "— `check.sh` จะแดงถ้ามีหน้าใน §14.2 ที่ไม่มีแถวที่นี่")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(IAInventory.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(entry.screen).font(.callout).bold()
                            Text("→ \(entry.area) · \(entry.subTab)")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.state.label)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(tint(entry.state).opacity(0.18), in: Capsule())
                                .foregroundStyle(tint(entry.state))
                        }
                        if let note = entry.state.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.screen) อยู่ที่ \(entry.area) \(entry.subTab) — "
                                        + "\(entry.state.label) \(entry.state.note ?? "")")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tint(_ state: IAEntry.State) -> Color {
        switch state {
        case .done: .green
        case .partial: .orange
        case .notBuilt: .secondary
        }
    }
}
