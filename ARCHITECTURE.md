# Co-AI Workspace — Architecture & Spec (Swift Native, v2)

> **เอกสารนี้คือ *สเปก*** — ตอบว่า **ระบบคืออะไร และทำไมถึงเป็นแบบนั้น** ไม่ตอบว่าสร้างถึงไหนแล้ว
>
> เนื้อหาถูกแยกเป็น 6 ส่วนเมื่อ 2026-08-17 เพราะไฟล์เดียวโต 331 KB — **ไม่มีเนื้อหาไหนถูกลบ ทุก anchor ยังใช้ชื่อเดิม** ไฟล์นี้เหลือหน้าที่เป็นสารบัญ
>
> **ไม่รู้จะเริ่มตรงไหน** → [`START_HERE.md`](START_HERE.md) · **กฎที่บังคับด้วยเครื่อง** → [`RULES.md`](RULES.md) · **สร้างถึงไหนแล้ว** → [`docs/plan/README.md`](docs/plan/README.md)

---

## 6 ส่วนของสเปก

| ส่วน | เนื้อหา | อ่านเมื่อ |
|---|---|---|
| [**รากฐาน** — อ่านก่อนเสมอ](docs/architecture/01-foundations.md) | [§0 เป้าหมายและคำนิยาม](docs/architecture/01-foundations.md#0-เป้าหมายและคำนิยาม) · [§1 Web Search และการจัดชั้นแหล่งข้อมูล](docs/architecture/01-foundations.md#1-web-search-และการจัดชั้นแหล่งข้อมูล) · [§2 AI Team Model — แกนหลักของ v2](docs/architecture/01-foundations.md#2-ai-team-model--แกนหลักของ-v2) · [§3 System Hierarchy](docs/architecture/01-foundations.md#3-system-hierarchy) · [§4 Module Catalog — ภาพรวมทั้งระบบ](docs/architecture/01-foundations.md#4-module-catalog--ภาพรวมทั้งระบบ) | อยากเข้าใจว่าระบบนี้พยายามแก้ปัญหาอะไร และเลือกทางไหนไว้แล้ว |
| [**โมดูลแกน** — M1–M9](docs/architecture/02-core-modules.md) | [§5 M1 CoreEngine](docs/architecture/02-core-modules.md#5-m1-coreengine) · [§6 M2 AgentKit](docs/architecture/02-core-modules.md#6-m2-agentkit) · [§7 M3 Roster](docs/architecture/02-core-modules.md#7-m3-roster) · [§8 M4 Channels](docs/architecture/02-core-modules.md#8-m4-channels) · [§9 M5 LLMProviders](docs/architecture/02-core-modules.md#9-m5-llmproviders) · [§10 M6 ToolBelt](docs/architecture/02-core-modules.md#10-m6-toolbelt) · [§11 M7 Knowledge](docs/architecture/02-core-modules.md#11-m7-knowledge) · [§12 M8 Analysis](docs/architecture/02-core-modules.md#12-m8-analysis) · [§13 M9 Execution](docs/architecture/02-core-modules.md#13-m9-execution) | กำลังจะแก้หรือเพิ่มความสามารถในโมดูลใดโมดูลหนึ่ง |
| [**หน้าจอ · คอนฟิก · ฮาร์ดแวร์**](docs/architecture/03-surfaces-and-ops.md) | [§14 M10 DocGen · M13 WorkspaceUI](docs/architecture/03-surfaces-and-ops.md#14-m10-docgen--m13-workspaceui) · [§15 M11 Config & Secrets](docs/architecture/03-surfaces-and-ops.md#15-m11-config--secrets) · [§16 M12 Observability & Eval](docs/architecture/03-surfaces-and-ops.md#16-m12-observability--eval) · [§17 Hardware Topology & Deployment](docs/architecture/03-surfaces-and-ops.md#17-hardware-topology--deployment) · [§18 Non-Functional Requirements](docs/architecture/03-surfaces-and-ops.md#18-non-functional-requirements) | กำลังทำหน้าจอ · ตั้งค่า · secrets · หรือเรื่องเครื่อง GX10 |
| [**Project Management** — M14](docs/architecture/04-project-management.md) | [§19 Project Environment & Project Management (M14 ProjectKit)](docs/architecture/04-project-management.md#19-project-environment--project-management-m14-projectkit) | กำลังทำอะไรที่เกี่ยวกับโปรเจกต์ · WBS · gate · ทะเบียน · รายงาน |
| [**งานวิจัย · ความสามารถ agent**](docs/architecture/05-research.md) | [§20 Research Program — งานวิจัยที่เดินบนโครง PM (M15 Instruments)](docs/architecture/05-research.md#20-research-program--งานวิจัยที่เดินบนโครง-pm-m15-instruments) · [§21 Agent Competence Model — อะไรทำให้ agent แต่ละตัวต่างกัน](docs/architecture/05-research.md#21-agent-competence-model--อะไรทำให้-agent-แต่ละตัวต่างกัน) | กำลังทำเครื่องมือวิจัย · สถิติ · การเก็บข้อมูลจากคน · หรือ knowledge view |
| [**องค์กร · ควบคุมเครื่อง · ระบบออกแบบ**](docs/architecture/06-organisation-and-ui.md) | [§22 AI Organization — จากทีมเดียวเป็นองค์กร (M17 Command)](docs/architecture/06-organisation-and-ui.md#22-ai-organization--จากทีมเดียวเป็นองค์กร-m17-command) · [§23 Machine Control — ให้ระบบทดสอบหน้าจอตัวเองได้ (M18 ScreenDriver)](docs/architecture/06-organisation-and-ui.md#23-machine-control--ให้ระบบทดสอบหน้าจอตัวเองได้-m18-screendriver) · [§24 Design System & Human Interface Guidelines (M13)](docs/architecture/06-organisation-and-ui.md#24-design-system--human-interface-guidelines-m13) | กำลังทำองค์กรหลายทีม · ตัวขับหน้าจอ · หรือระบบการออกแบบ |

---

## ทุกหัวข้อ เรียงตามเลข

| § | หัวข้อ | อยู่ในไฟล์ |
|---|---|---|
| **0** | [เป้าหมายและคำนิยาม](docs/architecture/01-foundations.md#0-เป้าหมายและคำนิยาม) | `01-foundations.md` |
| **1** | [Web Search และการจัดชั้นแหล่งข้อมูล](docs/architecture/01-foundations.md#1-web-search-และการจัดชั้นแหล่งข้อมูล) | `01-foundations.md` |
| **2** | [AI Team Model — แกนหลักของ v2](docs/architecture/01-foundations.md#2-ai-team-model--แกนหลักของ-v2) | `01-foundations.md` |
| **3** | [System Hierarchy](docs/architecture/01-foundations.md#3-system-hierarchy) | `01-foundations.md` |
| **4** | [Module Catalog — ภาพรวมทั้งระบบ](docs/architecture/01-foundations.md#4-module-catalog--ภาพรวมทั้งระบบ) | `01-foundations.md` |
| **5** | [M1 CoreEngine](docs/architecture/02-core-modules.md#5-m1-coreengine) | `02-core-modules.md` |
| **6** | [M2 AgentKit](docs/architecture/02-core-modules.md#6-m2-agentkit) | `02-core-modules.md` |
| **7** | [M3 Roster](docs/architecture/02-core-modules.md#7-m3-roster) | `02-core-modules.md` |
| **8** | [M4 Channels](docs/architecture/02-core-modules.md#8-m4-channels) | `02-core-modules.md` |
| **9** | [M5 LLMProviders](docs/architecture/02-core-modules.md#9-m5-llmproviders) | `02-core-modules.md` |
| **10** | [M6 ToolBelt](docs/architecture/02-core-modules.md#10-m6-toolbelt) | `02-core-modules.md` |
| **11** | [M7 Knowledge](docs/architecture/02-core-modules.md#11-m7-knowledge) | `02-core-modules.md` |
| **12** | [M8 Analysis](docs/architecture/02-core-modules.md#12-m8-analysis) | `02-core-modules.md` |
| **13** | [M9 Execution](docs/architecture/02-core-modules.md#13-m9-execution) | `02-core-modules.md` |
| **14** | [M10 DocGen · M13 WorkspaceUI](docs/architecture/03-surfaces-and-ops.md#14-m10-docgen--m13-workspaceui) | `03-surfaces-and-ops.md` |
| **15** | [M11 Config & Secrets](docs/architecture/03-surfaces-and-ops.md#15-m11-config--secrets) | `03-surfaces-and-ops.md` |
| **16** | [M12 Observability & Eval](docs/architecture/03-surfaces-and-ops.md#16-m12-observability--eval) | `03-surfaces-and-ops.md` |
| **17** | [Hardware Topology & Deployment](docs/architecture/03-surfaces-and-ops.md#17-hardware-topology--deployment) | `03-surfaces-and-ops.md` |
| **18** | [Non-Functional Requirements](docs/architecture/03-surfaces-and-ops.md#18-non-functional-requirements) | `03-surfaces-and-ops.md` |
| **19** | [Project Environment & Project Management (M14 ProjectKit)](docs/architecture/04-project-management.md#19-project-environment--project-management-m14-projectkit) | `04-project-management.md` |
| **20** | [Research Program — งานวิจัยที่เดินบนโครง PM (M15 Instruments)](docs/architecture/05-research.md#20-research-program--งานวิจัยที่เดินบนโครง-pm-m15-instruments) | `05-research.md` |
| **21** | [Agent Competence Model — อะไรทำให้ agent แต่ละตัวต่างกัน](docs/architecture/05-research.md#21-agent-competence-model--อะไรทำให้-agent-แต่ละตัวต่างกัน) | `05-research.md` |
| **22** | [AI Organization — จากทีมเดียวเป็นองค์กร (M17 Command)](docs/architecture/06-organisation-and-ui.md#22-ai-organization--จากทีมเดียวเป็นองค์กร-m17-command) | `06-organisation-and-ui.md` |
| **23** | [Machine Control — ให้ระบบทดสอบหน้าจอตัวเองได้ (M18 ScreenDriver)](docs/architecture/06-organisation-and-ui.md#23-machine-control--ให้ระบบทดสอบหน้าจอตัวเองได้-m18-screendriver) | `06-organisation-and-ui.md` |
| **24** | [Design System & Human Interface Guidelines (M13)](docs/architecture/06-organisation-and-ui.md#24-design-system--human-interface-guidelines-m13) | `06-organisation-and-ui.md` |

---

## ภาคผนวก — ย้ายออกเป็นเอกสารอ้างอิงแยก

เนื้อหาอ้างอิงทั้งหมดถูกย้ายออกจากไฟล์นี้เมื่อ 2026-08-15 เพื่อให้สเปกอ่านจบได้โดยไม่ต้องเลื่อนผ่านบันทึกการวัด — **ไม่มีเนื้อหาไหนถูกลบ**

| เดิม | ตอนนี้อยู่ที่ | อ่านเมื่อ |
|---|---|---|
| ภาคผนวก A — Legacy Feature Inventory | [`docs/LEGACY_V1.md`](docs/LEGACY_V1.md) | อยากรู้ว่า v1 มีอะไร · เช็คว่า feature ไหนหล่นระหว่างย้าย |
| ภาคผนวก B — Decisions Log | [`docs/DECISIONS.md`](docs/DECISIONS.md) | กำลังจะเสนอทางใหม่ — เช็คก่อนว่าเรื่องนั้นเคยถูกตัดสินไปแล้วหรือยัง |
| ภาคผนวก C — Engineering Notes | [`docs/ENGINEERING_NOTES.md`](docs/ENGINEERING_NOTES.md) | เจออาการแปลกกับ SurrealDB / การ bind ค่า / decoding JSON |
| ภาคผนวก D — Open Questions | [`docs/DECISIONS.md#d-open-questions--ปิดครบแล้ว`](docs/DECISIONS.md#d-open-questions--ปิดครบแล้ว) | อยากรู้ว่าคำถามก่อนล็อกสถาปัตยกรรมถูกตอบด้วยอะไร (ปิดครบ 10 ข้อ) |
| ภาคผนวก E — Verification Log | [`docs/VERIFICATION_LOG.md`](docs/VERIFICATION_LOG.md) | กำลังจะสรุปว่า "API นี้น่าจะทำได้" — ที่นี่บอกว่าวัดแล้วได้อะไรจริง |
| §1.1–1.3 Ecosystem Review | [`docs/ECOSYSTEM_REVIEW.md`](docs/ECOSYSTEM_REVIEW.md) | อยากรู้ที่มาของการเลือก Swift native / provider abstraction |

---

## เอกสารนี้กับส่วนอื่นของโปรเจกต์

เอกสารนี้เป็น **สเปก** — ตอบว่า *ระบบคืออะไรและทำไม* ไม่ตอบว่า *สร้างถึงไหนแล้ว*

| ถ้าอยากรู้ | อ่านที่ |
|---|---|
| สร้างอะไรก่อนหลัง · แต่ละ Task เสร็จแล้วหรือยัง · Done-when คืออะไร | [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) |
| ขับแอปด้วยมือแล้วเจออะไร (บั๊กที่เทสมองไม่เห็น) | [`docs/DRIVING_LOG.md`](docs/DRIVING_LOG.md) |
| ภาพรวมโปรเจกต์สำหรับคนนอก | [`README.md`](README.md) |
| โค้ด spike ที่รันผ่านจริงแล้ว | [`spikes/`](spikes/) |
