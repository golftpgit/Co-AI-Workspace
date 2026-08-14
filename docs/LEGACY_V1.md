# Legacy v1 — Feature Inventory, บทเรียน และ Completeness Checklist

> เอกสารอ้างอิง · ระบบเดิม (Rust + Tauri + React) ถูกแทนที่ด้วย Swift native v2
> ทุก feature / bug / บทเรียน ของ v1 ถูกบันทึกไว้ที่นี่ครบ — **ลบโฟลเดอร์ `OldARCHITECTURE/` ได้โดยไม่สูญเสียข้อมูล**
>
> อ่านเมื่อ: อยากรู้ว่า v1 มีอะไร · ทำไม v2 ตัดสินใจต่างออกไป · หรือเช็คว่ามี feature ไหนหล่นหายระหว่างย้าย

| ส่วน | เนื้อหา |
|---|---|
| [A.1](#a1-feature-audit-เดิม-21-ข้อ-จาก-user-feedback-2026-08-08--ที่อยู่ใน-v2) | Feature audit 21 ข้อ → ที่อยู่ใน v2 |
| [A.2](#a2-code-deviation-d1d7-บทเรียนจากการ-implement-จริง) | Code deviation D1–D7 |
| [A.3](#a3-bug-สำคัญที่เจอใน-v1-v2-ต้องไม่ทำซ้ำ) | Bug ที่ v2 ต้องไม่ทำซ้ำ |
| [A.4](#a4-phase-aj-ของ-v1-งานที่ทำเสร็จแล้ว--เป็น-scope-reference-ของ-v2) | Phase A–J ของ v1 |
| [Completeness Checklist](#completeness-checklist--v1--v2-task) | เช็คว่าไม่มี feature จาก v1 หล่น |

---


ตารางนี้ทำให้ลบ `OldARCHITECTURE/` ได้ — ทุก feature/สถานะ/บทเรียนจากระบบเดิมถูกบันทึกไว้ที่นี่แล้ว

## A.1 Feature Audit เดิม 21 ข้อ (จาก user feedback 2026-08-08) → ที่อยู่ใน v2

| # | Feature เดิม | สถานะใน v1 | ที่อยู่ใน v2 |
|---|---|---|---|
| 1 | Rebrand ชื่อแอป | DONE (display name) | v2 ชื่อ **Co-AI Workspace** — internal id ตั้งใหม่ได้ตั้งแต่ต้น ไม่มี legacy data ผูก |
| 2 | Folder picker แบบ Finder ตอนสร้าง project | DONE | M13 — `NSOpenPanel` native |
| 3 | แยก chat/workflow/agent เป็น general vs per-project | PARTIAL (KB + DB connector มี scope) | M2 `enum Scope` ใช้ร่วมทุก entity ตั้งแต่ต้น |
| 4 | Workflow Builder: list, drag-drop, tool palette แบบ n8n | DONE (Phase D) | M13 Workflow Builder |
| 5 | Knowledge Base: scope display, entity/relation graph, edit/delete, PDF/DOCX/PPTX, ingest agent, export/import, categorization | DONE ยกเว้น OCR | M7 — **OCR ปิดด้วย Vision framework** |
| 6 | Approval แทรกในขั้นตอนต่างๆ | DONE | M1 §5.4 — 3 จุด (Chat inline, Workflow card, หน้า Approvals) |
| 7 | แจ้งเตือน Telegram + macOS native | DONE | M4 `Notifier` |
| 8 | หลาย frontier model + local + แยกตาม agent | DONE (named OpenAI-compatible endpoints) | M5 EndpointRegistry — **ทบทวนแล้วคง decision เดิม: ไม่ทำ native SDK ต่อเจ้า** |
| 9 | External DB หลายชนิด + scope | DONE (PG/MySQL/SQLite/MSSQL/MongoDB) | M8 DBConnectors |
| 10 | เข้าถึง/แก้ embedded DB ได้เองในแอป | DONE (Phase G) | M13 DB Explorer |
| 11 | MCP servers follow protocol | DONE (tools+resources+prompts, Phase H) | M6 MCPBridge — ใช้ official Swift SDK + SwiftMCP |
| 12 | Skill creation UI + import/export + agent เขียน skill เอง | DONE (Phase H) | M3 Roster |
| 13 | Bridge หลาย bot/หลาย platform | DONE (Phase I: Telegram+Discord+LINE, multi-account) | M4 Channels |
| 14 | Subwindow ดู/แก้ไฟล์ | DONE (md/txt/code) | M13 File Viewer — v2 ขยายรองรับ docx/pptx/pdf view |
| 15 | Plugin system | DONE (Phase J — plugin = packaged MCP server) | M3 PluginRegistry |
| 16 | Tag วัตถุประสงค์ตอนสร้าง project | DONE (Phase E) | M13 + M2 |
| 17 | Big data analysis แบบ Jupyter | DONE (Phase J — SQL+Python cell) | M8 NotebookKernel |
| 18 | Agent ช่วย config/ติดตั้ง tool | DONE (Phase J — `install_package`) | M6 `install_package` |
| 19 | ตั้ง LM Studio endpoint | ใช้งานได้ | M5 EndpointRegistry |
| 20 | แสดงสถานะการเชื่อมต่อ (LLM/DB/MCP) | DONE (Phase E — persistent badge) | M5 + M13 |
| 21 | แสดงสถานะ agent + background process | DONE (Phase D/E — Live Monitor + Processes page) | M12 span store (แหล่งเดียว) |

## A.2 Code Deviation D1–D7 (บทเรียนจากการ implement จริง)

| # | ปัญหาที่เจอใน v1 | บทเรียนสำหรับ v2 |
|---|---|---|
| D1 | Embedding เป็น placeholder (hash) ทั้งระบบก่อนถูกจับได้ | **ห้ามปล่อย placeholder ที่ดูเหมือนทำงาน** — v2 ต้องมี eval ของ retrieval quality ตั้งแต่วัน 1 (v1 เลือก `all-MiniLM-L6-v2` เพราะ 384 มิติตรงกับ schema, 6 layer/22M param เบาพอ) |
| D2 | research-agent ไม่มี web search เลยแม้ diagram จะวาดไว้ | v1 แก้ด้วย DDG HTML scraping (DDG ไม่มี public API จริงสำหรับ organic result) → **v2 ใช้ SearXNG sidecar** ([§1.2](../ARCHITECTURE.md#12-web-search--มีของฟรีถาวรไหม-apple-ให้ด้วยไหม)) |
| D3 | ไม่มี code-agent เฉพาะ | **จงใจไม่แยก** — งานโค้ดต้อง context เต็ม + hook chain ครบ ตรงกับคำเตือนของ Cognition → v2 [§2.4](../ARCHITECTURE.md#24-ข้อยกเว้น-งานที่ห้ามแตกทีม) |
| D4 | Chunking ไม่รองรับไทย | v1 wrap `nlpo3` (newmm) → **v2 ใช้ NLTokenizer แต่ต้องเทียบคุณภาพก่อน** |
| D5 | Config ไม่มี schema versioning/migration | v2 มีตั้งแต่ต้น ([§15](../ARCHITECTURE.md#15-m11-config--secrets)) |
| D6 | MCP tool มีโค้ดครบแต่ไม่เคยถูกต่อเข้า tool list จริง | **บทเรียน**: มี implementation ≠ มี feature — v2 ต้องมี integration test ที่พิสูจน์ว่า tool ปรากฏใน session จริง |
| D7 | ไม่มี BM25/full-text index — "hybrid search" ไม่เคยเกิดขึ้นจริง | v2 ต้อง index ทั้ง vector + full-text ตั้งแต่ ingestion แรก |

## A.3 Bug สำคัญที่เจอใน v1 (v2 ต้องไม่ทำซ้ำ)

| # | Bug | ป้องกันใน v2 ยังไง |
|---|---|---|
| B2 🔴 | **Telegram bridge ข้าม Critic/Risk/HITL ทั้งหมด** — สร้าง `AgentLoop` เองพร้อม `ShellTool` = remote shell ไม่มี approval | [§3](../ARCHITECTURE.md#3-system-hierarchy) invariant: channel execute tool เองไม่ได้เลยเชิงโครงสร้าง |
| B3 | Workflow node-ID collision หลัง load | id เป็น UUID ไม่ใช่ counter |
| B4 | Settings panel กลืน error เงียบ (แสดงหน้าว่าง) | pattern เดียวกันทุก panel + `Result` type ที่ compiler บังคับ handle |
| B5 | Live Monitor เสีย state ทุกครั้งที่สลับหน้า, event หายเงียบ | M12 span store เป็น DB-backed ไม่ใช่ in-memory ของ view |
| B7 | ไม่มี accessibility เลยทั้ง frontend | [§14.2](../ARCHITECTURE.md#142-workspaceui--หน้าจอทั้งหมด) — requirement ตั้งแต่ต้น |
| B9 | หน้าต่างไม่มี minWidth/resizable, error ยาวล้นกรอบ | SwiftUI window sizing + text wrapping ตั้งแต่ต้น |

## A.4 Phase A–J ของ v1 (งานที่ทำเสร็จแล้ว — เป็น scope reference ของ v2)

| Phase | ขอบเขต | v2 อยู่ที่ |
|---|---|---|
| A | Session persistence (conversation/message ใน DB, history โหลดจาก DB ทุกครั้ง) | M1 + M7 |
| B | Long-horizon execution (task/checkpoint ใน DB, token accounting, compaction, stop flag, external-truth-gated done) | M1 §5.6–5.7 |
| C | Declarative agent setup (manifest loader, risk classification ต่อ tool, registry-driven dispatch) | M3 |
| D | Config migration, skill self-authoring, process manager, workflow palette, file viewer | M11/M3/M12/M13 |
| E | Scope ต่อ workflow/agent, connection badge, completion notification, project purpose tag | M2/M5/M4/M13 |
| F | Approval UI ใน workflow step card (+ พบว่า workflow execution เดิมไม่ผ่าน gate เลย) | M1 §5.4 |
| G | DB Explorer (ad-hoc SurrealQL/SQL) | M13 |
| H | MCP resources/prompts + skill CRUD/import/export + usage logging | M6/M3/M12 |
| I | Generic Bridge trait + Telegram/Discord/LINE multi-account | M4 |
| J | Notebook (SQL+Python), plugin system, `install_package` | M8/M3/M6 |

**งานที่ v1 ยังค้าง (Phase K)**: K1 Telegram remote-approval → **v2 ได้ฟรีจาก [§5.4](../ARCHITECTURE.md#54-approval-broker-sub-module)** · K2 OCR → **v2 ได้ฟรีจาก Vision framework** · K3 compaction handoff extraction → **ยังค้างอยู่ ต้อง design ใหม่**

---

## Completeness Checklist — v1 → v2 Task


เช็คว่าไม่มีอะไรจาก v1 หล่น — อ้างอิง [A.1](#a1-feature-audit-เดิม-21-ข้อ-จาก-user-feedback-2026-08-08--ที่อยู่ใน-v2)

| v1 (Phase A–J + audit 21 ข้อ) | v2 Task |
|---|---|
| Session persistence | P1.3 |
| Long-horizon / run-until-done | P4.8, P4.9 |
| Declarative agent setup | P8.1, P8.2 |
| Config migration + schema | P0.3, P9.2 |
| Skill self-authoring | P8.5 |
| Process manager | P1.9, P8.6 |
| Workflow builder + palette | P8.6 |
| File viewer/editor | P8.6 |
| Scope ต่อ entity | P1.1 (`Scope` ตัวเดียว) |
| Connection status badge | P5.5 |
| Completion notification | P7.5 |
| Project purpose tag | P8.6 |
| Approval ใน workflow card | P1.8 + P8.6 |
| DB Explorer | P6.5, P6.8 |
| MCP resources/prompts | P8.3 |
| Skill CRUD + import/export | P8.5, P8.6 |
| Bridge trait + 3 platform + multi-account | P7.1–P7.3 |
| Notebook (SQL+Python) | P6.4, P6.8 |
| Plugin system | P8.4 |
| `install_package` | P8.4 |
| KB: PDF/DOCX/PPTX, graph, export/import | P2.3, P2.7 |
| **K1 Telegram remote approval** (ค้างใน v1) | P7.1 — ได้ฟรีจาก Approval Broker |
| **K2 OCR** (ค้างใน v1) | P2.3 — ได้ฟรีจาก Vision |
| **K3 compaction extraction** (ค้างใน v1) | P4.9 — ต้อง design จริง ไม่มีทางลัด |

