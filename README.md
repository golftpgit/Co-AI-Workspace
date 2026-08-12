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

## สถานะ — pre-alpha (2026-08-12)

โปรเจกต์นี้เริ่มเขียน **10 ส.ค. 2569** และเปิดให้ดูตอนที่ยังไม่เสร็จ เพราะอยากได้ไอเดียก่อนจะเดินไปไกลกว่านี้
ไม่ใช่ซอฟต์แวร์ที่พร้อมให้คนอื่นใช้ทำงานจริง — แต่ **เดินได้ทั้งเส้นแล้ว** และตรวจได้ว่าเดินได้จริงแค่ไหน

| | |
|---|---|
| งานตามแผน | เสร็จ 53 · ทำบางส่วน 17 · ยังไม่เริ่ม 6 (จาก 76) |
| ชุดทดสอบ | **674 ตัว / 117 suite** รันกับของจริงทั้งหมด — SurrealDB จริง, DuckDB จริง, โมเดลจริง (on-device + MLX บนเครื่อง), Python จริง, process/สัญญาณ/sandbox จริง, MCP server จริง |
| กฎเชิงโครงสร้าง | `scripts/check.sh` fail ถ้าโครงพัง — เช่น มีทางเรียกทูลที่ไม่ผ่าน hook chain, channel เอื้อมถึง tool layer, ทูลที่จัดชั้นความเสี่ยงไว้แต่ไม่มีตัวจริง, ปุ่มไอคอนไม่มีป้ายให้ VoiceOver |

### เดินได้แล้ว (ยืนยันบนแอปจริง ไม่ใช่แค่ในเทส)

แชท → router สลับ tier เอง → tool call → hook chain (Critic → Risk → Policy → HITL) → อนุมัติจาก GUI/Telegram/Discord/LINE ช่องไหนก็ได้ →
`run_shell` ใน sandbox → span ลง SurrealDB · คลังความรู้ (PDF/DOCX/PPTX/OCR, chunker+tokenizer ไทย, hybrid search, provenance ต่อ chunk) ·
การ์ดข้อขัดแย้งที่ระบบยกขึ้นมาเอง · ทีม 4 บทบาท + QA loop + ledger · สมุดงาน SQL/Python (state ข้ามเซลล์ได้) + DB explorer +
แผ่นยืนยันที่โชว์คำสั่ง SQL คำต่อคำ · เอกสาร `.docx`/`.pptx` จริงที่ Word เปิดได้ + citation ผูก provenance + ส่วนข้อจำกัดที่เขียนตัวเอง ·
MCP client ครบ 3 primitive + ปลั๊กอิน (ติดตั้งแล้วทูลขึ้น tool list ทันที) · Siri/Shortcuts · เขียน skill เองผ่าน gate ปกติ

### ยังไม่ได้ (สิ่งที่ควรรู้ก่อนลอง)

- **ยังเซ็นแบบ ad-hoc** — Gatekeeper บนเครื่องอื่นจะปฏิเสธ ต้อง build จาก source เอง (ยังไม่ notarize เพราะยังไม่มี Developer ID)
- **macOS 26 + Apple Silicon เท่านั้น** และต้องมี Xcode 26 + Metal Toolchain เพื่อ build
- **หน้าจอยังไม่ครบ** (P8.6 ยังไม่เริ่ม): ไม่มีหน้า Settings, Workflow Builder, File Viewer, Processes — ตั้งค่าหลายอย่างยังต้องแก้ไฟล์ JSON/plist เอง
- **ข้อจำกัดของ App Sandbox ที่วัดแล้ว**: แอปมองไม่เห็น `/opt/homebrew` กับ `~/.lmstudio` → notebook ได้ Python จาก Command Line Tools ที่ไม่มี pandas/numpy · SearXNG ยังแพ็กเข้าแอปไม่ได้ (T5 web search จึงยังไม่ทำงาน)
- **คุณภาพโมเดลขึ้นกับเครื่อง** — บนเครื่อง 16 GB ชั้นในเครื่องคือโมเดล 4B ซึ่งพอสำหรับงานเบา งานจริงต้องต่อ endpoint · ยังไม่เคยทดสอบกับ API ที่คิดเงิน
- **secret ยังอยู่ใน environment variable ไม่ใช่ Keychain** (P9.3 ยังไม่ทำ) · ยังไม่มี security review
- ยังไม่มี graph view ของ entity/relation · การสกัด entity ภาษาไทยยังได้ clause ปนมา · ไม่มี multi-user/sync/แอปมือถือ

## เทียบกับเครื่องมือที่มีอยู่

**ตำแหน่งของมัน**: เครื่องมือส่วนใหญ่เก่งหนึ่งเลน — โค้ด *หรือ* แชตกับโมเดลในเครื่อง *หรือ* จัดการความรู้ *หรือ* วิเคราะห์ข้อมูล
อันนี้พยายามให้ **สี่เลนอยู่ในแอปเดียวและผ่านประตูอนุมัติเดียวกัน** เพราะงานวิจัยจริงข้ามเลนตลอด: อ่านเปเปอร์ → เขียนโค้ดดึงข้อมูล → รันสถิติ → เขียนต้นฉบับที่อ้างอิงกลับไปยังเปเปอร์นั้น

