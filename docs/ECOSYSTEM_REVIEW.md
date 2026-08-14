# Ecosystem Review 2026 — ผลการศึกษาก่อนออกแบบ v2

> เอกสารอ้างอิง · คู่กับ [`ARCHITECTURE.md`](../ARCHITECTURE.md) — สำรวจว่า **คนอื่นทำอะไรไว้แล้ว** ก่อนตัดสินใจสถาปัตยกรรม v2 (สำรวจ ส.ค. 2026)
>
> อ่านเมื่อ: อยากรู้ว่าทำไม v2 เลือกทาง Swift native / provider abstraction / harness pattern แบบนี้
> ข้อสรุปที่กลายเป็นสถาปัตยกรรมจริงอยู่ใน `ARCHITECTURE.md` แล้ว — ที่นี่คือ *ที่มา* ไม่ใช่ *ข้อผูกพัน*

---

## 1. คนอื่นทำ Swift AI Agent กันยังไง

| โปรเจกต์ | สิ่งที่ทำ | บทเรียนที่เอามาใช้ |
|---|---|---|
| [Mac Agent (macOS26/Agent)](https://github.com/macos26/agent) | agentic harness สำหรับ macOS desktop — computer use, automation, scripting, รองรับ 18+ provider ทั้ง local/cloud | ยืนยันว่า **provider-agnostic layer เป็นมาตรฐาน** ไม่ใช่ผูกกับ endpoint เดียว → v2 ใช้ `LanguageModelExecutor` เป็น abstraction ([§9](../ARCHITECTURE.md#9-m5-llmproviders)) |
| [Sumika](https://github.com/topics/mlx?l=swift) | local-first macOS agent — chat + workspace context + tool execution บน MLX Swift | "workspace context" เป็น concept เดียวกับ project scope ของเรา — ยืนยัน design เดิมถูก |
| [mlx-serve](https://github.com/ddalcu/mlx-serve) | native LLM inference server บน Apple Silicon, OpenAI+Anthropic API compatible, **ไม่ต้องพึ่ง Python** | ทางเลือกสำรองถ้า GX10 ไม่ว่าง — รันโมเดลกลางบน Mac เองได้โดยไม่ต้องติด Python stack |
| [swift-transformers 1.0](https://huggingface.co/blog/swift-transformers) | เติมช่องว่างที่ Core ML/MLX ไม่มี (tokenizer, model hub, generation loop) สำหรับ local inference | ใช้เป็น fallback path ของ embedding/tokenizer ถ้า Core ML อย่างเดียวไม่พอ |
| [SwiftMCP](https://github.com/sutheesh/SwiftMCP) | เชื่อม Apple Foundation Models เข้ากับ MCP server ใดก็ได้ — แก้ปัญหา `@Generable` เป็น compile-time แต่ MCP schema เป็น runtime ด้วย `DynamicGenerationSchema` | **สำคัญมาก** — คือชิ้นส่วนที่ทำให้ MCP tool ของเราเข้า Foundation Models ได้โดยไม่ต้องเขียน adapter เอง |
| [MCP Swift SDK ทางการ](https://github.com/modelcontextprotocol/swift-sdk) | official Swift SDK ทั้ง client และ server (spec 2025-11-25) | ไม่ต้องเขียน JSON-RPC client เองแบบ v1 (`mcp-client` crate) |

**ข้อสรุป**: Swift ecosystem ปี 2026 มีชิ้นส่วนครบพอสำหรับ agent system แล้ว — จุดที่ v1 ต้องเขียนเองเยอะที่สุด (tool-call protocol, MCP client, embedding runtime) ตอนนี้มีของสำเร็จรูปทั้งหมด

## 2. AI Harness ยอดนิยม — pattern ที่ยืมมา

จาก [Claude Code harness architecture](https://boringbot.substack.com/p/claude-code-skills-subagents-hooks) และ [Anthropic multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system):

| Pattern | รายละเอียด | ใช้ใน v2 ที่ |
|---|---|---|
| **Harness = runtime รอบโมเดล** (ไม่ใช่ prompt) | สิ่งที่ทำให้ LLM เป็น agent คือ layer ที่จัดการ tool/memory/permission ไม่ใช่ prompt ที่เก่งขึ้น | [§5](../ARCHITECTURE.md#5-m1-coreengine) CoreEngine ทั้ง module |
| **โหมดการทำงานชัดเจน** (default / auto-accept / plan / auto) | user รู้ตลอดว่ากำลังอยู่โหมดไหน ไม่ใช่ระบบเดาเอง | [§5.5](../ARCHITECTURE.md#55-โหมดการทำงาน-operating-modes) — v1 มี 3 สวิตช์อยู่แล้ว (Autonomy/Plan-only/Run-until-done) v2 จัดเป็นโหมดที่มองเห็นได้ |
| **Hook = lifecycle event ที่โมเดลข้ามไม่ได้** | deterministic control point ไม่ว่าโมเดลจะ "อยากทำ" อะไร | [§5.3](../ARCHITECTURE.md#53-hook-chain-gate-sub-module) — v1 มี PreToolUse/PostToolUse แล้ว v2 ขยายเป็น lifecycle เต็ม |
| **Skill ก่อน Subagent** | ปัญหาที่พบบ่อย: คนสร้าง subagent สำหรับงานที่ควรเป็นแค่ skill → เพิ่ม overhead + context isolation ที่ไม่จำเป็น | [§7](../ARCHITECTURE.md#7-m3-roster) — Roster module บังคับให้เลือกให้ถูกชั้น |
| **Subagent คืน summary ไม่ใช่ transcript** | subagent ใช้ token หลายหมื่นได้ แต่คืนกลับ 1,000–2,000 token — Anthropic วัดได้ว่า multi-agent ดีกว่า single-agent 90.2% ในงาน research | [§2.3](../ARCHITECTURE.md#23-context-isolation--กติกาการคืนงาน) |
| **Multi-agent กิน token ~15×** | ราคาที่ต้องจ่ายของ team model | บรรเทาด้วย Tier 0 on-device ([§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1)) — งานเล็กของทีมไม่กิน quota โมเดลใหญ่ |
| **Supervisor pattern มี framework support กว้างที่สุด** แต่ failure mode คือ over-delegation | ต้อง **hard-cap รายชื่อ worker** ที่ supervisor เรียกได้ ไม่ปล่อยอิสระ | [§2.2](../ARCHITECTURE.md#22-กติกาของหัวหน้าทีม-supervisor-contract) |
| **Cognition (Devin) เตือน**: งานที่ coupled กันแน่น (แก้โค้ดหลายไฟล์) **ห้ามแตกเป็นหลาย subagent** ต้อง full shared context | ขัดกับ multi-agent hype แต่จริง | [§2.4](../ARCHITECTURE.md#24-ข้อยกเว้น-งานที่ห้ามแตกทีม) — Engineer role ทำงาน context เดียวเสมอ |
| **Compaction ทิ้ง raw tool-output ก่อน** + ต้องมี durable rule file แยก | คำสั่งตอนต้น session หายได้หลัง compact | [§5.6](../ARCHITECTURE.md#56-context-manager-sub-module) |

## 3. เครื่องมือของ Apple ที่ช่วยพัฒนา

| เครื่องมือ/Framework | ใช้ทำอะไรในระบบนี้ | สถานะ |
|---|---|---|
| **[Foundation Models framework](https://developer.apple.com/wwdc26/guides/machine-learning/)** | LLM layer ทั้งหมด — on-device ~3B, `@Generable` structured output, `Tool` protocol, streaming | แกนหลักของ [§9](../ARCHITECTURE.md#9-m5-llmproviders) |
| **[Custom LLM provider API (WWDC26 session 339)](https://developer.apple.com/videos/play/wwdc2026/339/)** | ผูก vLLM/GX10 เข้า `LanguageModelSession` เดียวกับ on-device ผ่าน `LanguageModel` + `LanguageModelExecutor` | 🔶 **ยังไม่มีใน SDK ปัจจุบัน** — เป็นของ macOS 27/Xcode 27 (ออก ก.ย. 2026) ตรวจแล้วว่า `LanguageModelExecutor` ไม่มีใน SDK ที่ติดตั้ง → v2 คั่นด้วย abstraction ของเราเอง ([§9.1](../ARCHITECTURE.md#91-llm-abstraction-ของเราเอง-รองรับทั้งสองยุค)) |
| **Dynamic Profiles / multi-model routing (2026)** | routing ระหว่างหลายโมเดลในเฟรมเวิร์กเดียว | [§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1) Model Router |
| **[MLX + MLX Swift](https://developer.apple.com/videos/play/wwdc2026/232/)** | รัน agentic AI local บน Mac, Hugging Face model ผ่าน Foundation Models ได้ | ทางเลือกสำรอง/เสริมของ Tier 0.5 |
| **Vision** (`VNRecognizeTextRequest`) | OCR สำหรับ PDF ภาพสแกน — เร่งด้วย ANE, ปี 2026 เรียกเป็น tool ให้โมเดลใช้ได้ตรงๆ | ปิด **Task K2** ของ v1 ที่ค้างอยู่ทันที ([§10](../ARCHITECTURE.md#11-m7-knowledge)) |
| **NaturalLanguage** (`NLTokenizer`) | ตัดคำภาษาไทยสำหรับ chunking + BM25 | แทน `nlpo3` — **ต้องเทียบคุณภาพก่อนใช้จริง** ([ภาคผนวก D](DECISIONS.md#d-open-questions--ปิดครบแล้ว)) |
| **Security (Keychain Services)** | เก็บ token/API key/DB password | แทน `keyring` crate ([§15](../ARCHITECTURE.md#15-m11-config--secrets)) |
| **App Sandbox + Seatbelt + Hardened Runtime** | sandbox การรัน user code/DSL จริงระดับ OS | [§12](../ARCHITECTURE.md#13-m9-execution) |
| **App Intents (+ App Intents Testing)** | เปิดให้สั่งงาน workspace ผ่าน Siri/Shortcuts/Spotlight — "สั่งงานทีมโดยไม่ต้องเปิดแอป" | Feature ใหม่ที่ v1 ไม่มี ([§14.3](../ARCHITECTURE.md#143-app-intents-feature-ใหม่)) |
| **Swift Testing** (parallel by default) + **Instruments** + **MetricKit** (Swift-first API ปี 2026) | test harness, profiling, runtime metric | [§16](../ARCHITECTURE.md#16-m12-observability--eval) |
| **[Xcode 27 agent skills](https://www.avanderlee.com/ai-development/swiftui-best-practices-xcode-27-agent-skill/)** | Apple ปล่อย SwiftUI best-practice เป็น agent skill ทางการ | ใช้ตอน dev — ให้ Claude Code อ่าน skill นี้ตอนเขียน SwiftUI |
| **SwiftData + `ResultsObserver`** (iOS/macOS 27) | observe การเปลี่ยนแปลงนอก SwiftUI view | ทางเลือกสำหรับ local UI state cache (ไม่แทน SurrealDB) |

---

## สิ่งที่การสำรวจนี้กลายเป็นในสถาปัตยกรรมจริง

| ผลการศึกษา | ไปอยู่ที่ |
|---|---|
| provider-agnostic layer เป็นมาตรฐาน | [§9.1 LLM abstraction](../ARCHITECTURE.md#91-llm-abstraction-ของเราเอง-รองรับทั้งสองยุค) |
| harness = runtime รอบโมเดล ไม่ใช่ prompt | [§5 M1 CoreEngine](../ARCHITECTURE.md#5-m1-coreengine) |
| supervisor pattern + hard-cap worker | [§2.2 Supervisor Contract](../ARCHITECTURE.md#22-กติกาของหัวหน้าทีม-supervisor-contract) |
| งาน coupled ห้ามแตกทีม (คำเตือนของ Cognition) | [§2.4](../ARCHITECTURE.md#24-ข้อยกเว้น-งานที่ห้ามแตกทีม) |
| multi-agent กิน token ~15× | [§9.5 Budget Governor](../ARCHITECTURE.md#95-budget-governor--คุมค่าใช้จ่ายของ-tier-1b) |
| Apple framework ที่ใช้ได้จริงวันนี้ vs ที่ยังไม่มี | [§0.3 ข้อ 8](../ARCHITECTURE.md#03-design-principles-ที่มีผลต่อทุก-section) · [ภาคผนวก E](VERIFICATION_LOG.md) |
