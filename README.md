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
xcodebuild -downloadComponent MetalToolchain   # ครั้งเดียวต่อเครื่อง (Xcode 26 แยกเป็น component)
./scripts/fetch-helpers.sh   # ดึง sidecar binary (ครั้งเดียวต่อเครื่อง — vendor/ ไม่อยู่ใน git)
./scripts/build-metallib.sh  # คอมไพล์ Metal kernel ของ MLX (ครั้งเดียว; rebuild ~4 วิ)
./scripts/check.sh           # build + test + embedding model + structural rules
./scripts/build-app.sh       # ประกอบและเซ็น .app พร้อม App Sandbox + ตรวจว่าพาไปเครื่องอื่นได้
```

### แพ็กเกจ (P9.6)

`build-app.sh` จบด้วย `package-audit.sh` ซึ่งตรวจเฉพาะสิ่งที่**ผ่านบนเครื่องนี้เสมอ ไม่ว่าจะพาไปเครื่องอื่นได้หรือไม่**:
resource bundle ของ SwiftPM ทุกอันที่ binary อ้างถึงต้องอยู่ในแอป (`Bundle.module` มี fallback เป็นพาธ build directory
ของเครื่องที่คอมไพล์ — ลืมก๊อปแล้วจะพังที่เครื่องแรกที่ไม่ใช่เครื่องนี้) · ไม่ลิงก์ dylib นอกระบบ/นอก bundle ·
sidecar, Metal kernel และ `Metadata.appintents` ต้องอยู่ครบ · ลายเซ็นและ App Sandbox ต้องผ่าน

**ยังเผยแพร่ไม่ได้**: ตอนนี้เซ็นแบบ ad-hoc (`codesign --sign -`) ซึ่งใช้ได้บนเครื่องที่ build เท่านั้น —
Gatekeeper บนเครื่องอื่นจะปฏิเสธ การแจกจริงต้องมี **Developer ID** ของเจ้าของแอปแล้วทำสองขั้นนี้เพิ่ม
(ต้องมีบัญชี Apple Developer จึงทำแทนกันไม่ได้):

```bash
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: ชื่อคุณ (TEAMID)" \
  --entitlements Resources/CoAIWorkspace.entitlements "build/Co-AI Workspace.app"
xcrun notarytool submit "build/Co-AI Workspace.app" --wait \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
xcrun stapler staple "build/Co-AI Workspace.app"
```

**ข้อจำกัดของ App Sandbox ที่วัดแล้ว** (ด้วย probe ที่เซ็น sandbox จริง): ในแอป `/opt/homebrew` และ `/usr/local`
**มองไม่เห็นเลย** และ `/usr/bin/python3` เป็น shim ที่เรียก `xcrun` ซึ่งรันใน sandbox ไม่ได้
(`xcrun: error: cannot be used within an App Sandbox`) — ล่ามเดียวที่แอปรันได้จึงเป็นตัวที่มากับ Command Line Tools
ซึ่งไม่มี pandas/numpy ดังนั้น **ปลั๊กอินหรือ notebook ที่ต้องใช้แพ็กเกจ Python ภายนอกต้องพาล่ามของตัวเองมาใน bundle**
และนี่คือเหตุผลที่ venv ของ SearXNG (Homebrew 3.14) ก๊อปเข้า `.app` ตรง ๆ ไม่ได้ — ยังเป็นงานค้างของ P9.6

**เครื่องใหม่**: ต้องรัน `fetch-helpers.sh` ก่อน ไม่งั้นเทสฝั่ง Persistence จะข้าม และแอปจะเริ่มฐานข้อมูลไม่ได้ ·
ต้องมี **Metal Toolchain** + รัน `build-metallib.sh` ไม่งั้นโมเดล embedding โหลดไม่ขึ้น
(`Failed to load the default metallib`) — SwiftPM คอมไพล์ Metal shader ไม่ได้ จึงต้องมีขั้น `xcodebuild` แยกไว้ทำอย่างเดียว
([ARCH E.13](ARCHITECTURE.md#e13-bge-m3-ในโปรเซสเราเอง--รันได้จริง--เจอกับดักสำคัญ-2026-08-11))
ส่วน endpoint ของ Tier 1 ตั้งใน `bootstrap.plist` ที่ `~/Library/Containers/com.coaiworkspace.app/Data/Library/Application Support/CoAIWorkspace/`
(คีย์ `selfHostedEndpoint` + `selfHostedModel`) — เป็นค่าต่อเครื่อง ไม่ได้อยู่ใน repo

## สถานะ

**P1 — Walking Skeleton ✅ เสร็จแล้ว** (P0 ด้วย): เส้นทางบางที่สุดวิ่งครบแล้ว —
Chat UI → Model Router (escalate ข้าม tier เอง) → tool call → hook chain (Critic → Risk → Policy → HITL) →
Approval Broker (ตอบจากช่องทางไหนก็ได้) → `run_shell` ใน seatbelt sandbox → span + ข้อความ ลง SurrealDB

ชุดทดสอบ **139 ตัว** รันกับของจริงทั้งหมด: SurrealDB จริง, โมเดลจริง (on-device + endpoint), process/สัญญาณ/sandbox จริง

ถัดไปคือ **P2 — Knowledge**: chunker + Thai tokenizer, ingestion pipeline, hybrid search, provenance