| เทียบกับ | เราได้เปรียบ | เราเสียเปรียบ |
|---|---|---|
| **Claude Code / Codex CLI / Cursor** | มี UI, มีคลังความรู้ที่ผูก provenance, มี DB/สถิติในตัว, อนุมัติจากมือถือได้, ทำงานได้โดยไม่ต้องต่อเน็ต | เขาเก่งเรื่องโค้ดกว่ามาก (และโมเดลดีกว่า) · ecosystem/ส่วนขยายมหาศาล · ของเรายังไม่มี read/write file เป็นทูลเลย |
| **LM Studio / Ollama / Jan / Open WebUI** | ไม่ใช่แค่แชต — มี tool call ที่ผ่าน risk gate, มีคลังความรู้, มี notebook, สร้างเอกสารได้ | เขาจัดการโมเดลดีกว่ามาก (ดาวน์โหลด/สลับ/quantize) · รองรับหลาย OS · ของเราเห็นโมเดลใน `~/.lmstudio` ไม่ได้เพราะ sandbox |
| **LangGraph / CrewAI / AutoGen** | เป็นแอปที่ใช้ได้เลย ไม่ใช่ไลบรารีให้ประกอบเอง · invariant บังคับด้วยโครงสร้าง (channel เอื้อมถึง tool ไม่ได้เลยเพราะ type ไม่อยู่ใน scope) | ยืดหยุ่นน้อยกว่ามาก · ไม่มี ecosystem/ตัวอย่าง · ผูกกับ macOS |
| **NotebookLM / Obsidian + ปลั๊กอิน** | citation ผูก provenance จริง ไม่ใช่ให้โมเดลพิมพ์เอง — **แหล่งที่ไม่มีผู้เขียน/ปีจะหยุดการสร้างเอกสาร** · ออกเป็น .docx/.pptx จริง | UI ยังห่างชั้น · ไม่มี sync/มือถือ/แชร์ · คลังความรู้ยังโหลดทั้ง scope เข้า memory |
| **Jupyter / DuckDB UI** | คำสั่งที่เปลี่ยนข้อมูลมีแผ่นยืนยันที่โชว์คำสั่งคำต่อคำ · guard ตัวเดียวใช้ทั้ง notebook และ DB explorer · agent เข้าถึงคลังข้อมูลเดียวกันได้ | ไม่มี plot/แผนภูมิเลย · Python ในแอปไม่มี pandas · เขามี ecosystem ทั้งโลก |
| **n8n / Dify** | ไม่ต้องวางกล่องเอง — สั่งหัวหน้าทีมคนเดียวแล้วทีมแบ่งงาน · ทำงานบนเครื่อง ข้อมูลไม่ออกไปไหน | ไม่มี visual builder (P8.6) · ไม่มี integration สำเร็จรูปเป็นร้อย |

**สิ่งที่ยังไม่เห็นใครทำเหมือน** (และเป็นเหตุผลที่เขียนขึ้นมา): pre-registration ของแผนวิเคราะห์ที่ **อนุมัติไม่ได้ถ้ายังมีข้อเสนอของ AI ค้างอยู่** ·
ประตูตรวจสมมติฐานสถิติที่เตือนแล้วเสนอ non-parametric ให้ · ส่วน "ข้อจำกัดของการศึกษานี้" ที่เขียนจากสิ่งที่ระบบบันทึกไว้เองว่า AI เดาอะไรไปบ้าง ·
และภาษาไทยเป็นพลเมืองชั้นหนึ่งตั้งแต่ tokenizer ไปจนถึงฟอนต์ใน `.docx`

## อยากให้ช่วยอะไร

1. **ไอเดีย/ความเห็น** — โดยเฉพาะจากคนทำงานวิจัย/เวชระเบียน/วิเคราะห์ข้อมูล: workflow จริงของคุณสะดุดที่ไหน แล้วอันนี้ควรทำอะไรให้
2. **ลองสร้างแล้วบอกว่าพังตรงไหน** — `./scripts/check.sh` ควรเขียวบนเครื่องคุณ ถ้าไม่เขียวคืออยากรู้มากที่สุด
3. **ช่วยแก้** — งานที่พร้อมให้หยิบมีเขียนไว้ใน [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) ทุกงานมี **Done-when ที่ตรวจได้** และช่อง "ค้าง" ที่บอกตรง ๆ ว่าอะไรยังไม่จริง
4. **บอกว่าอะไรไม่ควรทำ** — สถาปัตยกรรมมีการตัดสินใจหลายข้อที่อาจผิด เขียนเหตุผลไว้ใน [`ARCHITECTURE.md`](ARCHITECTURE.md) แล้ว เถียงได้เลย

ข้อตกลงในโปรเจกต์นี้มีข้อเดียวที่ขอไม่ยืดหยุ่น: **ห้าม mark งานเป็นเสร็จถ้ายังมีรายการค้าง** และ "มีโค้ดแล้ว" ไม่เท่ากับ "มีฟีเจอร์" —
บทเรียนนี้เจอมา 6 ครั้งในโปรเจกต์นี้เอง (ล่าสุด: ทูล 9 ตัวที่จัดชั้นความเสี่ยงไว้เรียบร้อยแต่ไม่มีตัวจริงสักตัว) จนต้องเขียนเป็นกฎใน `check.sh`
