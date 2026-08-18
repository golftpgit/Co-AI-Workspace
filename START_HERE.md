# START HERE — ประตูเข้าเอกสารทั้งหมด

> **ไฟล์นี้มีไว้เพื่อให้คุณ *ไม่ต้อง* อ่านทุกไฟล์** · เอกสารของโปรเจกต์นี้มี ~1.2 MB · ตอบคำถามหนึ่งข้อไม่ควรใช้เกินสองไฟล์
>
> **อ่านไฟล์นี้จบ (2 นาที) แล้วกระโดดไปเฉพาะที่ต้องการ**

---

## 1. โปรเจกต์นี้คืออะไร — 6 บรรทัด

**Co-AI Workspace** — แอป macOS native (SwiftUI + Swift ล้วน) ที่เป็น**ทีม AI ทำงานวิจัยและวิเคราะห์ข้อมูล** ให้คนคนเดียว

| | |
|---|---|
| **แกน** | ทีม agent หลายบทบาท (Researcher · Writer · QA · Analyst) ที่มีหัวหน้าแจกงาน · ทุกการเรียกทูลผ่าน hook chain เดียวที่ข้ามไม่ได้ |
| **สมอง** | 4 ชั้น — Tier 0 Apple Foundation Models · **Tier 0.5 MLX บนเครื่อง (พื้นรับประกันตอนไม่มีเน็ต)** · **Tier 1 vLLM บน GX10 ในบ้าน** · Tier 2 endpoint ที่คิดเงิน |
| **ความรู้** | SurrealDB — BM25 + HNSW + graph · ไทย/อังกฤษข้ามภาษาด้วย `bge-m3` · ทุก chunk มี provenance และ tier ความน่าเชื่อถือ |
| **งานวิจัย** | โครงการเดินตาม PRINCE2/ISO 21502 จริง — WBS · stage gate · ทะเบียน 5 ตัว · สถิติ (α/ω/ICC/κ/EFA/survival) ที่เขียนเองและตรวจกับค่าที่ตีพิมพ์ |
| **ขนาด** | Swift ~72,000 บรรทัด · 35 target · 28 test target · **1,733 เทส** |
| **เครื่อง** | MacBook 16 GB (macOS 26.6.1 · Swift 6.3.3) + GX10 ที่ `192.168.1.205:8000` เสิร์ฟ `Qwen3.8-27B-NVFP4` |

**v2 เขียนใหม่ทั้งหมดจาก v1 (Rust + Tauri + React)** — บทเรียนของ v1 อยู่ที่ [`docs/LEGACY_V1.md`](docs/LEGACY_V1.md)

---

## 2. สถานะวันนี้ — สิ่งที่ต้องรู้ก่อนเชื่ออะไร

**อัปเดต 2026-08-17**

| | |
|---|---|
| `swift build` · `swift test` | ✅ 1,733 เทส · ผ่านหมด |
| `scripts/check.sh --full` | ✅ `ALL CHECKS PASSED` — กฎโครงสร้าง 95 ข้อ · Tier 1 ตรวจจริง |
| Phase ที่ปิดสนิท | P0 · P1 · P12 · P13 · P14 · P17 · P21 |

> ### อ่านตรงนี้ก่อนใช้คำว่า "เขียว"
>
> ✅ **รอบตรวจครอบคลุม Tier 1 แล้ว** (2026-08-17) — `check.sh` probe GX10 เอง และท้ายทุกรอบพิมพ์ว่าครอบคลุมอะไร รวมบรรทัด **"ข้ามได้ / ข้ามไม่ได้"** · `--full` แดงถ้า Tier 1 ต่อไม่ได้ · รอบล่าสุด **ข้ามไม่ได้ 0**
>
> ⚠️ **ยังเหลือ**: ด่านพื้นรับประกัน Tier 0.5 (P5.4) ถูกข้ามเพราะ RAM — โมเดลต้องการ 7.1 GB บนเครื่องที่ว่าง ~2.7 GB ([F-3](docs/AUDIT_2026-08-17.md))
>
> **กติกาอ่านผล**: ถ้าบรรทัดสรุปบอก `ข้ามไม่ได้` ไม่เป็น 0 ให้อ่าน "เขียว" ว่า **"ยังไม่พบว่าพัง ในส่วนที่ตรวจ"**

