# Decisions Log — การตัดสินใจที่ยังมีผลกับ v2

> เอกสารอ้างอิง · คู่กับ [`ARCHITECTURE.md`](../ARCHITECTURE.md)
> อ่านเมื่อ: อยากรู้ว่า **ทำไมถึงเลือกทางนี้** หรือกำลังจะเสนอทางใหม่ — ตารางนี้บอกว่าเรื่องนั้นเคยถูกตัดสินไปแล้วหรือยัง
>
> การตัดสินใจใหม่ให้เพิ่มแถวพร้อมวันที่ · การกลับคำตัดสินให้แก้ช่อง "สถานะ" ไม่ใช่ลบแถว

---

## B. Decisions Log


| หัวข้อ | การตัดสินใจ | สถานะใน v2 |
|---|---|---|
| GaLore training framework | ไม่ทำในโปรเจกต์นี้ — อยู่นอกขอบเขต agent app | คงเดิม |
| Network topology | Telegram long polling (outbound-only) ไม่ต้อง VPN/inbound port | คงเดิม |
| Reference manager | ไม่พึ่ง Zotero — ทำ provenance-based citation เอง | คงเดิม |
| Compute dispatch ไป GX10 | ไม่ทำใน v1 — scale up บน Mac ให้เต็มก่อน | คงเดิม |
| Multi-user / auth | single-user ไม่มี auth layer | คงเดิม |
| Analysis store | DuckDB | **ทบทวนใหม่แล้ว → คงเดิม** ([§12.1](../ARCHITECTURE.md#121-analysis-store--ทำไมยังเป็น-duckdb)) |
| SurrealDB deployment | embedded (Rust) | **เปลี่ยน → sidecar process** (Swift SDK เป็น network client) |
| Multi-provider inference | named OpenAI-compatible endpoints ไม่ทำ native SDK ต่อเจ้า | คงเดิม + เพิ่ม Foundation Models เป็น provider ที่ 2 |
| Long-horizon mode | explicit toggle ไม่ auto-detect | คงเดิม |
| Custom agent tool allowlist | full allowlist อิสระ + invariant บังคับ hook chain ตาม tool จริง | คงเดิม |
| Custom user-defined hooks (script เป็น gate) | **defer** — arbitrary script-as-gate เป็น attack surface ที่ยังไม่คุ้ม | คงเดิม — revisit เมื่อมี use case จริง |
| Skill self-authoring | unlock แล้ว (agent เขียน skill ได้ผ่าน gate ปกติ) แต่ยังไม่มี self-improvement loop | คงเดิม |
| DB connector เพิ่มเติม (Redis/BigQuery/Snowflake/Redshift/Oracle) | ไม่ทำทั้ง 5 ตัว — 3 ตัวต้อง connector shape ใหม่, Oracle ไม่มี extension, Redshift verify ไม่ได้ | คงเดิม |
| **ใหม่ v2**: ภาษา/แพลตฟอร์ม | Swift native ทั้ง stack, ไม่ใช้ Rust core ผ่าน FFI | ตัดสินใจ 2026-08-10 |
| **ใหม่ v2**: AI Team model | supervisor + specialists + QA loop แทน agent เดี่ยวหลายตัว | ตัดสินใจ 2026-08-10 |
| **ใหม่ v2**: web search T5 (เว็บทั่วไป) | ~~SearXNG self-hosted sidecar (ยอมรับ Python dependency)~~ → 🔄 **`WKWebView` แบบไม่มีหน้าต่างในแอปเอง** ([ARCH §1.2.1](../ARCHITECTURE.md#121-สะพานค้นเว็บด้วย-wkwebview-แบบไม่มีหน้าต่าง-p131)) · Apple ไม่มี web search API ให้นักพัฒนา (ข้อนี้ยังจริง) | **กลับคำตัดสิน 2026-08-14 (P13.1)** — venv ของ SearXNG ย้ายที่ไม่ได้ จึงก๊อปเข้า `.app` ไม่ได้: ใช้ได้บนเครื่องนักพัฒนาแล้วตายตรงที่ผู้ใช้ต้องใช้จริง · `WKWebView` เป็นเฟรมเวิร์กของระบบและรัน JavaScript ได้ · `SearXNGSource` ยังเป็น provider ที่ใช้ได้ถ้ามีคนรันเอง แต่ไม่ใช่ทางหลัก |
| **ใหม่ v2**: LLM layer กับ macOS 27 | **abstraction ของเราเอง** (`LLMExecutor`) implement 2 ตัวบน API ที่มีวันนี้ แล้วสลับไปใช้ `LanguageModelExecutor` ของ Apple เมื่อ macOS 27 ออก — ไม่ target beta, ไม่รอ, ไม่ผูกโค้ดตรง | ตัดสินใจ 2026-08-10 หลัง verify |
| **ใหม่ v2**: SurrealDB Swift access | **คง SurrealDB + เขียน `SurrealClient` เอง** (JSON-RPC over WebSocket) ไม่พึ่ง `surrealdb.swift` ที่เป็น alpha — Plan B คือ SQLite+FTS5+sqlite-vec | ตัดสินใจ 2026-08-10 หลัง verify |
| **ใหม่ v2**: Tier 0 usage pattern | on-device model **ใช้ผ่าน guided generation (`@Generable`) เท่านั้น** ห้ามพึ่ง instruction-following แบบ prose — พิสูจน์จากการรันจริงว่าโมเดล 3B ไม่ทำตามคำสั่งง่ายๆ | ตัดสินใจ 2026-08-10 หลัง verify |
| **ใหม่ v2**: ขอบเขตงานของ Tier 0 | **จำกัดไว้ที่งานที่ผิดแล้วไม่เสียหายและมี fallback เสมอ** — ย้าย routing ของ Team Lead และ gap severity ไป Tier 1 หลังพบว่า Tier 0 route ไม่นิ่ง (prompt เดิมให้คำตอบต่างกัน) | ตัดสินใจ 2026-08-10 หลัง spike D-7 |
| **ใหม่ v2**: Tier 0.5 (MLX) เป็นพื้นรับประกัน | ไม่ใช่ของเสริม — **ต้องมีโมเดลติดตั้งอย่างน้อย 1 ตัวเสมอ** เพื่อให้ระบบทำงานต่อได้เมื่อ Tier 1 ใช้ไม่ได้ (offline/งบหมด/endpoint ล่ม) พร้อม model management เต็มรูปแบบ (HuggingFace + local) และ admission control ตาม RAM | ตัดสินใจ 2026-08-10 |
| **ใหม่ v2**: แยก Tier 1a/1b + Budget Governor | self-hosted = unlimited ไม่มีเพดาน · paid API = ต้องผ่านเพดานหลายชั้น ประเมินก่อนยิง เกินแล้วตกไป tier อื่นหรือขอ approval | ตัดสินใจ 2026-08-10 |
| **ใหม่ v2**: source tiering ทุกแขนงความรู้ | ขยายจาก 4 tier เฉพาะการแพทย์ เป็น **T1–T5 ครอบทุกสาขา** ผ่าน source registry ที่แก้ได้โดยไม่แตะโค้ด + **`fetch_page` อ่านเนื้อหาจริงก่อนอ้างอิง** ไม่ตัดสินจาก snippet | ตัดสินใจ 2026-08-10 |
| **ใหม่ v2**: Conflict Ledger | ความรู้ที่ขัดกัน **ห้าม agent เลือกข้างเงียบๆ** — ประเมินน้ำหนักจาก tier/ความใหม่/ความเจาะจง/จำนวนแหล่ง แล้ว**ยกให้ผู้ใช้ตัดสินพร้อมข้อมูลประกอบ** เก็บคำตัดสินเป็น precedent ที่กลับได้ | ตัดสินใจ 2026-08-10 |
| **ใหม่ v2**: embedding model | **`bge-m3` @ 1024 มิติ** โฮสต์ผ่าน `MLXRuntime` ของเราเอง — วัดแล้วว่าเป็นตัวเดียวที่ทำ cross-lingual ไทย↔อังกฤษได้ ซึ่งจำเป็นเพราะ KB ผสมสองภาษาเสมอ | ตัดสินใจ 2026-08-10 หลังวัด 4 ตัวเลือก |
| **ใหม่ v2**: จัดการ guardrail refusal | **`GenerationError.Refusal` = สัญญาณ escalate ไป Tier 1 อัตโนมัติ ไม่ใช่ error** — วัดได้ว่า 12.5% ของ prompt งานวิจัยการแพทย์ถูกปฏิเสธแบบสุ่ม และผ่อน guardrail ไม่ได้ผล | ตัดสินใจ 2026-08-10 หลัง spike D-7b |

---

## D. Open Questions — ปิดครบแล้ว

คำถามที่ต้องตอบก่อนล็อกสถาปัตยกรรม · **ปิดครบทั้ง 10 ข้อ** โดยการวัดจริง ไม่ใช่การอ้างเอกสาร (หลักฐานอยู่ใน [ภาคผนวก E](VERIFICATION_LOG.md))


| # | คำถาม | สถานะ | ข้อสรุป |
|---|---|---|---|
| D-1 | `NLTokenizer` ตัดคำไทยดีพอสำหรับ BM25 ไหม | ✅ **ทดสอบจริงแล้ว** ([E.3](VERIFICATION_LOG.md#e3-thai-tokenizer--รันจริงกับประโยคงานวิจัยการแพทย์)) | **ใช้ได้แต่ต้องเสริม** — ตัดคำไทยแท้ดี, แตกคำทับศัพท์ (`โลจิสติก`→`โล\|จิ\|สติ\|ก`) → ใช้ `NLTokenizer` + **dictionary merge layer** สำหรับศัพท์เฉพาะทาง; BM25 ยังทำงานได้เพราะ index/query ใช้ tokenizer เดียวกัน |
| D-2 | Embedding ใช้ตัวไหน | ✅ **ปิดแล้ว — `bge-m3` @ 1024 มิติ** ([E.10](VERIFICATION_LOG.md#e10-d-2--เลือก-embedding-model-วัดจริง-ปิดแล้ว)) | Apple ไม่มี sentence embedding ไทย และ `NLContextualEmbedding` แยก vector space ตามสคริปต์ → cross-lingual เป็นไปไม่ได้; bge-m3 ได้ 100% ทุกมิติบนชุดทดสอบ |
| D-3 | ผูก GX10 เข้า `LanguageModelSession` ได้ไหม | ✅ **ตอบแล้ว — ยังไม่ได้ในวันนี้** ([E.2](VERIFICATION_LOG.md#e2-foundation-models-api-surface-ที่มีจริงบนเครื่อง)) | API เป็นของ macOS 27 (ก.ย. 2026) → **แก้ด้วย `LLMExecutor` abstraction ของเราเอง** ([§9.1](../ARCHITECTURE.md#91-llm-abstraction-ของเราเอง-รองรับทั้งสองยุค)) ไม่ต้องรอ ไม่ต้องลง beta |
| D-4 | DB connector ฝั่ง Swift ใช้อะไร | ✅ **ตรวจแล้ว** | DuckDB scanner เป็นหลัก (federated query ได้ด้วย) — PostgresNIO (ผ่าน SSWG) เป็นทางเลือกถ้าต้องการ native; MongoDB ใช้ `mongo-swift-driver` (wrap libmongoc) · **ผลจริงหลัง P6.2/P6.3**: ใช้ DuckDB scanner อย่างเดียว — SQLite ยืนยันกับไฟล์จริงแล้ว · PG/MySQL ใช้เส้นทางเดียวกันแต่ยังไม่ได้ยืนยันกับ server จริง · **MSSQL กับ MongoDB ยังต่อไม่ได้** (ไม่มี extension ทางการ / ยังไม่ได้เพิ่มไดรเวอร์เป็น dependency) และขึ้นในรายการพร้อมเหตุผล แทนที่จะเป็นตัวเลือกที่ล้มเงียบ |
| D-5 | Compaction handoff สกัดยังไง | ✅ **ปิดแล้ว (P4.9)** | ทำตามที่เสนอ แต่แบ่งหน้าที่ชัดกว่า: **สามฟิลด์ที่ v1 ทำให้ไม่ว่างไม่ได้ (`key_decisions`/`open_issues`/`file_pointers`) สกัดจาก transcript ด้วย heuristic ล้วน ไม่ถามโมเดล** — การอนุมัติที่เกิดขึ้นจริง คำสั่งที่ล้มเหลว และ path ที่ถูกเปิด เป็นข้อเท็จจริงที่อยู่ในข้อความอยู่แล้ว ส่วนโมเดลที่ถูกถามว่า "ตัดสินอะไรไปบ้าง" จะแต่งคำตอบที่ฟังดูดี · Tier 0 ใช้เฉพาะ `completed_steps`/`remaining_steps` ที่ถูกคร่าวๆ ก็พอ และถ้าเรียกไม่ได้ ครึ่งที่เป็นหลักฐานยังมาครบ |
| D-6 | SearXNG bundle ยังไง | ✅ **ปิดแล้ว — คำตอบคือ "แพ็กไม่ได้ จึงไม่แพ็ก"** | รอบแรกตอบว่าได้ (ติดตั้ง native ผ่าน Python venv แล้วให้ `SidecarManager` ดูแล lifecycle เหมือน `surreal`) และ **ติดตั้งกับค้นได้จริงบนเครื่องนักพัฒนา** · แต่ P3.1 พบว่า **venv ย้ายที่ไม่ได้** (สคริปต์ข้างในฝัง absolute path) จึงก๊อปเข้า `.app` ไม่ได้ → P13.1 เปลี่ยนไปใช้ `WKWebView` แทน ซึ่งไม่ต้องแพ็กอะไรเลย · **บทเรียน**: "ติดตั้งได้บนเครื่องนี้" กับ "แพ็กไปกับแอปได้" เป็นคนละคำถาม และเราตอบคำถามแรกแล้วนึกว่าตอบข้อที่สอง (รูปเดียวกับ P8.4/P9.6) |
| D-7 | `@Generable` guided generation ทำงานจริงใน app target ไหม | ✅ **ปิดแล้ว — ทำงานได้ดี** ([E.6](VERIFICATION_LOG.md#e6-d-7-spike--guided-generation-ใน-app-target-จริง)) | ใน NSApplication runloop ทำงานปกติ **0.6–0.9 วิ** (การค้างใน CLI เป็นข้อจำกัดของ command-line context จริง) tool-calling และ streaming ก็ผ่าน |
| D-8 | latency ของ guided generation ยอมรับได้ไหม | ✅ **ปิดแล้ว — ยอมรับได้** | 0.7–1.8 วิ จาก 32 การเรียก, streaming เห็น snapshot แรกที่ **508ms** → ใช้กับงาน UX-critical ได้ |
| D-9 | 🔴 **ใหม่ (พบจาก spike)**: guardrail ปฏิเสธงานวิจัยการแพทย์ | 🔴 **ยืนยันแล้วว่าเป็นปัญหาจริง** ([E.7](VERIFICATION_LOG.md#e7-guardrail-characterization--โดเมนการแพทย์)) | **12.5% ของ prompt งานวิจัยปกติถูกปฏิเสธ** ("May contain sensitive content"), เกิดแบบ**สุ่ม ไม่ deterministic**, และ `permissiveContentTransformations` **ไม่ช่วยเลย** → แก้ด้วยกลไกบังคับ 3 ข้อใน [§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1) |
| D-10 | 🔶 **ใหม่ (พบจาก spike)**: คุณภาพการ route ของ Tier 0 | 🔶 ปานกลาง — ยอมรับไม่ได้สำหรับ Team Lead | "แก้บั๊กใน main.swift" → `engineer` (ถูก) แต่รอบที่สอง → `researcher` (ผิด); prompt งานวิเคราะห์หลายอันได้ `researcher` แทน `analyst` → **ย้ายการ route ของ Team Lead ไป Tier 1** |

