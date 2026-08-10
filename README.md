# Co-AI Workspace

ระบบ AI Agent ส่วนตัวบน Mac (Swift native) สำหรับงาน **เขียนโค้ด · วิเคราะห์ข้อมูล · งานเอกสารเชิงวิจัย** —
ออกแบบเป็น **AI Team** ที่สั่งหัวหน้าทีมคนเดียว แล้วทีมแบ่งงาน ตรวจงานกันเองตามมาตรฐาน วนเป็น loop

โปรเจกต์นี้ **fork แนวคิดจากระบบเดิม (Rust + Tauri + React) แต่รื้อสถาปัตยกรรมใหม่ทั้งหมด** —
ไม่ได้แปลภาษา แต่จัดลำดับชั้นระบบใหม่ตามปัญหาที่พบจริงในรุ่นก่อน

## เอกสาร

| ไฟล์ | เนื้อหา |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | สเปกเต็ม — AI Team model, module catalog (M1–M13), ผลการศึกษา ecosystem, **verification log ที่รันจริงบนเครื่อง**, feature inventory ของระบบเดิมครบทุกข้อ |
| [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) | แผน P0–P9 พร้อม **Done-when ที่ตรวจได้จริง** ต่อ Task, risk register, completeness checklist |
| [`spikes/`](spikes/) | โค้ดที่ผ่านการพิสูจน์แล้วก่อนล็อกสถาปัตยกรรม — `SurrealClient` (JSON-RPC over WebSocket) และ `LLMExecutor` (OpenAI-compatible + streaming + tool calling) |

## Stack

- **UI**: SwiftUI (macOS 26+)
- **LLM**: Foundation Models on-device (Tier 0) · MLX local (Tier 0.5) · self-hosted / paid API (Tier 1) — ผ่าน `LLMExecutor` abstraction ของเราเอง ที่สลับไปใช้ `LanguageModelExecutor` ของ Apple ได้เมื่อ macOS 27 ออก
- **Knowledge**: SurrealDB (graph + vector + BM25) ผ่าน client ที่เขียนเอง — ไม่พึ่ง SDK ที่ยัง alpha
- **Analysis**: DuckDB (`duckdb-swift`) + Python notebook kernel
- **Search**: source tiering T1–T5 ทุกแขนงความรู้ + SearXNG self-hosted

## เริ่มใช้งาน

```bash
./scripts/check.sh        # build + test + structural rules
./scripts/build-app.sh    # ประกอบและเซ็น .app พร้อม App Sandbox
```

## สถานะ

**P0 — Scaffold ✅ เสร็จแล้ว**: SwiftPM package, bootstrap config ที่ซ่อมตัวเองได้, sidecar manager (restart + reap orphan), App Sandbox, ชุดทดสอบ 30 ตัว

ถัดไปคือ **P1 — Walking Skeleton**: เส้นทางบางที่สุดที่วิ่งครบ UI → Model Router → Tool → Hook chain → Approval → Span → DB