**งานที่อยู่หัวคิว**: ~~F-2~~ ✅ · ~~F-1~~ ✅ (ขับผ่าน S7 บนหน้าจอจริง) → **P9.1 golden-task** แล้วจึงตัดสิน P15.7 — ดู [`docs/plan/README.md`](docs/plan/README.md#งานถัดไป)

---

## 3. ฉันกำลังจะทำ X — อ่านอะไร

**ตารางนี้คือหัวใจของไฟล์นี้** ซ้ายคือสิ่งที่คุณกำลังจะทำ ขวาคือไฟล์ที่ต้องอ่าน **ตามลำดับ**

| ฉันกำลังจะ… | อ่าน (ตามลำดับ) |
|---|---|
| **เขียนโค้ดอะไรก็ตาม** | [`RULES.md`](RULES.md) §1 กฎแม่ 8 ข้อ → หมวดที่เกี่ยวกับสิ่งที่แตะ |
| **ปิด task ในแผน** | [`docs/plan/pNN.md`](docs/plan/README.md#แฟ้มรายเฟส) ของเฟสนั้น → [`docs/TEST_PROTOCOL.md`](docs/TEST_PROTOCOL.md) §6 นิยาม Done-when |
| **ทำหรือแก้หน้าจอ** | [`docs/UX_UI_DESIGN.md`](docs/UX_UI_DESIGN.md) §1 หลักการ 7 ข้อ + §4 tokens → [`RULES.md`](RULES.md) §6 |
| **แตะเรื่องโมเดล / tier / endpoint** | [`docs/architecture/02-core-modules.md`](docs/architecture/02-core-modules.md) §9 → [`RULES.md`](RULES.md) §7 → [`docs/plan/p15.md`](docs/plan/p15.md) |
| **แตะเรื่องทูล / hook chain / approval** | [`docs/architecture/02-core-modules.md`](docs/architecture/02-core-modules.md) §5, §10 → [`RULES.md`](RULES.md) §2 |
| **แตะคลังความรู้ / การค้น / conflict** | [`docs/architecture/02-core-modules.md`](docs/architecture/02-core-modules.md) §11 → [`docs/plan/p02.md`](docs/plan/p02.md) · [`docs/plan/p18.md`](docs/plan/p18.md) |
| **แตะโปรเจกต์ / WBS / gate / ทะเบียน** | [`docs/architecture/04-project-management.md`](docs/architecture/04-project-management.md) → [`docs/plan/p10.md`](docs/plan/p10.md) |
| **แตะเครื่องมือวิจัย / สถิติ / เก็บข้อมูลจากคน** | [`docs/architecture/05-research.md`](docs/architecture/05-research.md) → [`docs/plan/p11.md`](docs/plan/p11.md) · [`docs/plan/p19.md`](docs/plan/p19.md) |
| **จะรันเทส / จะบอกว่าอะไรผ่าน** | [`docs/TEST_PROTOCOL.md`](docs/TEST_PROTOCOL.md) — **ทั้งไฟล์ สั้น** |
| **จะเสนอทางออกแบบใหม่** | [`docs/DECISIONS.md`](docs/DECISIONS.md) **ก่อนเสมอ** — โดยเฉพาะ §C คำตัดสิน 2026-08-17 |
| **จะบอกว่าอะไรทดสอบไม่ได้** | [`docs/TEST_PROTOCOL.md`](docs/TEST_PROTOCOL.md) §9 — ต้องเขียนไว้ ห้ามเงียบ |
| **เจออาการแปลกกับ SurrealDB / JSON / การ bind ค่า** | [`docs/ENGINEERING_NOTES.md`](docs/ENGINEERING_NOTES.md) |
| **จะอ้างว่า "API นี้น่าจะทำได้"** | [`docs/VERIFICATION_LOG.md`](docs/VERIFICATION_LOG.md) — ที่นั่นบอกว่าวัดแล้วได้อะไรจริง |
| **จะเถียงว่าเอกสารกับโค้ดตรงกัน** | [`docs/AUDIT_2026-08-17.md`](docs/AUDIT_2026-08-17.md) — 10 จุดที่ไม่ตรง พร้อมหลักฐาน |

---

## 4. แผนที่เอกสารทั้งหมด

### ระดับบน — อ่านบ่อย

| ไฟล์ | ตอบคำถาม | ขนาด |
|---|---|---|
| **[`START_HERE.md`](START_HERE.md)** | *ไฟล์นี้* — ควรอ่านอะไร | 17 KB |
| **[`RULES.md`](RULES.md)** | **กฎของโปรเจกต์** พร้อมตัวบังคับและเหตุผล | 41 KB |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | สารบัญของสเปก → ชี้ไป `docs/architecture/` | 13 KB |
| [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) | สารบัญของแผน → ชี้ไป `docs/plan/` | 2 KB |
| [`README.md`](README.md) | ภาพรวมสำหรับคนนอก · วิธี build | 33 KB |

### สเปก — *ระบบคืออะไร ทำไม* ([`docs/architecture/`](docs/architecture/))

| ไฟล์ | § | เนื้อหา |
|---|---|---|
| [`01-foundations.md`](docs/architecture/01-foundations.md) | 0–4 | เป้าหมาย · การจัดชั้นแหล่งข้อมูล · AI Team Model · โครงระบบ · แคตตาล็อกโมดูล |
| [`02-core-modules.md`](docs/architecture/02-core-modules.md) | 5–13 | CoreEngine · AgentKit · Roster · Channels · **LLMProviders** · ToolBelt · **Knowledge** · Analysis · Execution |
| [`03-surfaces-and-ops.md`](docs/architecture/03-surfaces-and-ops.md) | 14–18 | DocGen · **WorkspaceUI** · Config & Secrets · Observability · **ฮาร์ดแวร์/GX10** · NFR |
| [`04-project-management.md`](docs/architecture/04-project-management.md) | 19 | Project Environment & Project Management ทั้งหมด |
| [`05-research.md`](docs/architecture/05-research.md) | 20–21 | Research Program · Instruments · Agent Competence Model |
| [`06-organisation-and-ui.md`](docs/architecture/06-organisation-and-ui.md) | 22–24 | AI Organization · Machine Control · Design System |

### แผน — *สร้างถึงไหนแล้ว* ([`docs/plan/`](docs/plan/README.md))

| ไฟล์ | เนื้อหา |
|---|---|
| [`README.md`](docs/plan/README.md) | **สถานะทุกเฟส · ของค้าง · คิวงาน · หลักการเรียงงาน** |
| [`p00.md`](docs/plan/p00.md) … [`p21.md`](docs/plan/p21.md) | หนึ่งไฟล์ต่อเฟส — **ตารางสถานะ + เหตุผลและตัวเลขที่วัดได้ อยู่ด้วยกัน** |
| [`risks.md`](docs/plan/risks.md) | ความเสี่ยง 18 ข้อพร้อมสถานะจริง |
| [`archive.md`](docs/plan/archive.md) | ของที่ถูกแทนที่แล้ว แต่ไม่ถูกลบ |

### ข้อกำหนดเฉพาะเรื่อง

| ไฟล์ | ตอบคำถาม |
|---|---|
| [`docs/TEST_PROTOCOL.md`](docs/TEST_PROTOCOL.md) | **อะไรเรียกว่าผ่าน** — 4 คำที่ห้ามใช้ปนกัน · L0–L4 (L4 = end-to-end) · scenario S1–S9 |
| [`docs/UX_UI_DESIGN.md`](docs/UX_UI_DESIGN.md) | **หน้าตาและการใช้งาน** — หลักการ 7 ข้อ · IA จริง · tokens · component |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | เรื่องที่ตัดสินไปแล้ว **อย่าเสนอซ้ำ** |
| [`docs/ENGINEERING_NOTES.md`](docs/ENGINEERING_NOTES.md) | ความประหลาดที่ต้องรู้ (SurrealDB · JSON decoding · Swift concurrency) |
| [`docs/ECOSYSTEM_REVIEW.md`](docs/ECOSYSTEM_REVIEW.md) | ทำไมถึงเลือก Swift native |
| [`docs/LEGACY_V1.md`](docs/LEGACY_V1.md) | v1 มีอะไร · feature ไหนหล่นระหว่างย้าย |

### บันทึก — **อย่าอ่านทั้งไฟล์ ให้ค้นเอา**

| ไฟล์ | ค้นเมื่อ | ขนาด |
|---|---|---|
| [`docs/VERIFICATION_LOG.md`](docs/VERIFICATION_LOG.md) | อยากรู้ว่า *วัดแล้วได้เท่าไร* — **ดัชนี E.1–E.46** ชี้ไป `docs/verification/` 3 ส่วน | 18 KB + 197 KB |
| [`docs/DRIVING_LOG.md`](docs/DRIVING_LOG.md) | อยากรู้ว่า *ขับหน้าจอแล้วเจออะไร* — อ้างด้วยรหัส `U…` | 183 KB |

### เอกสารรอบตรวจ 2026-08-17

| ไฟล์ | เนื้อหา |
|---|---|
| [`docs/AUDIT_2026-08-17.md`](docs/AUDIT_2026-08-17.md) | ข้อไม่ตรงกัน F-1…F-10 พร้อมหลักฐานจากการรันจริง |
| [`docs/CHANGE_PLAN_F1_F2.md`](docs/CHANGE_PLAN_F1_F2.md) | แผนแก้ F-1/F-2 ระดับบรรทัด — ✅ **อนุมัติแล้ว 2026-08-17** |

---

## 5. แปดข้อที่ห้ามลืม

ย่อจาก [`RULES.md`](RULES.md) §1 — **ถ้าจำได้แค่ส่วนเดียวของเอกสารทั้งหมด ให้จำส่วนนี้**

| # | | |
|---|---|---|
| **M1** | **"มี implementation" ≠ "มี feature"** | ความสามารถที่ไม่มีเส้นทางจากผู้ใช้ถึงมัน ไม่นับว่ามี — เกิดซ้ำมาแล้ว 9 ครั้ง |
| **M2** | **"เทสเขียว" ≠ "ใช้งานได้"** | ทุกรอบที่ขับหน้าจอ เจอบั๊กที่เทสทั้งชุดมองไม่เห็น |
| **M3** | **"เขียว" ≠ "ตรวจครบ"** | ต้องบอกทุกครั้งว่าข้ามอะไรไป |
| **M4** | **กฎที่ไม่มีเครื่องบังคับ = ความตั้งใจ** | ไม่ใช่กฎ |
| **M5** | **ความเงียบคือความล้มเหลวที่แพงที่สุดที่นี่** | อะไรที่พลาดแล้วไม่มีใครรู้ ต้องมีกฎ |
| **M6** | **ตัวเลขที่อ้าง ต้องวัดเอง** | ห้ามเขียน "น่าจะเร็วขึ้น" |
| **M7** | **ทุกอย่างต้องมีเทส และต้องมีเทสที่วิ่งครบวง** | เทสหน่วยพิสูจน์ว่าชิ้นส่วนถูก **ไม่ได้พิสูจน์ว่าชิ้นส่วนยังต่อกันอยู่** — และการต่อกันคือสิ่งที่พังทุกครั้งที่แก้อย่างอื่น |
| **M8** | **ที่นี่ขับหน้าจอเองได้ และต้องขับ** | "ทดสอบไม่ได้เพราะขับไม่ได้" หมดอายุตั้งแต่ P17 |

---

## 6. คำสั่งที่ใช้จริง

```bash
./scripts/check.sh
```

รอบเร็ว — build + 1,727 เทส + กฎโครงสร้าง 85 ข้อ (~3 นาที)

```bash
./scripts/check.sh --full
```

ก่อนปิดทุก task — เพิ่มด่าน Tier 1 กับ GX10 ครบ 6 ด่าน และแดงถ้า Tier 1 ต่อไม่ได้

```bash
./scripts/gx10-check.sh
```

พิสูจน์ว่า GX10 ทำได้ครบสามอย่างที่แอปพึ่ง (tool call · reasoning split · structured output)

```bash
./scripts/build-app.sh && open "build/Co-AI Workspace.app"
```

build `.app` ที่ sandbox แล้ว — **ต้องใช้อันนี้ก่อนขับหน้าจอทุกครั้ง** ไม่ใช่ `swift run`

```bash
pkill -if 'helpers/surreal'
```

เก็บ sidecar ค้างก่อนรันทุกรอบ (U17) — ตัวละ ~200 MB บนเครื่อง 16 GB

---

## 7. ข้อควรรู้เรื่องเอกสารชุดนี้

| | |
|---|---|
| **ภาษา** | เอกสารเป็นภาษาไทย · คอมเมนต์ในโค้ดเป็นภาษาอังกฤษ · UI เป็นภาษาไทย |
| **ขนาดไฟล์** | ไม่มีไฟล์ไหนเกิน 200 KB โดยตั้งใจ — ไฟล์ที่โตกว่านั้นถูกแยกเป็นโฟลเดอร์ |
| **ไม่มีอะไรถูกลบ** | ทุกครั้งที่จัดใหม่ เนื้อหาถูก*ย้าย* และมีลิงก์ตามไป |
| **เอกสารที่เป็น *ข้อเท็จจริง* vs *บันทึก*** | สเปก · กฎ · แผน · protocol = **ข้อเท็จจริงปัจจุบัน** (ผิดเมื่อไรให้แก้) · `VERIFICATION_LOG` · `DRIVING_LOG` · `archive.md` = **บันทึกตามเวลา** (ไม่แก้ย้อนหลัง เขียนต่อท้ายอย่างเดียว) |
| **ถ้าเอกสารขัดกับโค้ด** | **โค้ดคือความจริง** แล้วแก้เอกสาร — ยกเว้นกรณีที่โค้ดละเมิด `RULES.md` ซึ่งแปลว่าโค้ดผิด |
