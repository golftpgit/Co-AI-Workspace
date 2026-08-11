# Co-AI Workspace — Implementation Plan

> คู่กับ [`ARCHITECTURE.md`](ARCHITECTURE.md) (spec) — เอกสารนี้ตอบว่า **สร้างอะไรก่อนหลัง และรู้ได้ยังไงว่าเสร็จจริง**
>
> **กติกาของเอกสารนี้** (เรียนจากความผิดพลาดของ v1):
> - ทุก Task มี **Done-when** ที่เป็นหลักฐานตรวจได้ ไม่ใช่ "เขียนโค้ดเสร็จ" — ห้าม mark DONE ด้วยความรู้สึก
> - Phase ที่ปิดแล้วสรุปสั้น ไม่ลง sub-task ซ้ำ (กันไฟล์ยาวขึ้นเรื่อยๆ)
> - "มี implementation" ≠ "มี feature" — v1 เคยมี MCP client ครบแต่ไม่เคยถูกต่อเข้า tool list จริง (D6) ทุก Task ที่สร้างความสามารถให้ agent ต้องมี **integration test ที่พิสูจน์ว่ามันถูกเรียกใช้จริงใน path ของผู้ใช้**

## สารบัญ

| ส่วน | เนื้อหา |
|---|---|
| [หลักการเรียงงาน](#หลักการเรียงงาน) | ทำไมเรียงแบบนี้ |
| [สถานะปัจจุบัน](#สถานะปัจจุบัน) | อะไรพิสูจน์แล้ว อะไรยังเสี่ยง |
| [P0](#p0--scaffold) – [P9](#p9--hardening--release) | Phase → Task → SubTask |
| [Risk Register](#risk-register) | ความเสี่ยงที่ยังเปิดอยู่ + แผนรับมือ |
| [Completeness Checklist](#completeness-checklist) | เช็คว่าไม่มี feature จาก v1 หล่น |

---

## หลักการเรียงงาน

1. **Walking skeleton ก่อน breadth** — P1 สร้างเส้นทางบางที่สุดที่วิ่งครบตั้งแต่ UI → Router → Tool → Hook chain → Approval → Span → DB **ให้ใช้งานได้จริงตั้งแต่สัปดาห์แรกๆ** แล้วค่อยขยายทีละ module ไม่ใช่สร้างทุก module ให้เสร็จแล้วค่อยต่อกันตอนท้าย (v1 เจอปัญหานี้: workflow execution ไม่เคยผ่าน gate เลยจนมาเจอตอน Phase F)
2. **อะไรที่ spike แล้วเอาโค้ดมาใช้เลย** — [`spikes/`](spikes/) มีโค้ดที่รันผ่านจริงแล้ว 3 ชิ้น ไม่ต้องเริ่มจากศูนย์
3. **Invariant ก่อน feature** — hook chain, approval broker, span store ต้องมาก่อนสิ่งที่ต้องใช้มัน ไม่ใช่ตามมาแก้ทีหลัง (v1 bug B2: Telegram bridge ข้าม hook chain เพราะ bridge มาก่อน invariant)
4. **ทุก Phase จบด้วยสิ่งที่ใช้งานได้** ไม่ใช่ half-built layer

---

## สถานะปัจจุบัน

| เรื่อง | สถานะ | หลักฐาน |
|---|---|---|
| Guided generation (Tier 0) | ✅ พิสูจน์แล้ว 0.6–0.9 วิ | [ARCH E.6](ARCHITECTURE.md#e6-d-7-spike--guided-generation-ใน-app-target-จริง) |
| SurrealClient (KB) | ✅ พิสูจน์แล้ว ครบ BM25/HNSW/graph/hybrid | [ARCH E.8](ARCHITECTURE.md#e8-surrealclient-spike--เขียน-client-เอง-กับ-surrealdb-v320) · [`spikes/SurrealClient/`](spikes/SurrealClient/) |
| VLLMExecutor (Tier 1) | ✅ พิสูจน์แล้ว ครบ streaming/tool/schema/cancel | [ARCH E.9](ARCHITECTURE.md#e9-vllmexecutor-spike--tier-1-ผ่าน-openai-compatible-endpoint) · [`spikes/LLMExecutor/`](spikes/LLMExecutor/) |
| Guardrail refusal ~12.5% | ⚠️ ทราบแล้ว มีแผนรับมือ (escalate) | [ARCH E.7](ARCHITECTURE.md#e7-guardrail-characterization--โดเมนการแพทย์) |
| Thai tokenization | ⚠️ ใช้ได้ ต้องมี dictionary layer | [ARCH E.3](ARCHITECTURE.md#e3-thai-tokenizer--รันจริงกับประโยคงานวิจัยการแพทย์) |
| Embedding model | ✅ **`bge-m3` @ 1024 มิติ** — ตัวเดียวที่ทำ cross-lingual ไทย↔อังกฤษได้ | [ARCH E.10](ARCHITECTURE.md#e10-d-2--เลือก-embedding-model-วัดจริง-ปิดแล้ว) · [`spikes/EmbeddingEval/`](spikes/EmbeddingEval/) |
| macOS 27 API | ⏳ รอ ก.ย. 2026 — มี abstraction คั่นแล้ว | [ARCH §9.1](ARCHITECTURE.md#91-llm-abstraction-ของเราเอง-รองรับทั้งสองยุค) |

**สภาพแวดล้อมที่ยืนยันแล้วบนเครื่อง**: macOS 26.6.1 · Swift 6.3.3 · Xcode 26.6 · Apple Intelligence `available` · LM Studio :1234 (Llama 3.1 8B + nomic-embed) · SurrealDB v3.2.0 binary

---

## P0 — Scaffold ✅ DONE (2026-08-10)

**เป้าหมาย**: โครงที่ build/test/run ได้ ก่อนเขียน logic ใดๆ

| Task | รายละเอียด | Done-when | สถานะ |
|---|---|---|---|
| **P0.1** SwiftPM package + targets | `AgentKit` / `Config` / `Observability` / `Sidecar` / `CoAIWorkspaceApp` + test target ครบ ([ARCH §3](ARCHITECTURE.md#3-swift-package-layout)) | `swift build` + app เปิดหน้าต่างได้ | ✅ build ผ่าน, แอปเปิดเป็น Foreground app จริง (`lsappinfo` ยืนยัน) |
| **P0.2** Swift Testing + check script | `scripts/check.sh` = build + test + structural rules | รัน 1 คำสั่งแล้วได้ผลสรุป pass/fail | ✅ **30 tests / 7 suites ผ่านหมด** + structural rule 3 ข้อ (กัน `Scope` ซ้ำ, `print()` ใน library, `[String: Any]` บน Sendable) |
| **P0.3** Bootstrap config | `bootstrap.plist` + `AppPaths` สร้าง directory เอง + validate + ซ่อมไฟล์เสีย | ลบ dir แล้วเปิดแอปใหม่ → สร้างเองได้ ไม่ crash | ✅ ทดสอบกับแอปจริง: ลบทั้งโฟลเดอร์ → เปิดใหม่ → สร้างครบ 8 รายการ; เปิดซ้ำ → **ไม่เขียนทับ** |
| **P0.4** Sidecar manager | spawn/monitor/restart/terminate + health probe + **reap orphan จาก pid file** | kill จากภายนอก → restart ภายใน 5 วิ; ปิดแอป → ไม่มี process ค้าง | ✅ test พิสูจน์ครบ: restart **0.36 วิ**, `stopAll` ไม่เหลือ process, restart มีเพดานไม่วนไม่จำกัด, orphan ถูกเก็บกวาด |
| **P0.5** App Sandbox + entitlements | เปิด sandbox ตั้งแต่ต้น + `build-app.sh` ประกอบ+เซ็น bundle | แอปรันใน sandbox ได้ + เข้าถึง data dir/network ได้ | ✅ `lsappinfo` แสดง **sandboxed**, container ถูกสร้าง, `codesign --verify` ผ่าน |

**สิ่งที่ได้จริง**: `swift build && ./scripts/check.sh` ผ่านทั้งหมด · `./scripts/build-app.sh` ได้ `.app` ที่เซ็นแล้วเปิดใช้ได้จริง · แอปแสดงหน้า Boot Status (config, paths, sidecar health) ซึ่งจะถูกแทนที่ด้วย Chat view ใน P1.10

---

## P1 — Walking Skeleton

**เป้าหมาย**: คุยกับ agent ได้จริง 1 เส้นทาง ครบทุก invariant — นี่คือกระดูกสันหลังที่ทุก phase ต่อยอด

**ความคืบหน้า**: **P1 ครบทั้ง 10 task ✅ (2026-08-10)** — **139 tests ผ่านหมด** โดย Persistence ทดสอบกับ SurrealDB จริง · LLM ทดสอบกับโมเดลจริงทั้ง on-device และ endpoint · Execution ทดสอบกับ process/สัญญาณ/seatbelt ของจริง · และมี **end-to-end test หนึ่งตัวที่วิ่งครบเส้นทาง** user → DB → router → tool call → hook chain → approval broker → `run_shell` จริง → span ([`WalkingSkeletonTests`](Tests/ToolBeltTests/WalkingSkeletonTests.swift))

| Task | รายละเอียด | Done-when | สถานะ |
|---|---|---|---|
| **P1.1** `AgentKit` protocols | `AgentTool`, `Channel`, `Specialist`, `Scope`, `Assignment`, `Deliverable`, `RiskLevel`, `OpaqueID` ([ARCH §6](ARCHITECTURE.md#6-m2-agentkit)) — **type ล้วน ไม่มี logic** | module อื่น import ได้โดยไม่เกิด dependency cycle | ✅ `Assignment` บังคับ `acceptanceCriteria` ตั้งแต่ type; `Channel` มี approval เป็น method บังคับ |
| **P1.2** `SurrealClient` + schema | ย้ายโค้ดจาก spike เข้า target จริง + schema bootstrap แบบ **idempotent** | เปิดแอป 3 ครั้งติดกันไม่ error; test ครอบ reconnect + concurrent query | ✅ พร้อมแก้บั๊กจริง 5 ข้อที่เจอตอนเทสกับ engine ([ARCH C.0](ARCHITECTURE.md#c0-surrealdb-v320-quirks--ยืนยันซ้ำค้นพบใหม่จาก-spike-ฝั่ง-swift-2026-08-10)) — **3 ใน 5 เป็นบั๊กของเราเอง** |
| **P1.3** Conversation persistence | ตาราง `conversation`/`message`, เขียน user message **ก่อน** เรียก LLM เสมอ, โหลด history จาก DB ทุกครั้ง | ปิดแอปกลางบทสนทนา → เปิดใหม่เห็นครบ; agent error → user message ยังอยู่ | ✅ เทสยืนยัน reconnect แล้ว history ครบ, ลำดับถูก, scope filter ไม่รั่ว, delete cascade |
| **P1.6** Span store | ทุก step เขียน span เข้า DB — **แหล่งเดียว** ([ARCH §16](ARCHITECTURE.md#16-m12-observability--eval)) | สลับหน้าไปมาแล้ว event ไม่หาย (v1 bug B5); span ย้อนหลังอ่านได้หลัง restart | ✅ `SurrealSpanSink` + `SpanRecorder` ปิด span เสมอแม้ body throw; parent/child reassemble ได้ |
| **P1.4** `LLMExecutor` + 2 impl | `OnDeviceExecutor` (Foundation Models) + `VLLMExecutor` (OpenAI-compatible) หลัง protocol เดียว ([ARCH §9.1](ARCHITECTURE.md#91-llm-abstraction-ของเราเอง-รองรับทั้งสองยุค)) | ทั้งสอง executor ผ่าน contract เดียวกันกับ backend จริง | ✅ **Tier 0 ทำ structured output ได้จริง** ผ่าน `DynamicGenerationSchema` (JSON Schema ของเรา → schema ของ Apple ตอน runtime); tool calling ประกาศว่าไม่รองรับตามตรง เพื่อให้ router ส่งขึ้น tier บนแทนที่จะพังกลางเทิร์น |
| **P1.5** Model Router | เลือก tier จาก capability/impact/availability/latency + **fallback chain** + **refusal = escalate** ([ARCH §9.2](ARCHITECTURE.md#92-model-router-tier-0--05--1)) | test: บังคับให้ Tier 0 refuse → งานสำเร็จที่ tier ถัดไป **โดยไม่มี error โผล่ถึง caller** | ✅ 12 เทสคุมกติกา: refusal/overflow/offline escalate, decoding ไม่ escalate, งาน high-impact ข้าม Tier 0, **paid tier ต้องขอใช้ก่อนเสมอ**, streaming escalate ก่อน token แรก, เส้นทางที่ escalate ถูกบันทึกลง span |
| **P1.7** Hook chain + Risk scorer | Critic → Risk → HITL รอบทุก tool call ([ARCH §5.3](ARCHITECTURE.md#53-hook-chain-gate-sub-module)) + risk classification ต่อ tool | test พิสูจน์ว่า **ไม่มีทางเรียก tool โดยไม่ผ่าน gate** (v1 ใช้ test แบบนี้จับ bug ได้จริง) | ✅ invariant บังคับด้วย**โครงสร้าง** ไม่ใช่วินัย: `ToolGateway` ถือ tool ไว้เป็น private และแจก `ToolAdvert` ที่เรียกไม่ได้ + `check.sh` fail ถ้า `.call(argumentsJSON` โผล่นอก `ToolGateway.swift` · เทสทุกสาขาที่ปฏิเสธยืนยันว่า **body ของ tool ไม่ถูกเรียก** ไม่ใช่แค่ค่าที่คืนมา · tool ลดความเสี่ยงของตัวเองไม่ได้ (declared เป็นพื้น ไม่ใช่เพดาน), tool ที่ไม่รู้จัก = High, policy hard stop ชนะ full-autonomous |
| **P1.8** Approval Broker | broadcast ไปทุก channel, first-response-wins, กัน double-resolve ([ARCH §5.4](ARCHITECTURE.md#54-approval-broker-sub-module)) | test: 2 channel ตอบพร้อมกัน → resolve ครั้งเดียว, อีกฝั่งได้สถานะ "resolved แล้ว" | ✅ resolve ทุกทาง (ตอบ/หมดเวลา/ยกเลิก) ลอดผ่านจุดเดียว จึง "resolve ครั้งเดียว" เป็นสมบัติของ actor ไม่ใช่กติกาที่แต่ละ channel ต้องจำ · **ไม่มี channel = ปฏิเสธ ไม่ใช่ปล่อยผ่าน** และไม่ใช่รอค้าง · channel ที่ต่อเข้ามาทีหลังเห็นคำขอที่ค้างอยู่ |
| **P1.9** `run_shell` + Execution (แกน) | `Process` + sandbox profile + process registry + pause/stop ([ARCH §13](ARCHITECTURE.md#13-m9-execution)) | รันคำสั่งจริงได้, กด stop แล้วตายจริง, ไม่มี zombie | ✅ ใช้ **`posix_spawn` แทน `Process`** เพราะต้องได้ process group ของลูกแบบ atomic — เทสยืนยันว่า `sleep` ที่ shell แตกออกมาตายไปด้วยตอนกด Stop · pause/resume/timeout/reap ครบ (SIGTERM ต้อง SIGCONT ก่อน ไม่งั้น process ที่ pause ไว้ฆ่าไม่ตาย) · **seatbelt ปิดจริงระดับ kernel** (เขียนนอก project root ไม่ได้, network ปิด) และรายงานตรงๆ เมื่อ profile ใช้ไม่ได้แทนที่จะแกล้งว่าใช้ |
| **P1.10** Chat UI (แกน) | หน้าคุย + streaming + conversation list + approval banner inline | คุยกับ agent จริงจนจบเทิร์นที่มี tool call + approval ได้ | ✅ `AgentTurnRunner` วิ่งครบเทิร์น (user→DB→history จาก DB→router→stream→tool→gate→approval→DB) + Chat UI ครบ sidebar/streaming/3 สวิตช์/approval banner ที่แก้ argument ก่อนอนุมัติได้ · **เทิร์นที่มี tool call + approval พิสูจน์ด้วย end-to-end test กับ DB/process/broker ของจริง และขับผ่านหน้าจอจริงแล้ว** (Llama 3.1 8B ผ่าน LM Studio) — ขับจริง 3 รอบ เจอ 8 ข้อที่เทสไม่เห็น แก้ครบพร้อม regression test: การ์ด tool ขึ้นซ้ำ, แถบ approval บวมเต็มจอ, ขออนุมัติคำสั่งที่รันไม่ได้อยู่แล้ว, ถามซ้ำหลังกดไม่อนุมัติ, routing error กลืนสาเหตุจริง, **สถานะ "ไม่ได้รัน" หายตอนโหลด history** (ประวัติโกหกว่าทุกคำสั่งสำเร็จ), โมเดลเล็กมั่วชื่อ tool, **view model ถูกสร้างใหม่ทุก body pass จน approval ถูกส่งไปหา instance ที่ไม่มีใครแสดง → เทิร์นค้างโดยไม่มีแถบขึ้น** |

**🎯 Milestone P1**: พิมพ์ "ดูไฟล์ในโฟลเดอร์นี้แล้วสรุปให้หน่อย" → agent เรียก tool → ขอ approval → รัน → ตอบ → ทุกอย่างถูกบันทึกและดูย้อนหลังได้

---

## P2 — Knowledge

| Task | รายละเอียด | Done-when | สถานะ |
|---|---|---|---|
| **P2.1** เลือก embedding model ✅ | วัด 4 ตัวเลือกบนชุดไทย+อังกฤษเดียวกัน (recall@1/@3, MRR, cross-lingual) | มีตัวเลขเทียบ + บันทึกเหตุผลใน ARCH; **มิติถูกล็อกก่อนเริ่ม index** | ✅ **`bge-m3` @ 1024 มิติ** — 100% ทุกมิติ ([ARCH E.10](ARCHITECTURE.md#e10-d-2--เลือก-embedding-model-วัดจริง-ปิดแล้ว)); พบว่า embedding ของ Apple แยก vector space ตามสคริปต์ จึงทำ cross-lingual ไม่ได้เลย |
| **P2.2** Chunker + Thai tokenizer | `NLTokenizer` + **dictionary merge layer** สำหรับคำทับศัพท์ ([ARCH E.3](ARCHITECTURE.md#e3-thai-tokenizer--รันจริงกับประโยคงานวิจัยการแพทย์)) | `โลจิสติก`/`โควิด` ไม่ถูกแตก; วัด BM25 recall เทียบก่อน/หลัง merge layer | ✅ target `Knowledge` (tokenizer + chunker + BM25) **14 เทส** · `โลจิสติก`/`โควิด` ไม่แตกแล้ว และมีเทสยืนยันว่าถ้าปิด merge layer มันแตกจริง · **วัดแล้วได้ผลค้านข้อสันนิษฐานของ Done-when เอง**: recall@1/MRR เท่ากันเป๊ะทั้งเปิดและปิด (1.00) เพราะ index/query ใช้ tokenizer เดียวกัน — ของจริงที่ layer นี้แก้คือ **precision** (ค้น `สติ` แล้วไม่ได้เปเปอร์ logistic regression ติดมา) บันทึกไว้ที่ [ARCH E.3.1](ARCHITECTURE.md#e31-merge-layer-ให้ผลอะไรจริง--วัดตอน-p22-แก้ข้อสันนิษฐานเดิม) · chunker ไม่ตัดกลางประโยค + overlap แบบ best-effort |
| **P2.3** Ingestion pipeline | PDF/DOCX/PPTX/รูป → OCR (Vision) → chunk → dedup (sha256 + semantic) → entity/relation → embed → index | ingest ไฟล์สแกนจริงแล้วค้นเจอ; ingest ซ้ำ → ไม่เพิ่ม chunk ซ้ำ | ✅ **ทั้งสอง Done-when ผ่านกับไฟล์สแกนจริง** — เทสวาดข้อความไทยลง bitmap แล้วยัดเป็นหน้า PDF (ไม่มี text layer เลย) OCR จึงเป็นทางเดียวที่ข้อความจะเข้า index ได้ · ค้นเจอทั้งฝั่ง BM25 และฝั่ง vector (bge-m3 @ **1024 มิติ** ตามที่ P2.1 ล็อก) · ingest ซ้ำ = เพิ่ม 0 chunk · dedup 2 ชั้น: sha256 หลัง normalize ช่องว่าง + near-duplicate ด้วย cosine ≥ 0.97 (กันเคสสแกนใหม่แล้ว OCR เพี้ยนนิดหน่อย) · reader ครบ PDF (text layer บาง = ส่งเข้า OCR), รูป, docx/pptx (unzip + OOXML), plain text · **ปฏิเสธการ index ถ้า embedder อ่านสคริปต์ไม่ออก** ([E.11](ARCHITECTURE.md#e11-embedding-model-ที่-ตาบอดภาษาไทย--เจอตอน-p24-2026-08-11)) · พบว่า Vision รองรับไทยเฉพาะ `.accurate` ([E.12](ARCHITECTURE.md#e12-vision-ocr-รองรับไทยแค่โหมดเดียว--ตรวจตอน-p23-2026-08-11)) · **ค้าง**: relation extraction (ต้องใช้โมเดลอ่านประโยค) เลื่อนไปพร้อม graph view ใน P2.7 — ตอนนี้สกัดเฉพาะ entity ด้วย `NLTagger` |
| **P2.4** Hybrid search | BM25 + vector + RRF fusion (โค้ดมีแล้วจาก spike) + scope filter | ผลลัพธ์คืน provenance + tier ครบทุกแถว | ✅ `KnowledgeIndex` — RRF (k=60) fuse BM25 + cosine, ทุกแถวคืน provenance + tier + บอกได้ว่าอันดับมาจากฝั่งไหน (`lexicalRank`/`semanticRank`) · chunk ที่ยังไม่มี embedding ยังแข่งฝั่ง lexical ได้ ไม่หายไปเฉยๆ · scope filter เทสครบ central/project ก/project ข/policy ไม่รั่วข้ามกัน · **เจอของจริงระหว่างทำ**: embedding model บนเครื่องนี้คืน vector เดียวกันหมดสำหรับภาษาไทย → เพิ่ม `diagnose(_:)` กันไม่ให้ index ผ่าน embedder ที่ตาบอดสคริปต์ ([ARCH E.11](ARCHITECTURE.md#e11-embedding-model-ที่-ตาบอดภาษาไทย--เจอตอน-p24-2026-08-11)) |
| **P2.5** Provenance + credibility | `tier/origin/accessedAt/supersedes` ต่อ chunk ([ARCH §11.3](ARCHITECTURE.md#113-provenance--credibility-บังคับตั้งแต่-ingestion)) | ไม่มี chunk ไหนเข้า index ได้โดยไม่มี provenance (บังคับด้วย type ไม่ใช่ convention) | ✅ `IndexedChunk` ไม่มี initialiser ที่ไม่รับ `Provenance` และ `Provenance` ของแหล่งภายนอก **บังคับ `tier` แบบไม่ optional** (ตัว optional มีทางเดียวคือ `.authored` ของงานที่ระบบเขียนเอง) — บังคับด้วย type ตาม Done-when |
| **P2.6** Policy scope + Policy Gate | `scope: policy`, chunking atomic ต่อกฎ, `hard_constraint` → hard stop ใน hook chain | test: action ที่ขัด hard constraint ถูกหยุด **พร้อมแสดง chunk ที่ขัด** ไม่ใช่แค่ "เสี่ยง" | ✅ `PolicyDocumentParser` ตัด 1 กฎ/chunk (ข้ามหัวข้อ) และแยก **ห้าม/must not = hard** ออกจาก **ควร = คำแนะนำ** · `KnowledgePolicyGate` แทน `NoPolicyGate` ที่ P1 วางไว้ · เทสยิงผ่าน `ToolGateway` จริงและพิสูจน์ว่า**ทูลไม่ถูกเรียก** (ไม่ใช่แค่ค่าที่คืนมา) แม้เปิด full-autonomous · ข้อความที่คืนคือ**ตัวกฎคำต่อคำ + ชื่อเอกสารต้นทาง** · matching ตั้งใจให้แคบ (ทุก content term ของกฎต้องปรากฏใน action) เพราะ gate ที่ fire มั่วจะบล็อกงานจริงจนคนเลี่ยงมัน · 11 เทส |
| **P2.8** Embedding profile + reindex *(ใหม่ 2026-08-11)* | โมเดล embedding ผูกกับ **index** ไม่ใช่ tier — เก็บ `modelID/revision/dimensions/pooling/normalised/tokenizerVersion/chunkerVersion` เป็น profile เดียว + job re-embed ตอนเปลี่ยนโมเดล | index ปฏิเสธ vector ที่มาจากโมเดลอื่น (ทั้งตอนเขียนและตอนค้น); เปลี่ยนโมเดลแล้ว re-embed จากข้อความที่เก็บไว้ได้โดยไม่ต้อง OCR ใหม่ และวัด recall เทียบก่อนสลับ | ✅ `EmbeddingProfile` + ปฏิเสธ vector ข้าม profile ทั้งตอนเขียนและตอนค้น · `Reindexer` re-embed จากข้อความที่เก็บไว้ (ไม่แตะไฟล์ต้นฉบับ, resume ได้, chunk id/provenance/entity คงเดิม) + **golden-query gate ที่วัดก่อนสลับ** โมเดลที่แย่ลงถูกปฏิเสธและ index เดิมยังทำงานต่อ · **เจอระหว่างทำ**: gate ที่วัดแค่ผล fused ยอมรับโมเดลที่คืน vector เหมือนกันหมดด้วย recall@1 = 1.00 เพราะ BM25 แบกไว้ทั้งหมด → ต้องวัดฝั่ง vector แยกด้วย (`searchSemantically`) + เช็ค `diagnose` ก่อนรับ · รวม 15 เทส |
| **P2.7** KB UI | list, upload, graph view, edit/delete entity+relation, tier badge, export/import | แก้ entity แล้วผลค้นหาเปลี่ยนตามจริง | 🔶 **ตรรกะเสร็จ+พิสูจน์แล้ว · หน้าจอยังไม่ได้ขับจริง** — entity ถูก index ไปพร้อมเนื้อความ ทำให้ Done-when เป็นจริงในระดับ index (เทส: ก่อนแก้ค้นไม่เจอ → แก้ entity → เจอ → ลบ entity → หายอีกครั้ง) · `KnowledgeView` มี list + tier badge + ค้นหาที่บอกว่าอันดับมาจากฝั่งไหน + อัปโหลดผ่าน NSOpenPanel + แก้ entity + ลบเอกสาร + export/import (ไม่ส่ง vector ไปด้วย เพราะเครื่องปลายทางอาจใช้โมเดลคนละตัว) · · **KB ลง SurrealDB แล้ว** — ตาราง `chunk` + unique index บน `content_hash` (กัน chunk ซ้ำที่ชั้นที่ bypass ไม่ได้) · หน้าจอเขียนผ่านลง DB ทันทีทั้งตอน ingest / แก้ entity / ลบ / import และโหลดกลับตอนเปิดหน้าจอ · vector ที่สร้างด้วยโมเดลอื่นถูกตัดทิ้งตอนโหลด (เก็บข้อความไว้ให้ re-embed) ไม่ปนเข้า index · 7 เทสกับ SurrealDB จริง · **ค้าง**: graph view ของ entity/relation, relation extraction (P2.3 ยกยอดมา), และ**การขับผ่านหน้าจอจริง** ซึ่ง P1.10 พิสูจน์แล้วว่าเจอบั๊กที่เทสมองไม่เห็น 8 ข้อ |

---

## P3 — Web & Conflict

| Task | รายละเอียด | Done-when |
|---|---|---|
| **P3.1** SearXNG sidecar | ติดตั้ง native/binary + lifecycle ผ่าน `SidecarManager` ([ARCH §1.4](ARCHITECTURE.md#14-web-search--มีของฟรีถาวรไหม-apple-ให้ด้วยไหม)) | ค้นได้จริงจากในแอปโดย user ไม่ต้องติดตั้งอะไรเอง |
| **P3.2** Source registry + tiering | T1–T5 ครอบทุกสาขา, แก้ผ่าน Settings ไม่ต้องแก้โค้ด | เพิ่มแหล่งใหม่ 1 แถว → agent ใช้ทันทีโดยไม่ recompile |
| **P3.3** Tier 1–3 API clients | PubMed E-utilities, medRxiv, OpenAlex, Crossref, Semantic Scholar | คืนผลพร้อม `{tier, url, accessedAt}` ครบ |
| **P3.4** `fetch_page` | readability extraction (ตัด nav/ads), รองรับ PDF, provenance ระดับย่อหน้า | อ่านหน้าจริงได้ ≥5 เว็บที่โครงสร้างต่างกัน; agent อ้างอิงได้ระดับย่อหน้า |
| **P3.5** `ingest_url` | ดึงหน้าเว็บเข้า KB ผ่าน pipeline เดียวกับ upload | หน้าที่ ingest แล้วค้นเจอใน KB พร้อม tier ที่ถูกต้อง |
| **P3.6** Conflict Ledger | detect → ประเมินน้ำหนัก → auto/HITL → precedent ([ARCH §11.6](ARCHITECTURE.md#116-conflict-ledger--เมื่อความรู้ขัดกัน)) | test: ป้อนเอกสารขัดกัน 2 ฉบับ → เกิด Conflict Card; ตัดสินแล้วครั้งถัดไปไม่ถามซ้ำ; มีแหล่ง tier สูงกว่าเข้ามา → เปิด conflict ใหม่ |
| **P3.7** Conflict UI | Conflict Card (verbatim 2 ฝั่ง + ที่มา + น้ำหนัก + 4 ทางเลือก) + ประวัติที่กลับคำตัดสินได้ | ผู้ใช้ตัดสินได้โดยไม่ต้องเปิดเอกสารต้นฉบับเอง |

---

## P4 — AI Team

| Task | รายละเอียด | Done-when |
|---|---|---|
| **P4.1** Specialist actors | Researcher/Analyst/Engineer/Writer เป็น `actor` แยก, คืนแค่ `Deliverable` ([ARCH §2.3](ARCHITECTURE.md#23-context-isolation--กติกาการคืนงาน)) | compiler บังคับ isolation จริง — test พิสูจน์ว่า context ไม่รั่วข้าม actor |
| **P4.2** Team Orchestrator | plan → assign → review → rework → escalate + cap fan-out + task ledger ใน DB ([ARCH §2.2](ARCHITECTURE.md#22-กติกาของหัวหน้าทีม-supervisor-contract)) | หัวหน้าทีมมอบหมายชื่อ role นอก enum ไม่ได้ (compile-time); assignment ทุกอันมี acceptance criteria |
| **P4.3** QA agent + Definition of Done | ตรวจด้วย**หลักฐาน** ต่อ role ([ARCH §2.5](ARCHITECTURE.md#25-qa-loop--ตรวจตามมาตรฐาน)) | Engineer task ที่ไม่มี exit code 0 ในทรานสคริปต์ → QA ตีกลับ **แม้โมเดลจะบอกว่าเสร็จ** |
| **P4.4** Rework loop + escalation | retry cap → escalate หา user พร้อมเหตุผล | test: งานที่ผ่านไม่ได้ → escalate ที่ครั้งที่ N ไม่วนไม่จำกัด |
| **P4.5** Engineer ห้ามแตกทีม | บังคับว่า role นี้ทำงาน context เดียว ([ARCH §2.4](ARCHITECTURE.md#24-ข้อยกเว้น-งานที่ห้ามแตกทีม)) | test พิสูจน์ว่า orchestrator fan-out งาน code ไม่ได้ |
| **P4.6** Manual mode ทุกชั้น | คุยกับ specialist ตรง, แก้ plan รายขั้น, แก้ query ก่อนรัน ([ARCH §2.6](ARCHITECTURE.md#26-manual-mode--ไม่ใช่ทุกอย่างต้องผ่านทีม)) | ทุก artifact ที่ agent สร้าง มีปุ่มแก้เอง |
| **P4.7** Team View | เห็นทั้งทีม ใครทำอะไร สถานะ QA + สั่ง rework/ยกเลิกราย assignment | ดูงานที่กำลังวิ่งขนานกันได้จากหน้าเดียว |
| **P4.8** Operating modes | Autonomy Slider / Plan-only / Run-until-done — อิสระต่อกัน มองเห็นชัดในหัว conversation | ทั้ง 3 สวิตช์ทำงานถูกต้องและไม่กวนกัน |
| **P4.9** Context Manager | budget-aware compaction 70–80% + structured handoff (**ปิด D-5**: สกัด `key_decisions`/`open_issues`/`file_pointers` จริงด้วย Tier 0 + heuristic) | session ยาวจน compact แล้ว **ทำงานต่อถูกต้อง** และ 3 field นั้นไม่ว่างเปล่า |

---

## P5 — LLM Tiers เต็มรูปแบบ

| Task | รายละเอียด | Done-when |
|---|---|---|
| **P5.1** `MLXRuntime` | โหลด/รันโมเดล MLX ([ARCH §9.4](ARCHITECTURE.md#94-mlx-local-tier-05--model-management)) | รันโมเดล local ผ่าน `LLMExecutor` เดียวกันได้ ผ่าน test suite ชุดเดียวกับ executor อื่น |
| **P5.2** Model manager UI | โหลดจาก HuggingFace (progress/resume) + เลือกจากที่มีอยู่ + ลบ + quota | โหลดโมเดลใหม่จบในแอปโดยไม่ใช้ terminal |
| **P5.3** Admission control | เทียบขนาดโมเดล vs RAM ว่าง, ตารางจับคู่ RAM→ขนาด→งาน | เลือกโมเดลใหญ่เกิน RAM → เตือนและไม่ให้ตั้ง default |
| **P5.4** Tier 0.5 เป็นพื้นรับประกัน | fallback สุดท้ายเมื่อ tier อื่นใช้ไม่ได้ | **ตัดเน็ตทั้งหมด → ระบบยังทำงานได้** (นี่คือ acceptance test หลัก) |
| **P5.5** Endpoint registry + validation | `kind: selfHosted/paid`, probe, **validate model กับ `/v1/models`** ([ARCH E.9](ARCHITECTURE.md#e9-vllmexecutor-spike--tier-1-ผ่าน-openai-compatible-endpoint) เคส 8a) | ตั้งชื่อโมเดลผิด → เตือนตอนบันทึก ไม่ใช่ไปพังตอนใช้ |
| **P5.6** Budget Governor | เพดาน 4 ชั้น, ประเมินก่อนยิง, เกิน → fallback/approval ([ARCH §9.5](ARCHITECTURE.md#95-budget-governor--คุมค่าใช้จ่ายของ-tier-1b)) | test: ตั้งเพดานต่ำ → ระบบไม่ยิง paid endpoint และตกไป tier อื่นเอง |
| **P5.7** Cost/usage UI | แถบงบคงเหลือ + รายงานย้อนหลังต่อ session/role/โมเดล | ดูได้ว่าเงิน/token หมดไปกับอะไร |

---

## P6 — Analysis

| Task | รายละเอียด | Done-when |
|---|---|---|
| **P6.1** DuckDB store | `duckdb-swift` + query API | query จริงได้จากในแอป |
| **P6.2** Extension + federated query | ยืนยัน `INSTALL/LOAD` จาก Swift (postgres/sqlite/mssql scanner) | ต่อ external DB จริงแล้วดึงตารางได้ |
| **P6.3** DB connectors | PG/MySQL/SQLite/MSSQL + MongoDB (native) + scope | เพิ่ม connector ผ่าน UI แล้ว explore schema ได้ |
| **P6.4** Notebook kernel | Python persistent kernel (stdin/stdout protocol) + SQL cell | state คงข้าม cell; kill kernel แล้ว restart ได้ |
| **P6.5** Shared SQL guard | mutating-statement confirm **sub-module เดียว** ใช้ทั้ง Notebook + DB Explorer (v1 ก็อปกัน) | มีที่เดียวจริง — grep แล้วไม่เจอโค้ดซ้ำ |
| **P6.6** Statistical Verification Gate | assumption check ต่อ test → structured warning → วนกลับ Analysis Plan | รัน t-test บนข้อมูลที่ไม่ normal → ระบบเตือนและเสนอ non-parametric |
| **P6.7** Gap Detection + Analysis Plan | parse proposal → 3 ระดับ gap → origin tag → approve เป็นก้อน | Analysis Plan ที่ approve แล้ว **ไม่มี `agent_suggested` ค้าง** |
| **P6.8** Notebook + DB Explorer UI | cell UI, result table, DB Explorer | รัน analysis จริงจบใน UI |

---

## P7 — Channels & DocGen

| Task | รายละเอียด | Done-when |
|---|---|---|
| **P7.1** Telegram channel | long polling + inline keyboard approval | approve งานเสี่ยงจากมือถือได้จริง (สิ่งที่ v1 ค้างเป็น Task K1) |
| **P7.2** Discord + LINE | Gateway WS / webhook+HMAC + ปุ่ม approval | ทั้ง 3 channel ใช้ `Channel` protocol เดียวกันไม่มี special case |
| **P7.3** Multi-account + allow-list | หลาย bot/หลาย chat ต่อ platform | test: ข้อความจาก chat นอก allow-list ถูกทิ้ง |
| **P7.4** ตรวจ invariant ข้าม channel | ทุก channel ผ่าน CoreEngine เดียวกัน | **test พิสูจน์ว่าไม่มี channel ไหนเรียก tool เองได้** (ป้องกัน v1 bug B2 ซ้ำ) |
| **P7.5** Notifier + App Intents | native notification + Siri/Shortcuts | สั่งงานจาก Shortcuts ได้ |
| **P7.6** DocGen engine | template + fill + docx/pptx export | สร้างเอกสารจริงเปิดด้วย Word/Keynote ได้ |
| **P7.7** Citation engine | inline citation + bibliography ตาม style | ทุกประโยคจาก KB มี citation ผูก provenance จริง |
| **P7.8** Limitations อัตโนมัติ | assumption (`agent_suggested`) + ข้อความที่เคยมี conflict ขึ้นบัญชีเอง | draft มีส่วน Limitations ที่ถูกต้องโดยไม่ต้องสั่ง |
| **P7.9** Template editor + auto-parse | upload ตัวอย่าง → สกัดโครงสร้าง | ใช้ template ที่ parse มาสร้างเอกสารได้ |

---

## P8 — Roster & UI ครบ

| Task | รายละเอียด | Done-when |
|---|---|---|
| **P8.1** Manifest loader | agent + skill frontmatter parser ตัวเดียวกัน, validate `tools:` | ชื่อ tool ผิด → reject พร้อม error ชัดตอนโหลด |
| **P8.2** Invariant: risk-sensitive → gated | คำนวณจาก tool list จริง ไม่ใช่ field ใน manifest | test: manifest ที่พยายามข้าม gate ทำไม่ได้ |
| **P8.3** MCP client | official Swift SDK + tools/resources/prompts + stdio cwd | **integration test พิสูจน์ว่า MCP tool ปรากฏใน tool list ของ session จริง** (v1 D6) |
| **P8.4** Plugin = packaged MCP server | install/list/uninstall จากโฟลเดอร์ | ติดตั้ง plugin แล้ว tool ใช้ได้ทันที |
| **P8.5** `write_skill` | agent เขียน skill เองผ่าน gate ปกติ | skill ที่ agent เขียน โหลดกลับมาใช้ได้ |
| **P8.6** UI ที่เหลือ | Workflow Builder, Templates, File Viewer/Editor, Processes, Settings ทุกหมวด, Models, Budget, Sources | ทุกหน้าใน [ARCH §14.2](ARCHITECTURE.md#142-workspaceui--หน้าจอทั้งหมด) ใช้งานได้ |
| **P8.7** Accessibility | `accessibilityLabel` ทุกปุ่ม icon-only, keyboard nav, Dynamic Type | ใช้งานด้วยคีย์บอร์ดล้วนได้ครบทุกหน้า (v1 ต้องไล่แก้ทีหลัง 16 ปุ่ม) |

---

## P9 — Hardening & Release

| Task | รายละเอียด | Done-when |
|---|---|---|
| **P9.1** Golden-task eval harness | ชุด regression จากงานจริงที่สำเร็จ | รันใน CI, จับ plan ที่เบี่ยงจาก pattern เดิมได้ |
| **P9.2** Config migration | `schema_version` + migration ตอน boot | โหลด config เวอร์ชันเก่าแล้วไม่เสียค่าเดิม |
| **P9.3** Secrets audit | ทุก secret อยู่ Keychain, ไม่มี plaintext ที่ไหน | grep แล้วไม่เจอ token ใน DB/ไฟล์ |
| **P9.4** Crash/hang resilience | sidecar ล่ม, endpoint หาย, ไฟล์เสีย, disk เต็ม | ทุกกรณีมี error ที่อ่านรู้เรื่อง ไม่ crash |
| **P9.5** Performance pass | Instruments + MetricKit — UI ไม่ block ระหว่าง agent ทำงาน | หน้า UI ตอบสนองระหว่างงานยาววิ่งอยู่ |
| **P9.6** Packaging | bundle sidecars, notarization, ติดตั้งครั้งแรกบนเครื่องสะอาด | เครื่องใหม่ติดตั้งแล้วใช้ได้เลยไม่ต้อง setup manual |

---

## Risk Register

| # | ความเสี่ยง | ผลกระทบ | แผนรับมือ |
|---|---|---|---|
| R1 | **Guardrail ปฏิเสธงานการแพทย์ 12.5% แบบสุ่ม** | Tier 0 ใช้เดี่ยวไม่ได้ | escalate อัตโนมัติ (P1.5) — **ต้องมี test ที่บังคับ refusal จริง ไม่ใช่ mock** |
| R2 | **macOS 27 API ยังไม่ออก** (ก.ย. 2026) | ถ้าผูกโค้ดตรงจะต้องรื้อ | `LLMExecutor` abstraction (P1.4) — เมื่อ macOS 27 ออก เพิ่ม executor ตัวที่ 4 ไม่แตะ CoreEngine |
| R3 | **`surrealdb.swift` alpha** | ถ้าพึ่ง SDK จะโดน breaking change | เขียน client เอง ✅ ทำแล้ว — Plan B (SQLite+FTS5+sqlite-vec) บันทึกไว้ |
| R4 | **Thai tokenizer แตกคำทับศัพท์** | BM25 recall ตกในงานการแพทย์ | dictionary merge layer (P2.2) + วัดผลก่อน/หลัง |
| R5 | **เลือก embedding ผิด** | ต้อง re-index ทั้ง KB | ปิด D-2 **ก่อน** เริ่ม index (P2.1) — ห้ามข้าม |
| R6 | **Multi-agent กิน token 15×** | ค่าใช้จ่าย/เวลาบานปลาย | Budget Governor (P5.6) + cap fan-out (P4.2) + Tier 0/0.5 รับงานเบา |
| R7 | **SearXNG เป็น Python** | เพิ่มภาระ packaging | ประเมิน prebuilt binary ก่อน (P3.1); fallback = DDG scraper |
| R8 | **ทำ module เสร็จแต่ไม่ได้ต่อเข้า path จริง** (v1 D6) | มีโค้ดแต่ไม่มี feature | ทุก Task ที่ให้ความสามารถ agent ต้องมี integration test ระดับ session |

---

## Completeness Checklist

เช็คว่าไม่มีอะไรจาก v1 หล่น — อ้างอิง [ARCH ภาคผนวก A](ARCHITECTURE.md#ภาคผนวก-a--legacy-feature-inventory-เก็บครบจากระบบเดิม)

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

---

## งานถัดไปทันที

1. **P0.1–P0.2** — ตั้งโครง project ให้ build/test ได้
2. ~~**P2.1 (D-2 embedding)**~~ ✅ ปิดแล้ว — `bge-m3` @ 1024 มิติ
3. ~~**P1**~~ ✅ ครบทั้ง 10 task — ระบบใช้งานได้จริงเป็นครั้งแรก
4. ~~**ขับ Chat UI ด้วยมือหนึ่งรอบ**~~ ✅ ทำแล้ว — เจอ 5 ข้อที่เทสไม่เห็น แก้ครบ
5. **P2.2** Chunker + Thai tokenizer — เริ่ม P2 Knowledge
