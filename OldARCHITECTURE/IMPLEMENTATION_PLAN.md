# แผนการพัฒนา (Implementation Plan) — ระบบ AI Agent (Rust)

เอกสารนี้บอก **สถานะปัจจุบัน** แบบ Phase → Task → SubTask และ**งานที่เหลือเท่านั้น** — Phase ที่ปิดจบแล้วสรุปบรรทัดเดียว+ลิงก์ archive, ไม่ลง sub-task ซ้ำที่นี่ (เลือกแบบ **lean forward-looking** ตอน rewrite 2026-08-09 รอบสาม เพื่อไม่ให้ไฟล์นี้ยาวขึ้นเรื่อยๆ ตามจำนวน phase ที่ปิดแล้ว) รายละเอียดเต็มของทุก phase ที่ DONE (ใครทำอะไร เจอ bug/quirk อะไร เทสกี่ตัว) อยู่ที่ [`LOG_ARCHIVE.md` §23 — Build History](LOG_ARCHIVE.md#23-build-history) ทั้งหมด

> แยกจาก `ARCHITECTURE.md` ฉบับรวมเดิมเมื่อ 2026-08-09 — ดู [`ARCHITECTURE.md`](ARCHITECTURE.md) สำหรับ spec เต็ม, [`LOG.md`](LOG.md) สำหรับ decision/bug ที่ยัง active, [`LOG_ARCHIVE.md`](LOG_ARCHIVE.md) สำหรับประวัติที่ปิดจบแล้ว

## สารบัญ

- [Completed Phases](#completed-phases-สรุปบรรทัดเดียว-รายละเอียดเต็มที่-archive) — Phase A–J สรุปสถานะ
- [Remaining Work](#remaining-work-phase-k) — Phase K: Task → SubTask ของงานที่ยังไม่เสร็จ
- [Open Decisions](#open-decisions-ยังไม่ scope-เป็น-task) — ยังไม่ตัดสินใจว่าจะทำหรือไม่ทำ
- [Known Debt / Deferred Cleanup](#known-debt--deferred-cleanup) — พบระหว่าง review 2026-08-09, ตั้งใจเลื่อนไปทำหลังเอกสาร
- **ดูเพิ่ม**: [← Architecture](ARCHITECTURE.md) · [Log (active) →](LOG.md) · [Log (archive) →](LOG_ARCHIVE.md)

---

## Completed Phases (สรุปบรรทัดเดียว, รายละเอียดเต็มที่ archive)

ทุก Phase ด้านล่างนี้ ✅ **DONE ครบ** ณ 2026-08-09 — sub-task ID (เช่น A1–A5) กับรายละเอียด implementation เต็มอยู่ที่ลิงก์ "รายละเอียด →" ของแต่ละแถวเท่านั้น ไม่ทำซ้ำที่นี่

| Phase | ขอบเขต | สถานะ | รายละเอียด |
|---|---|---|---|
| **A** — Session Persistence | บทสนทนา/ข้อความ persist ลง SurrealDB แทน frontend state ล้วน | ✅ DONE (2026-08-08) | [§23.4 →](LOG_ARCHIVE.md#23-build-history) |
| **B** — Long-Horizon Execution | "Run until done" mode — outer loop, task/checkpoint ใน DB, budget-aware compaction | ✅ DONE (2026-08-09) | [§23.5 →](LOG_ARCHIVE.md#23-build-history) |
| **C** — Declarative Agent/Tool Setup | `agent-registry` manifest loader, custom agent full tool allowlist | ✅ DONE (2026-08-09) | [§23.6 →](LOG_ARCHIVE.md#23-build-history) |
| **D** — Backlog เดิม (P2) | config schema migration, skill self-authoring, process-manager panel, workflow tool palette, file viewer/editor — งานที่เหลือของ backlog นี้ (DB connector เพิ่มเติม/plugin/Jupyter UI/`install_package`) ถูกดูดเข้า Phase E–J แล้ว | ✅ DONE (2026-08-09) | [§23.7 →](LOG_ARCHIVE.md#23-build-history) |
| **E** — เล็ก, independent | scope สำหรับ workflow/agent, connection-status badge, task/chat-done notification, project purpose tag | ✅ DONE (2026-08-09) | [§23.8 →](LOG_ARCHIVE.md#23-build-history) |
| **F** — Workflow Approval UI | approval แทรกใน Workflow step card ตรงๆ (พบ+แก้ bug: workflow execution เดิมไม่ผ่าน gate เลย) | ✅ DONE (2026-08-09) | [§23.9 →](LOG_ARCHIVE.md#23-build-history) |
| **G** — Ad-hoc DB Query UI | sidebar "DB Explorer" — รัน SurrealQL/SQL ตรงกับ KB store + analysis store | ✅ DONE (2026-08-09) | [§23.10 →](LOG_ARCHIVE.md#23-build-history) |
| **H** — MCP Resources/Prompts + Skill UI | `resources/list`/`resources/read`/`prompts/*`, skill creation UI + import/export + usage-logging | ✅ DONE (2026-08-09) | [§23.11 →](LOG_ARCHIVE.md#23-build-history) |
| **I** — Generic Bridge Trait | `bridge-core::Bridge` trait, multi-account Telegram + Discord + LINE | ✅ DONE (2026-08-09) | [§23.12 →](LOG_ARCHIVE.md#23-build-history) |
| **J** — Notebook UI + Plugin System | Jupyter-style notebook (SQL + Python cell), plugin = packaged MCP server, `install_package` tool | ✅ DONE (2026-08-09) | [§23.13 →](LOG_ARCHIVE.md#23-build-history) |

**Feature audit ต้นฉบับ** (21 ข้อจาก user feedback + 7 code-deviation D1–D7 เทียบ spec เดิม) ปิดครบทุกข้อ ยกเว้น 2 รายการที่ยังเป็นงานเปิดอยู่ — ย้ายไปอยู่ใน [Remaining Work](#remaining-work-phase-k) ด้านล่างแล้ว (ไม่ค้างเป็นตารางแยกที่นี่อีก) รายละเอียดเต็มของทุกข้อที่ปิดแล้วอยู่ที่ [LOG_ARCHIVE.md §23.1](LOG_ARCHIVE.md#231-feature-gaps--user-feedback-audit-บันทึกดั้งเดิม-2026-08-08)/[§23.2](LOG_ARCHIVE.md#232-โค้ดจริงเบี่ยงจากแผนเดิมของเอกสารนี้เอง-บันทึกดั้งเดิม-2026-08-08)

---

## Remaining Work (Phase K)

Phase เดียวที่ยังเปิดอยู่จริง ณ 2026-08-09 — งานที่ **ตกลงจะทำ** (ต่างจาก [Open Decisions](#open-decisions-ยังไม่-scope-เป็น-task) ที่ยังไม่ตัดสินใจ)

### Task K1 — Telegram Remote-Approval Flow `[P0]`

High-risk tool call ที่ trigger จาก Telegram bridge approve ได้แค่ผ่าน GUI/native notification เท่านั้นตอนนี้ (คนละเรื่องกับ [Log B2](LOG_ARCHIVE.md#21-ข้อค้นพบใหม่จาก-uxarchitecture-review-2026-08-09) ที่ปิดไปแล้ว — B2 คือ hook-chain bypass, ส่วนนี้คือ **remote-approval UX** ที่ยังไม่มี)

- **K1.1** ออกแบบ approval-request message format สำหรับ Telegram (inline keyboard Approve/Reject ผูกกับ `approval_id`)
- **K1.2** ต่อ Telegram callback query เข้ากับ `PendingApprovals`/`ApprovalHandler` channel เดิม ([§5.2](ARCHITECTURE.md#52-hook-chain-gate-architecture)) — ต้องรองรับ approve/reject จากทั้ง GUI และ Telegram แข่งกันได้ (first-response-wins)
- **K1.3** เทส end-to-end: mock Telegram callback → approval resolve ถูกต้อง, กัน double-resolve, กัน race กับ GUI approve พร้อมกัน

### Task K2 — OCR ท้องถิ่นผ่าน `ort`/CoreML สำหรับ PDF ภาพสแกน

ส่วนที่เหลือของ feature gap #5 เดิม (KB ingestion อื่นๆ ทำครบแล้ว) — ระบุไว้ตั้งแต่ [§12.1](ARCHITECTURE.md#121-การใช้ทรัพยากร-local-compute-cpugpunpu-บน-mac-mini) ว่าจะ route ผ่าน NPU (ANE) ก่อน แต่ยังไม่ implement

- **K2.1** เลือกโมเดล OCR ที่รันผ่าน ONNX Runtime + CoreML execution provider ได้จริงบน Apple Silicon (ตรวจ license + ขนาดโมเดลก่อนเลือก)
- **K2.2** ต่อเข้า GraphRAG ingestion pipeline ([§9](ARCHITECTURE.md#9-graphrag-ingestion-pipeline)) ที่ขั้นตอน Parse & OCR ก่อน chunk
- **K2.3** เทสกับ PDF ที่เป็นภาพสแกนจริง (ไม่ใช่แค่ PDF ที่มี text layer อยู่แล้ว)

### Task K3 — Compaction Handoff: สกัด `key_decisions`/`open_issues`/`file_pointers` จริง

ตอนนี้ 3 field นี้ใน `session_checkpoint` ([§7](ARCHITECTURE.md#7-long-horizon-autonomous-execution--run-until-done-mode) จุด 3) ยังเป็น `[]` เสมอ — มีแค่ `goal`/`completed_steps`/`remaining_steps` ที่สกัดจริง (ดู [LOG.md §16](LOG.md#16-decisions-log))

- **K3.1** ออกแบบวิธีสกัด: heuristic จาก transcript (เช่น diff ของไฟล์ที่แตะ, tool call ที่ fail) หรือเรียก LLM summarize เพิ่มตอน compact
- **K3.2** ทดสอบกับ long-horizon session จริงที่ยาวพอจะ trigger compaction (~70-80% context) — ยืนยันว่า handoff ที่ได้ยังพอให้ context ใหม่ทำงานต่อได้ถูกต้อง ไม่ใช่แค่ field ไม่ว่างเฉยๆ

---

## Open Decisions (ยังไม่ scope เป็น Task)

รายการที่ยัง**ไม่ตัดสินใจ**ว่าจะทำหรือไม่ทำ — ต่างจาก Phase K ที่ตกลงแล้วว่าทำแน่ รายละเอียด/เหตุผลเต็มที่ [LOG.md §16 Decisions Log](LOG.md#16-decisions-log)

- **Custom user-defined hooks** (script เป็น gate เพิ่มจาก Critic/Risk/HITL) — deferred ตั้งแต่ 2026-08-08 เพราะ arbitrary script-as-gate เป็น attack surface ใหม่ที่ยังไม่คุ้มเปิดตอนนี้ — revisit เมื่อมี concrete use case ที่ hook แบบ Rust-hardcoded ไม่พอจริงๆ

---

## Known Debt / Deferred Cleanup

พบระหว่าง full review 2026-08-09 (code + doc) — **ตั้งใจเลื่อนไปทำหลังรอบเอกสารนี้** (เอกสารก่อน โค้ดทีหลัง — ตัดสินใจไว้ตอน review) ไม่ใช่ Task ของ Phase K เพราะยังไม่ได้ scope วันที่จะเริ่ม เก็บไว้ที่นี่กันตกหล่น:

- **Code duplication**: `DbExplorer.tsx` กับ SQL cell ใน `Notebook.tsx` — `MUTATING_KEYWORDS`/`looksMutating()`/`cellToDisplay()` ก็อปกันคำต่อคำ → แยกเป็น shared util (เช่น `frontend/src/sqlGuard.ts`)
- **UI scope overlap**: `LiveMonitor` (standalone page) กับ `ProcessManager` แสดง process list + pause/stop เหมือนกันทุกประการ แต่คนละ data source (event-accumulated vs polling) → ตัดสินใจว่าจะรวมเป็นหน้าเดียว หรือแยก scope ให้ชัดกว่านี้ (เช่น หน้าหนึ่งเป็น "process ของ session ปัจจุบัน" อีกหน้าเป็น "global audit view")
- **Stale doc comments ยืนยันแล้ว 2 จุด**: `crates/agents/research-agent/src/lib.rs` บอกว่า web search ยังไม่สร้าง (จริงๆ สร้างแล้ว — `WebSearchTool` ต่อเข้าแล้ว); `crates/agents/doc-agent/src/lib.rs` บอกว่า template ยังไม่ wire (จริงๆ wire แล้ว — `generate_document.rs` เรียก template จริง) → แก้ comment ให้ตรงโค้ด (ยังไม่ได้แก้)
- ~~**Comment ที่อาจ stale เหมือนกัน ยังไม่ยืนยัน**: `frontend/src/settings/McpServersPanel.tsx:77-79`~~ — **RESOLVED (2026-08-09)**: ไล่โค้ดจริงยืนยันแล้วว่า comment เก่าจริง ไม่ใช่ backend บันทึกผิด — `agent_dispatch.rs:124` เรียก `mcp::connect_mcp_tools` แล้ว `tools.extend(mcp_tools)` ที่บรรทัด 152 รวมเข้า tool list ของ `general`/`code`/custom agent ทุกตัวจริง (คนละ path จาก `data`/`research`/`doc` ที่ return ก่อนถึงจุดนี้ ใช้ tool set แคบตายตัว ไม่ได้ MCP tools) แก้ข้อความในพาเนล UI ให้ตรงกับพฤติกรรมจริงแล้ว (ทดสอบผ่าน dev server จริง — Settings → MCP Servers แสดงข้อความใหม่ถูกต้อง)
- **`db-connectors` ยังไม่ทดสอบกับ server จริง**: มีแค่ SQLite/MSSQL ที่ integration-test กับของจริงแล้ว — Postgres/MySQL connection-string handling ตามสเปก DuckDB เอกสาร แต่ยังไม่เคยรันจริง (ดู `crates/app-tauri/src/db_connectors.rs:6-16`)
- **`Scope`-shaped enum ประกาศซ้ำ 3 ที่**: `kb_store::Scope`, `config::DbConnectorScope`, `agent_registry::AgentScope` — รูปร่างเดียวกัน (`{Central, Project(ProjectId)}`) แต่แยก type เพราะ `config` ไม่ dependency ไป `kb-store` — priority ต่ำ, revisit เฉพาะถ้ามี copy ที่ 4 โผล่มาอีก
