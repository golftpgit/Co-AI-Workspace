# แผนแก้ F-1 · F-2 — อนุมัติแล้ว

**สถานะ**: ✅ อนุมัติ 2026-08-17 ([C1–C4](DECISIONS.md#c-คำตัดสินของเจ้าของโปรเจกต์--2026-08-17)) · ยังไม่ลงมือ

| | F-2 | F-1 |
|---|---|---|
| **อาการ** | `check.sh` เขียวโดยข้ามด่าน Tier 1 ทั้งด่าน | เพิ่ม GX10 บนหน้าจอแล้ว Chat ไม่มีให้เลือก |
| **ลำดับ** | **ทำก่อน** | หลัง |
| **ไฟล์** | 3 | 6 |
| **เทสใหม่** | 0 (งานของ harness) | 6 + E2E 1 |
| **กฎใหม่** | 1 | 2 |

**ทำไม F-2 ก่อน**: ถ้ารอบตรวจยังข้ามสมองหลักได้เงียบ ๆ เราจะไม่มีทางรู้ว่า F-1 แก้แล้วได้ผลจริง — เครื่องวัดต้องเชื่อได้ก่อนของที่ถูกวัด

---

# F-2 · ทำให้ "เขียว" หมายความว่าตรวจครบ

## 2.1 หา endpoint เอง — `scripts/check.sh` ก่อนขั้น `tests`

**ลำดับ**: `COAI_TEST_ENDPOINT` → GX10 → ไม่มี · **ไม่มี LM Studio แล้ว** ([C7](DECISIONS.md#c7--ถอด-lm-studio))

```bash
probe_endpoint() { curl -s --max-time 4 "$1/models" >/dev/null 2>&1; }
TIER1=""
for candidate in "${COAI_TEST_ENDPOINT:-}" "http://192.168.1.205:8000/v1"; do
  [ -n "$candidate" ] || continue
  if probe_endpoint "$candidate"; then TIER1="$candidate"; break; fi
done
if [ -n "$TIER1" ]; then
  export COAI_TEST_ENDPOINT="$TIER1"
  TIER1_MODEL="$(curl -s --max-time 4 "$TIER1/models" \
    | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)"
  ok "Tier 1: $TIER1 · $TIER1_MODEL"
else
  echo "   ⊘ Tier 1: ไม่พบ endpoint ที่ตอบ"
fi
```

`swift test` สืบทอด `COAI_TEST_ENDPOINT` ⇒ `ExecutorContractTests` ยิงไป GX10 เองโดยไม่ต้องแก้เทส
**รอบปกติยิง Tier 1 ด้วย** ([C1](DECISIONS.md#c-คำตัดสินของเจ้าของโปรเจกต์--2026-08-17)) — รอบยาวจาก 2.9 เป็น ~4 นาที

## 2.2 `--full` แดงเมื่อขาด Tier 1

```bash
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
...
if [ -z "$TIER1" ] && [ "$FULL" = "1" ]; then
  fail "โหมด --full ต้องมี Tier 1 — GX10 ต่อไม่ได้"
fi

if [ "$FULL" = "1" ] && [ -n "$TIER1" ]; then
  step "Tier 1 endpoint (P15.0/P15.2)"
  HOSTPORT="$(echo "$TIER1" | sed 's|^http://||; s|/v1$||')"
  ./scripts/gx10-check.sh "$HOSTPORT" 2>&1 | tail -20 \
    && ok "Tier 1 ทำได้ครบสามอย่างที่แอปพึ่ง" \
    || fail "Tier 1 ตอบ แต่ทำสิ่งที่แอปพึ่งไม่ได้"
fi
```

`gx10-check.sh` มีอยู่แล้วและผ่านครบทุกด่าน — ไม่เคยถูกเรียก (D6 ครั้งที่ 9)

## 2.3 Skip สองชั้น

`Tests/LLMProvidersTests/ExecutorContractTests.swift` — เพิ่มฟังก์ชันคู่กับ `skipped`:

```swift
/// การข้ามที่แตะแกนหลักตามแผน. Tier 1 คือสมองหลักตั้งแต่ P15 ขึ้นหัวคิว จึงต้อง
/// แยกจากการข้ามที่ยอมรับได้ (ไม่มี Python, ไม่มี sqlite_scanner) — ทั้งสองอย่าง
/// พิมพ์เหมือนกันมาตลอด และ "ข้าม" ที่อ่านเหมือน "ผ่าน" คือสาเหตุที่ด่านนี้ไม่เคยถูกรัน
private func skippedCritical(_ message: String) { print("SKIPPED-CRITICAL: \(message)") }
```

ใช้กับ **case เดียว** คือไม่มี Tier 1 endpoint · ใน `check.sh`:

```bash
CRITICAL_SKIPS=$(echo "$TEST_OUT" | grep -c "^SKIPPED-CRITICAL:")
echo "$TEST_OUT" | grep "^SKIPPED-CRITICAL:" | sort -u | sed 's/^/   🔴 ข้ามไม่ได้: /'
[ "$CRITICAL_SKIPS" -gt 0 ] && [ "$FULL" = "1" ] && fail "ข้ามการตรวจที่แตะแกนหลัก $CRITICAL_SKIPS จุด"
```

## 2.4 สรุปความครอบคลุม + pre-flight

ท้ายทุกรอบ:

```
── สรุปความครอบคลุม ──
   Tier 1:    http://192.168.1.205:8000/v1 · unsloth/Qwen3.8-27B-NVFP4 · 32768
   Tier 0.5:  Qwen3.5-9B-MLX-4bit · ต้องการ 7.1 GB · ว่าง 3.1 GB → ⊘ ข้าม
   RAM:       ก่อน 3.1 GB → หลัง 2.8 GB
   ผ่าน 1727 · ตก 0 · ข้ามได้ 2 · ข้ามไม่ได้ 0
```

หัวรอบ (F-3):

```bash
ORPHANS=$(pgrep -f 'vendor/helpers/surreal' | wc -l | tr -d ' ')
[ "$ORPHANS" -gt 0 ] && echo "   ⚠ เก็บ sidecar ค้าง $ORPHANS ตัว" && pkill -if 'helpers/surreal'
```

## 2.5 ไฟล์ที่แตะ

| ไฟล์ | แก้อะไร | ขนาด |
|---|---|---|
| `scripts/check.sh` | `--full` · endpoint discovery · pre-flight · เรียก `gx10-check.sh` · สรุปความครอบคลุม | +60 |
| `Tests/LLMProvidersTests/ExecutorContractTests.swift` | `skippedCritical` · ถอดค่าเริ่มต้น LM Studio | +8 / ~3 |
| `Sources/CoAIWorkspaceApp/EndpointsViewModel.swift` | placeholder เป็น GX10 | ~1 |

## 2.6 Done-when

1. GX10 เปิด → `check.sh` พิมพ์ `Tier 1: … · unsloth/…` และ `ข้ามไม่ได้ 0`
2. GX10 ปิด → `check.sh --full` **แดง** พร้อมเหตุผล
3. GX10 ปิด → `check.sh` (ไม่มี `--full`) **เขียว** พร้อมบรรทัด `🔴 ข้ามไม่ได้:` ที่มองเห็น
4. บล็อกสรุปความครอบคลุมโผล่ทุกรอบ ทั้งที่ผ่านและที่ตก

---

# F-1 · ทำให้ค่าที่ตั้งบนหน้าจอ มีผลจริง

## รากของปัญหา

```
Engine.swift:213      let endpoints = config.effectiveEndpoints      ← อ่านครั้งเดียว
Engine.swift:220-256  for endpoint in … { executors.append(VLLMExecutor(…)) }
Engine.swift:264      let router = ModelRouter(executors: executors, …)
ModelRouter.swift:137 private let executors: [any LLMExecutor]       ← let
AppEnvironment.swift:218  rememberEndpoints(…) { BootstrapStore.save(…) }  ← เขียนไฟล์อย่างเดียว
AppEnvironment.swift:57   buildEngine(…)  ← เรียกจาก boot() ที่เดียว
```

**ข้อดีของโครงที่มีอยู่**: `ModelRouter` เป็น `actor` ถูกส่งแบบอ้างอิงไป **9 จุด** ⇒ แก้ที่ router ที่เดียว ทุกจุดเห็นพร้อมกัน ไม่ต้องรื้อการต่อสาย

## 1.1 โรงงาน executor จุดเดียว — `Sources/CoAIWorkspaceApp/EndpointExecutors.swift` (ใหม่)

**ต้องทำก่อน** ไม่งั้นจะมีจุดสร้างสองจุดที่ค่อย ๆ ต่างกัน ซึ่งคือความผิดพลาดที่ `check.sh` ทั้งไฟล์มีไว้กัน

```swift
enum EndpointExecutors {
    struct Result {
        var executors: [any LLMExecutor]
        var checks: [String: EndpointCheck]
        var defaultWindow: Int?          // เพดานบริบทตามที่เซิร์ฟเวอร์รายงาน (P15.3)
    }
    static func build(from registry: EndpointRegistry,
                      probe: EndpointProbe = EndpointProbe()) async -> Result { … }
}
```

`Engine.build` บรรทัด 213–257 เหลือ:

```swift
let built = await EndpointExecutors.build(from: config.effectiveEndpoints)
executors.append(contentsOf: built.executors)
endpointChecks = built.checks
defaultWindow = built.defaultWindow
```

## 1.2 `ModelRouter` เปลี่ยนสายได้

```swift
- private let executors: [any LLMExecutor]
+ private var executors: [any LLMExecutor]

+ /// เปลี่ยนสายทั้งชุด — ใช้ตอนคนแก้ endpoint บนหน้าจอ
+ ///
+ /// **ล้าง availability cache เสมอ**: cache key ด้วย identifier และ identifier เดิม
+ /// อาจชี้ไปคนละเซิร์ฟเวอร์แล้ว — เก็บผลเดิมไว้แปลว่า endpoint ที่เพิ่งแก้ให้ถูก
+ /// จะยังถูกข้ามไปอีก 30 วินาทีโดยไม่มีเหตุผลที่คนเห็นได้
+ public func replaceExecutors(_ new: [any LLMExecutor]) {
+     executors = new.sorted { $0.tier < $1.tier }
+     availability.removeAll()
+ }
```

`init` เรียก `replaceExecutors` แทนการเรียงเอง — เรียงที่เดียว

## 1.3 หน้าจอบันทึกแล้ว router รู้ทันที — `AppEnvironment.swift`

```swift
  try BootstrapStore(paths: paths).save(updated)
  config = updated
+ // เดิมจบตรงนี้ — ไฟล์ถูกเขียน แต่ router ที่ประกอบตอน boot ไม่รู้เรื่อง
+ Task { [engine] in
+     guard let engine else { return }
+     let built = await EndpointExecutors.build(from: registry)
+     var chain: [any LLMExecutor] = [OnDeviceExecutor(), engine.localTier]
+     chain.append(contentsOf: built.executors)
+     await engine.router.replaceExecutors(chain)
+     if let window = built.defaultWindow {          // C2
+         await engine.runner.setPromptBudget(ContextManager.promptBudget(forWindow: window))
+     }
+     await MainActor.run { self.endpointGeneration += 1 }
+ }
+ /// เพิ่มขึ้นทุกครั้งที่สายโมเดลเปลี่ยน — หน้าจอที่แสดงรายการโมเดลเฝ้าค่านี้
+ public private(set) var endpointGeneration = 0
```

## 1.4 เพดานบริบทเปลี่ยนตามได้ (C2)

`ContextManager.budget`: `let` → `var` · `AgentTurnRunner` เพิ่ม `setPromptBudget(_:)`

**เหตุผลที่เลือกทางนี้**: (ก) ปล่อยไว้ ⇒ Done-when ของ P15.3 อ่านแรงกว่าที่เป็นจริง · (ค) ให้ runner ถามเพดานตอนเริ่มเทิร์น ⇒ ถูกที่สุดเชิงความหมาย แต่รื้อ `ContextManager` มากที่สุด — **ไปพร้อม P16 ซึ่งจะแตะเรื่องนี้อยู่แล้ว**

**เทสที่ต้องมี**: เปลี่ยนงบระหว่างที่มีเทิร์นกำลังวิ่ง แล้วเทิร์นนั้นต้องใช้ค่าเดิมจนจบ ไม่ใช่ค่าใหม่กลางคัน

## 1.5 หน้าแชทเห็นรายการใหม่โดยไม่ออกจากหน้า — `ChatView.swift:406`

```swift
  .task { await model.refreshLocalModels(); await model.refreshOfferedModels() }
+ .onChange(of: environment.endpointGeneration) {
+     Task { await model.refreshOfferedModels() }
+ }
```

`.task` วิ่งตอน view ปรากฏ · สลับพื้นที่ด้วย ⌘1–⌘5 ไม่รับประกันว่า view ถูกสร้างใหม่ ⇒ ไม่มี `onChange` จะเจออาการเดิมในรูปที่จับยากกว่าเดิม

## 1.6 กฎใหม่ 2 ข้อ

```bash
# ค่าที่ Engine.build อ่านตอน boot ต้องมีทางอัปเดตขณะรัน หรืออยู่ในรายการที่ยอมรับว่าต้องรีสตาร์ท
RESTART_OK="surrealPort modelQuotaGigabytes"

# router ต้องเปลี่ยนสายได้ — กลับไปเป็น `let` เมื่อไหร่ อาการเดิมกลับมาทันที
grep -q "private var executors" Sources/LLMProviders/ModelRouter.swift \
  && grep -q "func replaceExecutors" Sources/LLMProviders/ModelRouter.swift \
  || fail "ModelRouter กลับไปถือสายแบบเปลี่ยนไม่ได้ (F-1)"
```

## 1.7 เทส 6 + E2E 1

| # | เทส | พิสูจน์อะไร |
|---|---|---|
| 1 | `replaceExecutors` แล้ว `offered` เปลี่ยนตาม | ต้นเหตุของ F-1 |
| 2 | executor ที่ถูกถอด ไม่โผล่ใน `offered` และไม่ถูกเรียก | ลบ endpoint แล้วต้องหายจริง |
| 3 | `replaceExecutors` ล้าง availability cache | 1.2 |
| 4 | ลำดับ tier ยังถูกหลังเปลี่ยนสาย | กัน §9.2 regress |
| 5 | เปลี่ยนสายกลางสตรีม → สตรีมที่วิ่งอยู่ไม่ตาย | ความปลอดภัยของ actor |
| 6 | `chosenModel` ที่ชี้ไป executor ที่หายไป = ไม่เปลี่ยนอะไร ไม่ใช่ error | กฎข้อ 4 ของ E.37 |
| **E2E** | **S7**: บันทึก endpoint → `offeredModels` มีชื่อใหม่ → ส่งเทิร์น → คำตอบมาจาก endpoint นั้น | [กฎ M7](../RULES.md#1-กฎแม่-8-ข้อ) — ทั้งหกข้อบนผ่านได้โดยที่เส้นทางจริงยังขาด |

## 1.8 ไฟล์ที่แตะ

| ไฟล์ | แก้อะไร | ขนาด |
|---|---|---|
| `Sources/CoAIWorkspaceApp/EndpointExecutors.swift` | **ใหม่** — จุดสร้าง executor จุดเดียว | +60 |
| `Sources/CoAIWorkspaceApp/Engine.swift` | เรียกโรงงานแทนสร้างเอง (213–257) | −37 / +6 |
| `Sources/LLMProviders/ModelRouter.swift` | `let` → `var` + `replaceExecutors` | +12 / ~2 |
| `Sources/CoreEngine/ContextManager.swift` · `AgentTurnRunner.swift` | `budget` เป็น `var` + `setPromptBudget` | +14 |
| `Sources/CoAIWorkspaceApp/AppEnvironment.swift` | `rememberEndpoints` เรียก router · `endpointGeneration` | +16 |
| `Sources/CoAIWorkspaceApp/ChatView.swift` | `.onChange` | +3 |
| `Tests/LLMProvidersTests/ModelRouterTests.swift` + E2E | เทส 7 | +110 |
| `scripts/check.sh` | กฎ 2 ข้อ | +18 |

## 1.9 Done-when

**อัตโนมัติ**: เทส 7 ผ่าน · `check.sh` เขียวรวมกฎใหม่

**L3 ขับหน้าจอด้วย `ScreenDriver`** ([C4](DECISIONS.md#c-คำตัดสินของเจ้าของโปรเจกต์--2026-08-17)) — นี่คือข้อที่ปิดข้อร้องเรียนจริง

| ขั้น | คาดว่าจะเห็น |
|---|---|
| เปิดแอปตอนไม่มี endpoint → หน้าแชท | ตัวเลือกมีแค่ `อัตโนมัติ` · Tier 0 · Tier 0.5 |
| **ระบบ → งบ + endpoint** เพิ่ม GX10 กดบันทึก | "พร้อมใช้" พร้อมชื่อโมเดลจาก `/v1/models` |
| กลับ **⌘1 สนทนา** *(ไม่ปิดแอป)* | **`GX10 · 1a` โผล่ทันที** ← ข้อร้องเรียน |
| เลือก GX10 แล้วถามภาษาไทย | ตอบถูก สระครบ · บรรทัดเหตุผลบอกว่ามาจาก GX10 |
| ลบ GX10 กลับมาหน้าแชท | หายทันที · บทสนทนาที่เคยเลือกไว้ยังใช้ได้ ไม่ error |
| เปลี่ยน `--max-model-len` ที่เซิร์ฟเวอร์ แล้วกดตรวจใหม่ | มิเตอร์บริบทเปลี่ยนตามโดยไม่ต้องรีสตาร์ท (C2) |

บันทึกลง [`DRIVING_LOG.md`](DRIVING_LOG.md) · [S7](TEST_PROTOCOL.md#5-l4-end-to-end--scenario-ที่ต้องผ่าน) เปลี่ยนจาก ❌ เป็น ✅

---

## ลำดับลงมือ

```
1. F-2 ทั้งชุด + ถอด LM Studio (C7)  → check.sh + --full เห็นสรุปความครอบคลุม
2. F-1.1 โรงงาน executor             → check.sh เขียว (ยังไม่เปลี่ยนพฤติกรรม)
3. F-1.2 router + เทส 6              → เทสใหม่ผ่าน
4. F-1.4 context budget (C2)         → เทสเปลี่ยนงบกลางเทิร์นผ่าน
5. F-1.3/1.5 หน้าจอ + E2E S7         → build-app.sh แล้วขับด้วย ScreenDriver
6. F-1.6 กฎ 2 ข้อ                    → พิสูจน์ว่ากฎ fail ได้จริงโดยย้อนโค้ดชั่วคราว
7. บันทึก DRIVING_LOG + VERIFICATION_LOG + ปิดแถว F-1/F-2
```

**ทุกขั้นจบด้วย `check.sh` เขียว** — ไม่ทำขั้นถัดไปถ้าขั้นก่อนยังแดง
