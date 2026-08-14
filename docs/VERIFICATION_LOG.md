# Verification Log — ผลที่วัดจริงบนเครื่อง

> เอกสารอ้างอิง · คู่กับ [`ARCHITECTURE.md`](../ARCHITECTURE.md)
> **บันทึกผลตรวจสอบจริง ไม่ใช่การอ้างจากเอกสาร** — ตามหลัก [§0.3 ข้อ 7–8](../ARCHITECTURE.md#03-design-principles-ที่มีผลต่อทุก-section)
>
> อ่านเมื่อ: กำลังจะสรุปว่า "API นี้น่าจะทำได้" — ที่นี่บอกว่าวัดแล้วได้อะไรจริง ๆ บนเครื่องนี้ พร้อมวันที่วัด

**สภาพแวดล้อมที่วัด**: macOS 26.6.1 (build 25G76) · Swift 6.3.3 · Xcode 26.6 · SDK 26.5 · Apple Intelligence `available` · SurrealDB v3.2.0 · LM Studio :1234

| # | หัวข้อ | วันที่วัด |
|---|---|---|
| [E.1](#e1-foundation-models-บนเครื่องจริง-macos-2661) · [E.2](#e2-foundation-models-api-surface-ที่มีจริงบนเครื่อง) | Foundation Models บนเครื่องจริง + API surface | 2026-08-10 |
| [E.3](#e3-thai-tokenizer--รันจริงกับประโยคงานวิจัยการแพทย์) · [E.3.1](#e31-merge-layer-ให้ผลอะไรจริง--วัดตอน-p22-แก้ข้อสันนิษฐานเดิม) | Thai tokenizer + merge layer ให้ผลอะไรจริง | 2026-08-10/11 |
| [E.4](#e4-สถานะ-dependency-หลัก-จาก-github-api-วันที่ตรวจ) · [E.5](#e5-web-search--ข้อสรุปที่-verify-แล้ว) | สถานะ dependency · web search | 2026-08-10 |
| [E.6](#e6-d-7-spike--guided-generation-ใน-app-target-จริง) · [E.7](#e7-guardrail-characterization--โดเมนการแพทย์) | Guided generation · guardrail refusal 12.5% | 2026-08-10 |
| [E.8](#e8-surrealclient-spike--เขียน-client-เอง-กับ-surrealdb-v320) · [E.9](#e9-vllmexecutor-spike--tier-1-ผ่าน-openai-compatible-endpoint) | SurrealClient spike · VLLMExecutor spike | 2026-08-10 |
| [E.10](#e10-d-2--เลือก-embedding-model-วัดจริง-ปิดแล้ว) · [E.11](#e11-embedding-model-ที่-ตาบอดภาษาไทย--เจอตอน-p24-2026-08-11) | เลือก embedding model · embedder ที่ตาบอดภาษาไทย | 2026-08-10/11 |
| [E.12](#e12-vision-ocr-รองรับไทยแค่โหมดเดียว--ตรวจตอน-p23-2026-08-11) · [E.13](#e13-bge-m3-ในโปรเซสเราเอง--รันได้จริง--เจอกับดักสำคัญ-2026-08-11) | Vision OCR ไทย · bge-m3 ในโปรเซสเราเอง | 2026-08-11 |
| [E.14](#e14-mlx-chat-runtime-tier-05--รันจริงตอน-p51-2026-08-12)–[E.18](#e18-ทะเบียน-endpoint-กับเพดานเงิน--สร้างตอน-p55p57-2026-08-12) | MLX chat runtime · model manager · admission control · พื้นรับประกัน · endpoint+งบ | 2026-08-12 |

---


บันทึกผลตรวจสอบจริง ไม่ใช่การอ้างจากเอกสาร — ทำก่อนล็อกสถาปัตยกรรมตามหลัก [§0.3](../ARCHITECTURE.md#03-design-principles-ที่มีผลต่อทุก-section) ข้อ 7–8

## E.1 Foundation Models บนเครื่องจริง (macOS 26.6.1)

| รายการ | ผล |
|---|---|
| เครื่อง/ระบบ | macOS **26.6.1** (build 25G76) · Swift **6.3.3** · Xcode **26.6** · SDK **26.5** |
| `SystemLanguageModel.default.availability` | ✅ `available` (Apple Intelligence พร้อมใช้) |
| prompt ธรรมดา (`respond(to:)`) | ✅ ทำงาน — **1.92 วินาที** |
| คุณภาพการทำตามคำสั่ง | ⚠️ สั่ง *"Reply with exactly one word: OK"* → ตอบ *"Sure, I can do that. What is your question?"* → **โมเดล ~3B ไม่เหมาะกับ instruction-following แบบ prose ต้องบังคับ schema** |
| `@Generable` guided generation | 🔴 **ยืนยันไม่ได้** — เรียกจาก command-line tool ค้าง >60 วิ ไม่คืนผล (macro compile ผ่านเมื่อ build ผ่าน SwiftPM + Xcode toolchain; `swift file.swift` แบบ script ใช้ macro ไม่ได้เลย) → ต้องเทสซ้ำใน app target |

## E.2 Foundation Models API surface ที่มีจริงบนเครื่อง

ไล่ดู `FoundationModels.swiftinterface` ใน SDK ที่ติดตั้ง:

- **มีแล้ว**: `LanguageModelSession`, `SystemLanguageModel`, `Transcript`, `GenerationSchema`, `DynamicGenerationSchema`, `GeneratedContent`, `GenerationOptions`, `Guardrails`, `Tool`, `ToolCall`, `ToolDefinition`, `ToolOutput`, `Generable`, `Guide`, `Adapter`, `ResponseStream`, `LanguageModelFeedback`
- 🔴 **ยังไม่มี**: `LanguageModelExecutor`, `LanguageModelExecutorGenerationRequest` (0 ครั้งในไฟล์) — ยืนยันว่า custom-provider API เป็นของ macOS 27
- **Timeline ที่ตรวจ**: macOS 27 / Xcode 27 dev beta 8 มิ.ย. 2026 · public beta 13 ก.ค. · **ออกจริงกันยายน 2026**

## E.3 Thai tokenizer — รันจริงกับประโยคงานวิจัย/การแพทย์

`NLTokenizer(unit: .word)` + `setLanguage(.thai)`:

| Input | ผลการตัดคำ | ประเมิน |
|---|---|---|
| `ผู้ป่วยเบาหวานชนิดที่ 2 ที่มีภาวะไตเรื้อรัง...` | `ผู้ป่วย \| เบาหวาน \| ชนิด \| ที่ \| 2 \| ที่ \| มี \| ภาวะ \| ไต \| เรื้อรัง \| ...` | ✅ ดี |
| `กรมควบคุมโรค กระทรวงสาธารณสุข รายงาน...` | `กรมควบคุมโรค \| กระทรวงสาธารณสุข \| รายงาน \| สถานการณ์ \| ...` | ✅ ดีมาก (จับชื่อหน่วยงานเป็นก้อน) |
| `...แบบจำลองการถดถอยโลจิสติก` | `แบบจำลอง \| การ \| ถดถอย \| โล \| จิ \| สติ \| ก` | 🔴 **แตกคำทับศัพท์** |
| `โควิด-19 กับวัคซีน mRNA...` | `โค \| วิด \| 19 \| กับ \| วัคซีน \| mRNA \| ...` | 🔴 **แตกคำทับศัพท์** |
| `ระบบตัวแทนปัญญาประดิษฐ์ทำงานร่วมกัน...` | `ระบบ \| ตัวแทน \| ปัญญาประดิษฐ์ \| ทำงาน \| ร่วมกัน \| ...` | ✅ ดี |

เพิ่มเติม: language identification ภาษาไทยแม่นยำ (confidence 1.0) · **POS tagging ไม่รองรับไทย** (มีแค่ scheme `Language`/`Script`/`TokenType`) · เทียบข้อมูลภายนอก: `newmm` ที่ v1 ใช้ได้ **71.18%** บน BEST2010 (SOTA 95.60%) → NLTokenizer ไม่ได้ด้อยกว่าอย่างชัดเจน

### E.3.1 merge layer ให้ผลอะไรจริง — วัดตอน P2.2 (แก้ข้อสันนิษฐานเดิม)

ตอนตั้ง P2.2 เขียน Done-when ไว้ว่า "วัด BM25 recall เทียบก่อน/หลัง merge layer" โดยสันนิษฐานว่า recall จะดีขึ้น **วัดจริงแล้วไม่ใช่** — บน corpus 10 เอกสาร / 5 query (`Tests/KnowledgeTests/RetrievalMeasurementTests.swift`):

| | recall@1 | MRR |
|---|---|---|
| ไม่มี merge layer | **1.00** | **1.00** |
| มี merge layer | **1.00** | **1.00** |

เหตุผลคือสิ่งที่ E.3 เขียนไว้เองอยู่แล้ว: index กับ query ผ่าน tokenizer ตัวเดียวกัน `โลจิสติก` จึงแตกเป็น `โล|จิ|สติ|ก` เหมือนกันทั้งสองฝั่งและยังเจอเอกสารเดิม

**สิ่งที่ merge layer แก้จริงคือ precision** — ค้น `สติ` (คำไทยแท้ แปลว่าความรู้สึกตัว) โดยไม่มี merge layer ได้เอกสารเรื่อง logistic regression ติดมาด้วย เพราะมันมี fragment `สติ` อยู่ข้างใน พอเปิด merge layer เอกสารนั้นหายไปและเหลือเฉพาะเอกสารที่พูดเรื่องสติจริงๆ · ตรวจเพิ่มด้วยว่า merge layer **ไม่เพิ่ม** ผลลัพธ์ที่ไม่มี merge layer หาไม่เจอ (subset check ทุก query)

## E.11 embedding model ที่ "ตาบอดภาษาไทย" — เจอตอน P2.4 (2026-08-11)

`text-embedding-nomic-embed-text-v1.5` ที่ LM Studio เสิร์ฟ **คืน vector ตัวเดียวกันเป๊ะทุกครั้งสำหรับ input ภาษาไทย** ไม่ว่าข้อความจะต่างกันแค่ไหน:

| input | vector 3 ตัวแรก |
|---|---|
| `การให้อินซูลินในผู้ป่วยเบาหวาน` | `-0.00297, 0.00135, -0.15952` |
| `การควบคุมระดับน้ำตาลในเลือด...` | `-0.00297, 0.00135, -0.15952` |
| `การปนเปื้อนโลหะหนักในแหล่งน้ำดิบ` | `-0.00297, 0.00135, -0.15952` |
| `insulin therapy in diabetic patients` | `0.00015, 0.06579, -0.14905` ✅ ต่างกันปกติ |

ไม่ใช่ปัญหา batch — ยิงทีละ request ก็ได้ผลเดียวกัน · ภาษาอังกฤษทำงานปกติ → tokenizer ของโมเดลไม่รู้จักสคริปต์ไทยเลย

**ทำไมอันตราย**: cosine ระหว่าง vector ที่เท่ากันคือ 1.0 ทุกคู่ ระบบจะ "ค้นเจอ" เสมอและจัดอันดับมั่วโดยไม่มี error ให้เห็น — เป็นการพังแบบเงียบที่แย่กว่าพังดังๆ · **ยืนยันการตัดสินใจของ P2.1 ([E.10](#e10-d-2--เลือก-embedding-model-วัดจริง-ปิดแล้ว)) ว่าทำไมต้อง `bge-m3`**

**สิ่งที่ทำ**: `diagnose(_ embedder:)` ใน `Knowledge` ยิงประโยคที่ต่างกันชัดเจน 2 ประโยคต่อสคริปต์ (ไทย + ละติน) ถ้าได้ vector เท่ากันเป๊ะ = `.blind(to:)` ไม่ใช่ threshold แต่เทียบว่า "เท่ากันเป๊ะ" เพราะโมเดลที่แค่มองว่าสองประโยคคล้ายกันคือทำงานถูกแล้ว — P2.3 จะไม่ยอม index ผ่าน embedder ที่อยู่ในสถานะนี้

## E.12 Vision OCR รองรับไทยแค่โหมดเดียว — ตรวจตอน P2.3 (2026-08-11)

`VNRecognizeTextRequest.supportedRecognitionLanguages()` บนเครื่องนี้:

- `.accurate` → **30 ภาษา รวม `th-TH`** ✅
- `.fast` → `en-US, fr-FR, it-IT, de-DE, es-ES, pt-BR` เท่านั้น — **ไม่มีไทย**

แปลว่าสำหรับคลังเอกสารไทย `.accurate` ไม่ใช่ตัวเลือกเรื่องคุณภาพแต่เป็นทางเดียวที่ใช้ได้ · ถ้าเผลอตั้ง `.fast` เพื่อความเร็ว หน้าที่เป็นภาษาไทยจะคืนค่าว่างโดยไม่มี error → `TextRecognizer` ล็อก `.accurate` ไว้ตายตัวและ expose `supportedLanguages` ให้ UI บอกผู้ใช้ได้ว่าเครื่องนี้อ่านภาษาอะไรได้บ้าง

## E.13 bge-m3 ในโปรเซสเราเอง — รันได้จริง + เจอกับดักสำคัญ (2026-08-11)

รันจริงแล้วบนเครื่องนี้ ([spikes/EmbeddingRuntime/](../spikes/EmbeddingRuntime/FINDINGS.md)):

| เช็ค | ผล |
|---|---|
| โหลด bge-m3 ผ่าน `MLXEmbedders` | ✅ 1024 มิติ ตรงกับที่ P2.1 ล็อก |
| อ่านภาษาไทย | ✅ ประโยคใกล้กัน 0.764 vs ไม่เกี่ยวกัน 0.379 (ต่างจาก nomic ใน [E.11](#e11-embedding-model-ที่-ตาบอดภาษาไทย--เจอตอน-p24-2026-08-11) ที่คืน vector เดียวกันหมด) |
| ความเร็ว | ✅ **232 chunk/วินาที** → re-embed 10,000 chunk ใช้เวลาไม่ถึงนาที (โหลดครั้งแรก ~43 วิรวมดาวน์โหลด) |

**🔴 กับดักที่เจอ — "bge-m3" สองบิลด์ให้ vector space ที่ตั้งฉากกัน**

เทียบ vector ของประโยคเดียวกันระหว่าง MLX conversion กับ GGUF ที่ LM Studio เสิร์ฟ: cosine = **−0.0008, −0.0068, 0.0512** ไม่ใช่ "ต่างกันนิดหน่อย" แต่คือ**ไม่เกี่ยวข้องกันเลย**

ใครที่คิดว่าชื่อโมเดลคือสิ่งที่สำคัญ จะสลับสองอันนี้โดยใช้ index เดิม แล้ว**ทำลาย KB แบบเงียบสนิท** — ค้นได้ปกติ แต่จัดอันดับมั่ว นี่คือสิ่งที่ `EmbeddingProfile.revision` มีไว้ดัก และตอนนี้ไม่ใช่สมมติฐานอีกแล้ว

**อุปสรรค 3 ข้อที่ต้องผ่าน (ไม่มีข้อไหนเกี่ยวกับตัวโมเดล)**:

1. **Metal Toolchain ไม่ได้ติดตั้ง** — Xcode 26 แยกเป็น component ต่างหาก ถ้าไม่มี MLX ตายที่ `Failed to load the default metallib` แก้ด้วย `xcodebuild -downloadComponent MetalToolchain` (ติดตั้งแล้วบนเครื่องนี้) → **เป็น prerequisite ของเครื่องที่ build โปรเจกต์นี้ตั้งแต่นี้ไป**
2. **SwiftPM สร้าง Metal shader ไม่ได้** — README ของ mlx-swift เขียนเอง ต้อง build ผ่าน `xcodebuild` ขณะที่ `check.sh`/`build-app.sh` เป็น SwiftPM โดยเจตนา → ต้องมีขั้น `xcodebuild` เพิ่มเพื่อสร้าง `.metallib` อย่างเดียว
3. **`EmbedderRegistry.bge_m3` โหลดไม่ขึ้น** — มันชี้ไป `BAAI/bge-m3` ที่ weight ใช้ชื่อ layer แบบ HF แต่ BERT port ต้องการชื่อแบบ MLX (`keyNotFound(["encoder","layers","0","ln2","weight"])`) ต้องใช้ `mlx-community/bge-m3-mlx-8bit` แทน — **entry ใน registry ผิดกับโมเดลที่มันตั้งชื่อไว้เอง** ควรระวัง entry อื่นด้วย

## E.14 MLX chat runtime (Tier 0.5) — รันจริงตอน P5.1 (2026-08-12)

โมเดลสนทนาในโปรเซสเราเอง ผ่าน `LLMExecutor` ตัวเดียวกับอีกสอง tier วัดบน qwen3.5-9B-4bit (16 GB, LM Studio ปิด):

| เช็ค (เคสเดียวกับ Tier 0/Tier 1) | ผล |
|---|---|
| สตรีมเป็นชิ้น | ✅ 29 text + 456 reasoning delta |
| reasoning แยกจากคำตอบ | ✅ 676 ตัวอักษรของความคิด ไม่ปนเข้าคำตอบ |
| structured output ถอด JSON ได้ | ✅ 1.3 วิ (ก่อนแก้: ล้มเหลว 102.7 วิ — ดูข้างล่าง) |
| tool call ประกอบกลับเป็น JSON | ✅ `lookup_patient_count{"cohort":"diabetes"}` |
| prompt เกิน context | ✅ ปฏิเสธก่อนยิง ไม่ใช่ไปพังตอนรัน |
| โหลดค้างไว้ / ปลดตอน idle / โหลดกลับ | ✅ ทั้งสามข้อ |

**สามข้อที่ tier นี้ต้องทำเอง เพราะไม่มีโปรโตคอลไหนทำให้**

1. **`<think>` ที่ไม่มีแท็กเปิด** — chat template ของ Qwen ปิดท้าย generation prompt ด้วย `<think>\n` โมเดลจึงเริ่ม*กลาง*ความคิด และ output มีแต่ `</think>` ปลายทาง · splitter ที่รอแท็กเปิดจะรายงานความคิดทั้งก้อนเป็นคำตอบ = [E.9](#e9-vllmexecutor-spike--tier-1-ผ่าน-openai-compatible-endpoint) เคส 8c เวอร์ชัน local · แก้ด้วยการ **ถาม template** (render พรอมป์ต์ทดสอบแล้วดูว่า block ยังเปิดค้างอยู่ไหม) ไม่ใช่เดาจาก output — เดาไม่ทัน เพราะกว่า `</think>` จะมาถึง ความคิดก็ถูกสตรีมออกไปเป็นคำตอบแล้ว
2. **ไม่มี guided generation ใน mlx-swift-lm** — ไม่มี grammar/logit-constraint API เลย (ต่างจาก Tier 0 ที่มี `@Generable` และ Tier 1 ที่มี `response_format`) · schema จึงเป็นคำสั่งใน prompt แล้วดึง JSON object แรกที่ balanced และ parse ผ่านออกมา · **ไม่มี JSON = error ที่ escalate ได้ ไม่ใช่สตริงว่าง** — สตริงว่างคือสิ่งที่ปลายทางอ่านว่า "ไม่พบข้อขัดแย้ง"
3. **🔴 โมเดล reasoning + schema = คิดจนหมดเพดานแล้วไม่ตอบ** — ขอ routing object สองฟิลด์ ให้เพดาน 2,048 token: โมเดลใช้ทั้ง 2,048 ไปกับการคิด **102.7 วินาที ได้สตริงว่าง** · ปิด thinking ผ่าน `enable_thinking: false` ใน additionalContext ของ template → **1.3 วินาที** · ในงานที่คำตอบคือ "เติมสองช่องนี้" ไม่มีอะไรให้คิด และ tier ที่ทำงานได้เฉพาะตอนผู้เรียกใจกว้างเรื่องเพดาน ไม่ใช่พื้นรับประกันตาม [§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1) ข้อ 4

**สองข้อที่กระทบการออกแบบต่อไป**

- **context window ที่ประกาศ ≠ ที่เครื่องรับไหว** — config บอก 262,144 แต่ประกาศแค่ 32,768 · router คัดผู้สมัครจากตัวเลขนี้ ตัวเลขที่ใจกว้างจึงเท่ากับเชิญพรอมป์ต์ที่ทำเครื่องล่มเข้ามาพอดี (วัดไว้: prompt 7.6k โทเคน 9B = ~7.4 GB) — P5.3 จะแทนด้วยการวัด RAM จริง
- **sandbox ทำให้แอปกับ `check.sh` เห็นโมเดลคนละชุด** — `~/.lmstudio` และ `~/.cache/huggingface` อยู่นอก container จึงมองไม่เห็นจากในแอป (ที่เห็นคือ `Documents/huggingface/models` ของ container เอง ซึ่ง `HubApi` ใช้อยู่แล้ว) · แปลว่า "ใช้โมเดลที่มีอยู่แล้ว" ใน [§9.4](../ARCHITECTURE.md#94-mlx-local-tier-05--model-management) ต้องมาพร้อม open panel + security-scoped bookmark ไม่ใช่แค่ path ใน settings — งาน P5.2

## E.15 Model manager ในแอปที่ sandbox — เจอตอน P5.2 (2026-08-12)

Tier 0.5 คือ inference ในแอปนี้เอง แอปจึงต้องเป็นที่ที่โมเดล**มาจาก**ด้วย ([§9.4](../ARCHITECTURE.md#94-mlx-local-tier-05--model-management)) — กดโหลดจริงในแอปแล้ว (Qwen3-0.6B, 335 MB) ระหว่างทางเจอห้าเรื่องที่เทสระดับหน่วยไม่มีทางเห็น:

| อาการ | สาเหตุจริง |
|---|---|
| `Qwen3-VL-4B` ถูกเสนอเป็นโมเดลแชท แล้วพังตอนโหลด | มีไฟล์ครบทุกอย่างของโมเดลแชท (weights + tokenizer + chat template) แต่ `LLMModelFactory` ไม่มี implementation ของ `qwen3_vl` · และเป็นโมเดลใหญ่สุดบนเครื่อง จึงถูกเลือกเป็น Tier 0.5 พอดี → **ถาม `typeRegistry` ของ mlx-swift-lm ก่อนเสมอ** ทั้งตอนสแกนของที่มีอยู่และตอนทำรายการแนะนำ |
| โมเดล 335 MB กินดิสก์ 670 MB | `HubApi` มีที่เก็บสองที่โดยการออกแบบ: snapshot ที่ `downloadBase` กับแคชกลางแบบ content-addressed — สำเนาที่โควตาของเรามองไม่เห็นคือสำเนาที่ทำดิสก์เต็ม → `HubApi(downloadBase:cache: nil)` |
| กด "ยกเลิก" ขึ้น error สีแดง `NSURLErrorDomain -999` | การยกเลิก Task ไปถึง URLSession ก่อน จึงกลับมาเป็น NSError ไม่ใช่ `CancellationError` — ต้องแปลเองที่ขอบของ installer |
| แถบ progress เดินแต่ตัวเลขค้าง "0 MB / 0 MB" | `Progress` ที่ `snapshot` ส่งกลับนับ **ไฟล์** (unit ละไฟล์ ซอยย่อยข้างใน) ไม่ใช่ byte — ใช้ `fractionCompleted` คูณกับขนาดที่บันทึกไว้ |
| โมเดลใน HF cache รายงานขนาด ~0 | snapshot ในแคชเป็น symlink ไป `blobs/` — `fileSize` ของ link คือ 76 byte จึงแพ้ `preferred()` ให้ไฟล์จริงเสมอ |

**สองข้อที่เป็นเรื่องของการออกแบบ ไม่ใช่บั๊ก**

- **ดาวน์โหลดที่ยกเลิกไว้ต้องไม่นับว่า "ติดตั้งแล้ว"** — ไฟล์เล็กมาก่อน โมเดล 17 GB ที่ค้างจึงมี config + template + shard เดียว และอ่านว่าพร้อมใช้จนไปพังตอนโหลด · เช็ครายชื่อ shard จาก `model.safetensors.index.json` ให้ครบก่อน · เก็บไฟล์ไว้ (นั่นคือ resume) แต่ไม่เสนอ
- **Tier 0.5 เป็น "ช่อง" ไม่ใช่โมเดลตายตัว** — router ประกอบครั้งเดียวตอน boot แต่โมเดลเปลี่ยนระหว่างแอปทำงาน (โหลดตัวแรก, สลับ 4B→8B) ถ้าใส่ `MLXExecutor` ตรงๆ ทุกการเปลี่ยนต้องรีสตาร์ท — และการโหลดครั้งแรกบนเครื่องที่ไม่เคยมีโมเดล คือจังหวะที่คนกำลังดูอยู่พอดีว่ามันใช้ได้ไหม

**ผลข้างเคียงที่สำคัญต่อ [§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1)**: พอ Tier 0.5 มีจริง การเรียงแบบ "ถูกที่สุดก่อน" กลายเป็นอันตราย — เครื่องที่มีโมเดล 0.6B จะส่ง **planning/delegation** ไปให้มันแทน 27B บน endpoint · router จึงเรียงงาน high-impact ตามสายของ §9.2 (**1a → 0.5 → 1b**) ส่วน Tier 0.5 ยังอยู่ในสายในฐานะพื้นรับประกัน เพียงแต่ไม่ใช่ตัวแรก

## E.16 Admission control ที่วัดจากรูปร่างของโมเดล — P5.3 (2026-08-12)

สิ่งที่ชั้นนี้กันไม่ใช่คำตอบผิด แต่คือ**เครื่องหยุดตอบสนอง** — โมเดลที่ใหญ่กว่าที่ว่างไม่ได้ fail fast มันเข้า swap แล้วลากทั้งเครื่องไปด้วยหลายนาที

**ประเมินจาก config ของโมเดลเอง ไม่ใช่กฎคร่าวๆ** — `2 × layers × kv-heads × head-dim × 2 bytes` ต่อโทเคน บวก weights บวก overhead 0.5 GB:

| | qwen3.5-9B-4bit |
|---|---|
| weights บนดิสก์ | 5.6 GB |
| KV cache | 128 KB/token (32 layers × 4 kv heads × 256) → ~1.0 GB ที่ 7.6k |
| overhead | 0.5 GB |
| **ประเมินรวม** | **7.1 GB** |
| **วัดจริง** ([§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1) note ใน `Engine.swift`) | **~7.4 GB** |

คลาดต่ำกว่า 10% และมีเทสยืนยันตัวเลขนี้ — ตัวเลขที่ผิดทางสูงจะกันโมเดลที่รันได้ ตัวเลขที่ผิดทางต่ำจะทำเครื่องค้าง

**บังคับสามจุด ไม่ใช่จุดเดียว**

1. **ตอนตั้งเป็นตัวหลัก** — ปุ่มถูก disable พร้อมตัวเลขทั้งสองข้าง ([§9.4](../ARCHITECTURE.md#94-mlx-local-tier-05--model-management) บอกว่า "เตือนและไม่ให้ตั้ง default")
2. **ตอนทุก request** — `isAvailable()` ถามใหม่ทุกครั้ง เพราะโมเดลที่พอดีตอนเปิดแอปไม่พอดีตอนงานวิเคราะห์ถือ 10 GB · tier ที่ตอบว่า "ตอนนี้ไม่ว่าง" ทำให้ router ขึ้น tier ถัดไป ([§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1) ข้อ 2) ซึ่งดีกว่า tier ที่รับงานแล้วทำเครื่องล่ม · ถ้าโมเดลโหลดค้างอยู่แล้วถือว่าผ่าน — หน่วยความจำนั้นจ่ายไปแล้ว
3. **ตอนเลือกเองอัตโนมัติ** — `preferred()` คือ**ตัวใหญ่ที่สุดที่พอดี** ไม่ใช่ตัวใหญ่ที่สุด · ถ้าไม่มีตัวไหนพอดีเลยจะคืนตัวเล็กที่สุด (ไม่ใช่ nil) เพื่อให้ tier ยังมีชื่อโมเดลไว้อธิบาย และกลับมาใช้ได้ทันทีที่ RAM ว่าง

**เกิดขึ้นจริงระหว่างตรวจ**: LM Studio ถือ RAM อยู่ เหลือว่าง 6.1 GB → 9B ถูกปฏิเสธ → contract ทั้งชุดข้ามแบบดังๆ แทนที่จะรัน · นั่นคือพฤติกรรมที่ถูก และเป็นเหตุผลที่ `MLXCheck` ต้องแยก "ข้ามเพราะไม่มีที่" ออกจาก "ล้มเหลว" — ไม่งั้นชั้นที่ทำงานถูกจะรายงานว่าตัวเองพัง

## E.17 พื้นรับประกันที่ใช้ได้จริง — วัดตอน P5.4 (2026-08-12)

ปิด LM Studio จริง แล้วให้แอปตอบจากโมเดลบนเครื่อง — หัวแชทขึ้น `mlx:mlx-community/Qwen3-VL-4B-Instruct-4bit · tier 0.5` เส้นทางของ [§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1) ข้อ 4 จึงเป็นของจริงแล้ว ไม่ใช่ข้อความในเอกสาร

**VL checkpoint คือโมเดลแชท — แค่คนละโรงงาน** · `qwen3_vl` อยู่ใน `VLMModelFactory` ไม่ใช่ `LLMModelFactory` · ถามแค่ registry เดียวแปลว่าบนเครื่องที่มีแต่โมเดล VL จะ**ไม่มี Tier 0.5 เลย** ทั้งที่โมเดลตอบข้อความได้สบาย

**สี่อย่างที่ต้องมี ไม่งั้นโมเดล 4B ใช้งานจริงไม่ได้** (วัดบน Qwen3-VL-4B-4bit):

| อาการ | สิ่งที่แก้ |
|---|---|
| `{"role: "engineer"` — key ขาด quote ปิด ไม่มีปีกกาปิด | ใส่ **ตัวอย่างให้ลอก** ที่สร้างจาก schema (`{"role": "researcher", "needsClarification": false}`) แทนการยื่น spec ให้ตีความ |
| ขอ JSON แล้วได้บ้างไม่ได้บ้าง | **temperature 0** ตอนมี schema — การสุ่มคือสิ่งที่ทำให้ quote หาย |
| retry แล้วผิดซ้ำแบบเดิมเป๊ะ | ที่ temperature 0 การลองใหม่ได้โทเคนชุดเดิม → **รอบสองต้อง sample ต่างออกไป** (0.4) พร้อมบอกตรงๆ ว่ารอบแรกไม่ใช่ JSON |
| ตอบ `ไมรนบน` สามร้อยรอบ บน transcript ไทยที่ย่อแล้ว | **repetition penalty 1.05** — endpoint แบบ hosted ใส่ให้อยู่แล้ว, mlx-swift-lm ไม่ใส่ให้ถ้าไม่สั่ง |

นอกจากนั้นยังต้อง**เก็บกู้ tool call ที่ parser มองไม่เห็น**: โมเดลลอกตัวอย่างใน chat template ของตัวเองแล้วพิมพ์ `<tool_call>` สองครั้ง — ตัว call ถูกต้องทุกอย่าง แต่ห่ออยู่ในแท็กเกินหนึ่งอัน จึงหลุดออกมาเป็น prose

**คุณภาพที่ได้จริง — พูดตรงๆ**: เลขถูก (17×3 = 51) แต่สะกดไทยเพี้ยน ("เทากบ") และตัดสินคู่ metformin ("ต้องให้" กับ "ห้ามให้") ว่า**ไม่ขัดแย้ง** · ตรงกับตาราง [§9.4](../ARCHITECTURE.md#94-mlx-local-tier-05--model-management): เครื่อง < 16 GB ได้โมเดลระดับ fallback ไม่ใช่ระดับนักวิเคราะห์ · พื้นรับประกัน**มีจริง** แต่พื้นก็คือพื้น

**สองข้อที่เปลี่ยนวิธีทำงานของโปรเจกต์**

- **`tier 0.5` ไม่ใช่ `tier 1`** — UI พิมพ์ `rawValue` ของ enum ทำให้โมเดลบนเครื่องดูเหมือน endpoint ที่มันเพิ่งตกลงมาจาก · tier มีชื่อของมันใน §9.2 แล้ว UI ต้องเรียกตามนั้น
- **skip ต้องดังแต่ไม่ทำให้ build แดง** — เดิมสวีต Tier 1 บันทึกการข้ามเป็น Issue เครื่องที่ไม่มี LM Studio จึงไม่มีวันได้ชุดเทสสีเขียว ทั้งที่นั่นคือ*ปลายทาง*ของ P5 · ตอนนี้พิมพ์ `SKIPPED:` แล้ว `check.sh` ยกมาแสดง — เห็นชัดเท่าเดิม แต่ไม่ลงโทษเครื่องที่รันตัวเองได้ล้วนๆ

## E.18 ทะเบียน endpoint กับเพดานเงิน — สร้างตอน P5.5–P5.7 (2026-08-12)

สร้างทั้งชั้นก่อนที่จะมี endpoint จริงให้ต่อ (GX10 ยังไม่เสร็จ) — สิ่งที่พิสูจน์ได้ตอนนี้คือ*พฤติกรรม*ของมัน ไม่ใช่ตัวเลขค่าใช้จ่ายจริง และหน้าจอบอกความจริงข้อนั้นเองว่า "ยังไม่มี endpoint ที่คิดเงิน เพดานจึงยังไม่มีผลกับอะไร"

**สามการตัดสินใจที่มีผลกับโครงสร้าง**

| เรื่อง | ทำไมเป็นแบบนี้ |
|---|---|
| **บันทึก endpoint ได้ต่อเมื่อ probe ผ่าน** | [E.9](#e9-vllmexecutor-spike--tier-1-ผ่าน-openai-compatible-endpoint) เคส 8a: เซิร์ฟเวอร์ OpenAI-compatible ตอบรับชื่อโมเดลที่ไม่มีอยู่ ความผิดพลาดจึงไปโผล่ทีหลังในที่ที่ไม่มีใครรู้ว่าพิมพ์ชื่อผิด · ทะเบียนที่เต็มไปด้วย endpoint ที่ไม่เคยต่อติดคือรายการงานที่ต้องมาไล่เช็คเองทีหลัง |
| **`SpendLedger` อยู่ใน AgentKit** | สามโมดูลต้องใช้และไม่ควรต้องรู้จักกัน: `Config` เขียนเพดาน, `Persistence` เก็บยอด, `LLMProviders` เป็นที่ที่สองอย่างนั้นมาเจอกัน — รูปแบบเดียวกับ `Embedder` ที่ `Knowledge` ประกาศแล้ว `EmbeddingRuntime` ทำ |
| **API key เก็บแค่ชื่อตัวแปร env** | bootstrap.plist เป็นไฟล์ธรรมดาใน Application Support · คีย์ในนั้นคือคีย์ที่วางอยู่บนดิสก์ · Keychain จริงเป็น P9.2 แต่ระหว่างนี้ paid endpoint ต้องใช้งานได้ |

**เพดานที่บอกว่าชั้นไหนเต็ม** — "เกินงบ" เฉยๆ คือข้อความที่ทำให้คนปิดระบบงบทิ้ง ข้อความจึงบอกทั้งชั้นที่ชน ยอดที่ประเมิน และยอดที่เหลือ · และ**เกินเพดานไม่ใช่ error**: งานตกไป Tier 1a/0.5 แล้วทำต่อ ([§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1) ข้อ 4) ผู้ใช้รู้จาก span ไม่ใช่จากความล้มเหลว

**ประเมินก่อน จ่ายจริงทีหลัง** — ตัดสินใจด้วยการประเมินจาก `maxTokens` (มองโลกในแง่ร้ายโดยตั้งใจ: ประเมินต่ำคือวิธีที่เพดานถูกข้ามโดยไม่เคยชน) แล้วลงบัญชีจาก `usage` ที่ endpoint คืนมาจริง ซึ่ง E.9 ยืนยันแล้วว่ามีทั้งแบบ streaming และไม่ streaming · **endpoint ที่คิดเงินแต่ไม่ได้ตั้งราคา = governor ไม่ยอมให้ใช้เลย** ดีกว่าเดาด้วยเงินคนอื่น

**P4.7 ที่ค้างอยู่ก็ปิดในรอบเดียวกัน** — ปุ่มสั่งแก้/ยกเลิกรายชิ้น · สองอย่างที่ไม่ใช่รายละเอียด: (1) การสั่งแก้**บังคับให้พิมพ์เหตุผล** และเหตุผลนั้นเดินทางไปทางเดียวกับ findings ของ QA — "ทำใหม่อีกรอบ" เฉยๆ คือคำสั่งที่ทำให้ loop ของ v1 วน (2) การยกเลิกถูก**บันทึกเป็น `cancelled` ไม่ใช่ลบทิ้ง** และ run-until-done ข้ามมันเหมือนที่ข้าม escalation — ทั้งคู่คือการตัดสินใจของคน และการหยิบขึ้นมาทำเองคือการกลับคำตัดสินนั้น

## E.4 สถานะ dependency หลัก (จาก GitHub API วันที่ตรวจ)

| Dependency | ตัวเลขจริง | ประเมิน |
|---|---|---|
| [`surrealdb.swift`](https://github.com/surrealdb/surrealdb.swift) | ⭐ **5** · สร้าง 2026-02-24 · push 2026-07-14 · **ไม่มี release** · README: *"API subject to breaking changes without notice"* · remote-only | 🔴 **ไม่พึ่ง** → เขียน client เอง ([§11.5](../ARCHITECTURE.md#115-surrealdb-sidecar--client-ของเราเอง)) |
| [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) | ⭐ 1.5k · 216 forks · **v0.12.1** (2026-05-07) · stdio transport ✅ · macOS 13+ | ✅ **ใช้ได้** (ระวัง minor version อาจ breaking ก่อน 1.0) |
| [`duckdb-swift`](https://github.com/duckdb/duckdb-swift) | ⭐ 134 · push 2026-07-22 · tag ล่าสุด `v1.6.0-dev11145` · ทีม DuckDB ดูแลเอง | ✅ **ใช้ได้** — ยังต้อง spike ว่า `INSTALL/LOAD` extension (postgres_scanner) ทำได้จาก Swift |
| [`sqlite-vec`](https://github.com/asg017/sqlite-vec) | ⭐ **7,996** · push 2026-05-18 | ✅ Plan B ที่แข็งแรง |
| [`SQLiteVecKit`](https://github.com/carlosypunto/SQLiteVecKit) (Swift wrapper) | ⭐ 1 · 2 commits · v0.1.0 | 🔴 ใหม่เกินไป — ถ้าใช้ Plan B ให้ bundle C extension เอง |
| [`SwiftMCP`](https://github.com/sutheesh/SwiftMCP) | bridge Foundation Models ↔ MCP ผ่าน `DynamicGenerationSchema` | ✅ ใช้เป็น reference pattern ได้ (เขียนเองก็ไม่ยากเพราะ `DynamicGenerationSchema` มีในเครื่องแล้ว) |
| PostgresNIO / MySQLNIO / mongo-swift-driver | PostgresNIO ผ่าน Swift Server Working Group; mongo driver wrap libmongoc | ✅ มีทางเลือก native ครบ |

## E.5 Web search — ข้อสรุปที่ verify แล้ว

- 🔴 **Apple ไม่มี web search API สำหรับนักพัฒนา** — "World Knowledge Answers" เป็นฟีเจอร์ของ Siri (macOS 27) ไม่ใช่ public API; iTunes/App Store Search API ค้นได้แค่ content ใน store
- 🔴 **Brave Search API ปิด free tier สำหรับผู้ใช้ใหม่แล้ว** (ต้นปี 2026) เหลือ $5 credit/เดือน ≈ 1,000 query; แผนเดิม 100 query/วัน จะปิดถาวร **1 ม.ค. 2027**
- ✅ **ฟรีถาวรจริง**: SearXNG self-hosted (ติดตั้ง native บน macOS ได้ ไม่ต้อง Docker) + API ทางการของ PubMed E-utilities / medRxiv / OpenAlex / Crossref สำหรับ tier 1–3

## E.6 D-7 Spike — guided generation ใน app target จริง

รันเป็น executable ที่มี `NSApplication` runloop (โค้ด spike อยู่ใน scratchpad) — ทุก call มี hard timeout กัน hang เงียบ:

| # | เคส | เวลา | ผล |
|---|---|---|---|
| 0 | control: prose ธรรมดา `respond(to:)` | 6,209 ms | ⚠️ ตอบเลี่ยง (*"As an AI language model, I'm prohibited…"*) — ตอกย้ำว่าอย่าใช้ prose |
| 1 | guided/struct/EN | **571 ms** | ✅ `role=researcher clarify=true` |
| 2 | guided/struct/TH | 1 ms | 🔴 **REFUSED** — "May contain sensitive content" (prompt: หางานวิจัยวัคซีน mRNA ในผู้สูงอายุ) |
| 3 | guided/`@Generable` enum/TH | **917 ms** | ✅ `role=researcher reason="Analyze age-related diabetes patterns."` |
| 4 | guided/warm session (call ที่ 2) | **673 ms** | ✅ `severity=critical field="Diabetes definition"` |
| 5 | guided/หลัง `prewarm()` | **629 ms** | ✅ `role=analyst` |
| 6 | guided/**streaming** | 632 ms | ✅ snapshot แรกที่ **508 ms**, รวม 2 snapshots |
| 7 | **tool calling** (`Tool` protocol + `@Generable Arguments`) | 1,281 ms | ✅ `toolUsed=true` → *"There are 1,234 patients in the diabetes cohort."* |

**ข้อสรุป**: กลไกที่ Tier 0 และ ToolBelt ต้องใช้ (**guided generation, streaming, tool calling**) ทำงานครบและเร็วพอ — การค้างที่เจอตอนทดสอบผ่าน CLI เป็นข้อจำกัดของ command-line context ไม่ใช่ของ API

## E.7 Guardrail characterization — โดเมนการแพทย์

16 prompt งานวิจัยการแพทย์/สาธารณสุข (ไทย+อังกฤษ) × 2 โหมด guardrail = 32 การเรียก:

| topic | TH default / permissive | EN default / permissive |
|---|---|---|
| vaccine-mRNA | ✅ 1,754 / ✅ 1,183 ms | 🔴 **REFUSED** / 🔴 **REFUSED** |
| diabetes | ✅ 925 / ✅ 773 | ✅ 963 / ✅ 822 |
| covid-outbreak | ✅ 883 / ✅ 988 | ✅ 855 / ✅ 822 |
| cancer-survival | ✅ 816 / ✅ 1,015 | ✅ 956 / ✅ 895 |
| drug-dosage | 🔴 **REFUSED** / 🔴 **REFUSED** | ✅ 749 / ✅ 878 |
| mental-health (suicide rate) | ✅ 801 / ✅ 966 | ✅ 961 / ✅ 957 |
| hiv-cohort | ✅ 799 / ✅ 855 | ✅ 739 / ✅ 723 |
| plain-code / plain-writing | ✅ 1,036 / ✅ 703 | — |

**อัตราการปฏิเสธ: 2/16 (12.5%) เท่ากันทั้งสองโหมด**

ข้อสรุป 4 ข้อที่มีผลต่อสถาปัตยกรรม:

1. **ปฏิเสธงานวิจัยการแพทย์ปกติจริง** — "หางานวิจัยวัคซีน mRNA ในผู้สูงอายุ" และ "ตรวจสอบขนาดยา metformin ตามแนวทางเวชปฏิบัติ" ไม่ใช่คำขอที่มีปัญหาใดๆ
2. **ไม่ deterministic** — prompt วัคซีนภาษาไทยถูกปฏิเสธในรอบแรก แต่ผ่านในรอบสอง ส่วนภาษาอังกฤษกลับกัน → **ทำนายไม่ได้ ต้องออกแบบให้ทนต่อมันแทนที่จะหลบ**
3. **`permissiveContentTransformations` ไม่ช่วย** — ปฏิเสธเคสเดียวกันเป๊ะ (การตั้งชื่อบอกอยู่แล้วว่าเกี่ยวกับ *content transformation* ไม่ใช่การผ่อนเรื่อง safety topic)
4. **คุณภาพการ route ปานกลาง** — prompt เดียวกันให้คำตอบต่างกันระหว่างสองโหมด (`แก้บั๊กใน main.swift` → `engineer` แล้ว `researcher`), งานวิเคราะห์หลายอันได้ `researcher` แทน `analyst` → ใช้ตัดสินใจสำคัญไม่ได้

## E.10 D-2 — เลือก embedding model (วัดจริง, ปิดแล้ว)

ชุดทดสอบ: 20 เอกสาร (ไทย 10 / อังกฤษ 10) เนื้อหาการแพทย์+สถิติ พร้อม distractor คนละโดเมน · 12 query · วัด recall@1, recall@3, MRR และ **cross-lingual** (query ภาษาหนึ่งดึงเอกสารอีกภาษาที่เกี่ยวข้องได้ไหม) — harness เก็บไว้ที่ [`spikes/EmbeddingEval/`](../spikes/EmbeddingEval/)

| provider | dim | recall@1 | recall@3 | MRR | cross-lingual | fails |
|---|---|---|---|---|---|---|
| `NLEmbedding.sentence` | 512 | 50.0% | 50.0% | 0.500 | 0.0% | **16** |
| `NLContextualEmbedding` | 512 | 50.0% | 66.7% | 0.599 | 0.0% | 0 |
| `nomic-embed-text-v1.5` | 768 | 66.7% | 75.0% | 0.751 | 41.7% | 0 |
| **`bge-m3`** | **1024** | **100%** | **100%** | **1.000** | **100%** | 0 |

**ข้อเท็จจริงที่ตัดสินเรื่องนี้ — เป็นข้อจำกัดเชิงโครงสร้าง ไม่ใช่การปรับจูน**:

1. 🔴 **Apple ไม่มี sentence embedding ภาษาไทย** — `NLEmbedding.sentenceEmbedding(for: .thai)` คืน `nil` (fail ทั้ง 16 ครั้งคือฝั่งไทยล้วน)
2. 🔴 **`NLContextualEmbedding` แยกโมเดลตามสคริปต์ ไม่ใช่ multilingual ตัวเดียว** — ตรวจ `languages` จริง: โมเดลของไทยครอบ **1 ภาษา (`th`) เท่านั้น**, โมเดล Latin ครอบ 20 ภาษา (cs, da, de, en, …) **แต่ไม่มีไทย** → เอกสารไทยกับอังกฤษอยู่คนละ vector space **cross-lingual retrieval จึงเป็นไปไม่ได้เชิงโครงสร้าง** ไม่ว่าจะ pooling แบบไหน
3. ✅ **`bge-m3` ทำได้ 100% ทุกมิติบนชุดนี้** — สร้างมาเพื่อ multilingual retrieval โดยตรง (100+ ภาษา, context ยาวถึง 8192 token), ขนาด 634MB (567M params)

**Decision (2026-08-10): ใช้ `bge-m3` ที่ 1024 มิติ** — เหตุผลที่ชี้ขาดคือ **cross-lingual**: KB ของระบบนี้มี proposal ภาษาไทยปนกับ paper ภาษาอังกฤษเสมอ ถ้าค้นด้วยคำไทยแล้วไม่แตะเอกสารอังกฤษเลย ระบบจะพลาดครึ่งหนึ่งของ KB **โดยที่ผู้ใช้ไม่มีทางรู้** — เป็น failure mode ที่เงียบและอันตรายที่สุดของ RAG

**ข้อจำกัดของการวัดนี้ (ต้องบันทึกไว้)**: ชุดทดสอบมีแค่ 20 เอกสาร/12 query — คะแนนเต็ม 100% แปลว่าชุดนี้**แยกความต่างที่ปลายบนไม่ได้อีกแล้ว** ไม่ใช่ว่าโมเดลสมบูรณ์แบบ ใช้ตัดสินได้เพราะช่องว่างกับอันดับสอง (1.000 vs 0.751) กว้างมาก แต่ถ้าจะเทียบ bge-m3 กับ multilingual ตัวอื่นในอนาคต **ต้องสร้างชุดที่ยากกว่านี้ก่อน**

**ผลต่อสถาปัตยกรรม**: มิติ 1024 ถูกล็อกเข้ากับ HNSW index — เปลี่ยนโมเดลทีหลัง = re-index ทั้ง KB และ **bge-m3 ต้องรันในเครื่องเราเอง ไม่ใช่พึ่ง LM Studio** ([§9.4](../ARCHITECTURE.md#94-mlx-local-tier-05--model-management) `MLXRuntime` ต้องโฮสต์โมเดล embedding ด้วย ไม่ใช่แค่โมเดลสนทนา)

## E.8 SurrealClient spike — เขียน client เอง กับ SurrealDB v3.2.0

ทดสอบว่า **ไม่ต้องพึ่ง `surrealdb.swift` (alpha)** ได้จริงไหม — เขียน `SurrealClient` เอง (~200 บรรทัด, JSON-RPC over `URLSessionWebSocketTask`) แล้วรันกับ `surreal` v3.2.0 จริง (storage `surrealkv`, bind `127.0.0.1:18000`) โค้ดที่ผ่านการทดสอบเก็บไว้ที่ [`spikes/SurrealClient/`](../spikes/SurrealClient/)

| # | เคส | เวลา | ผล |
|---|---|---|---|
| 1 | connect + signin + use | 48 ms | ✅ |
| 2 | schema: FULLTEXT(BM25) + HNSW + graph table | 130 ms | ✅ |
| 3 | insert 5 chunk (ข้อความไทย + embedding) | 69 ms | ✅ |
| 4 | **BM25 full-text ภาษาไทย** | 1 ms | ✅ เจอ "วัคซีน mRNA" score **2.3815** จาก query "ผู้สูงอายุ วัคซีน" |
| 5a | **HNSW KNN** `<\|3,40\|>` (vector เป็น `$param`) | <1 ms | ✅ อันดับถูก, `dist=0.0000` สำหรับ exact match |
| 5b | HNSW KNN (vector เป็น literal) | <1 ms | ✅ ผลเหมือน 5a |
| 5c | `vector::similarity::cosine` (ไม่ใช้ index) | <1 ms | ✅ `sim=1.0000` |
| 6 | **RELATE + graph traversal** | 14 ms | ✅ `entity:vaccine ->studied_in-> [ผู้สูงอายุ]` |
| 7 | **hybrid search (BM25 + vector, RRF fuse ใน Swift)** | 1 ms | ✅ `วัคซีน mRNA(0.0328), Survival analysis(0.0161)` |
| 8 | 10 query ขนานกัน | 1 ms | ✅ ครบทั้ง 10 ไม่มี response ปนกัน |
| 9 | SQL ผิด → error กลับมาถูกต้อง | <1 ms | ✅ ไม่ crash, ได้ error message ที่อ่านรู้เรื่อง |
| 10 | ปิด connection แล้วต่อใหม่ | 31 ms | ✅ ข้อมูลอยู่ครบ (count=5) |

**ข้อสรุป**: ความสามารถทั้งหมดที่ M7 ต้องใช้ (**BM25 ไทย + HNSW vector + graph + hybrid + concurrency + reconnect**) ทำงานครบผ่าน client ที่เราเขียนเอง — **ปิดความเสี่ยงเรื่อง SDK alpha ได้แล้ว** และ pipeline ตัดคำไทยด้วย `NLTokenizer` → BM25 index ทำงาน end-to-end จริง (ยืนยัน D-1 อีกชั้น)

ราคาที่จ่าย: ต้องดูแล wire protocol เอง (~200 บรรทัด) + เจอกับดักเฉพาะ Swift 3 อย่างระหว่างทาง (บันทึกไว้ที่ [ภาคผนวก C.0](ENGINEERING_NOTES.md#c0-surrealdb-v320-quirks--ยืนยันซ้ำค้นพบใหม่จาก-spike-ฝั่ง-swift-2026-08-10))

## E.9 VLLMExecutor spike — Tier 1 ผ่าน OpenAI-compatible endpoint

ทดสอบ `LLMExecutor` protocol ของเราเอง ([§9.1](../ARCHITECTURE.md#91-llm-abstraction-ของเราเอง-รองรับทั้งสองยุค)) กับ endpoint จริง — LM Studio + `meta-llama-3.1-8b-instruct` บนเครื่องเดียวกัน (โปรโตคอลเดียวกับ vLLM บน GX10) โค้ดเก็บไว้ที่ [`spikes/LLMExecutor/`](../spikes/LLMExecutor/)

| # | เคส | เวลา | ผล |
|---|---|---|---|
| 1 | non-streaming + token accounting | 2,428 ms | ✅ `p=47 c=17 finish=stop` |
| 2 | **SSE streaming** | 1,770 ms | ✅ **TTFT 612 ms**, 40 deltas, usage มากับ stream |
| 3 | **tool call** (non-streaming) | 708 ms | ✅ `lookup_patient_count({"cohort":"diabetes"})` |
| 4 | **tool call (streaming, argument แตกเป็นชิ้น)** | 1,392 ms | ✅ ประกอบ JSON กลับได้ถูกต้อง |
| 5 | **structured output ผ่าน `json_schema`** | 2,228 ms | ✅ schema ถูกบังคับจริง (Tier-1 analogue ของ `@Generable`) |
| 6 | **prompt ไทยที่ Tier 0 ปฏิเสธ** | 1,851 ms | ✅ **ไม่ถูกปฏิเสธ** — ยืนยันว่า escalate ไป Tier 1 แก้ปัญหา D-9 ได้จริง |
| 7 | **full tool round-trip** (call → result → คำตอบ) | 2,377 ms | ✅ คำตอบสุดท้ายใช้ผลจาก tool จริง |
| 8a | model ที่ไม่มีอยู่ | 383 ms | ⚠️ **endpoint ยอมรับเฉยๆ ไม่ error** → ต้อง validate ฝั่ง client |
| 8b | endpoint ตายสนิท | 1 ms | ✅ error ชัด (`NSURLErrorCannotConnectToHost`) |
| 8c | validate model กับ `/v1/models` | 2 ms | ✅ กันปัญหา 8a ได้ |
| 9 | **ยกเลิกกลาง stream (ปุ่ม Stop)** | 431 ms | ✅ หยุดหลัง 5 delta, stream ถูกปิดจริง |
| 10 | 3 request ขนานกัน | 676 ms | ✅ 3/3 |

**บทเรียนที่ต้องเขียนไว้ไม่งั้นเสียเวลาแน่**:

1. 🔴 **assistant message ต้องพก `tool_calls` เดิมกลับไปด้วย ไม่ใช่แค่ `tool_call_id`** — รอบแรกส่งแค่ id ทำให้โมเดล**ตอบกลับมาเป็นข้อความว่างเปล่า ไม่มี error ใดๆ** กว่าจะรู้ต้องไล่ดูเอง (นี่คือ agent loop ทั้งเส้น — ถ้าพลาดจุดนี้ระบบจะเงียบและพังแบบหาสาเหตุยาก)
2. 🔴 **endpoint ไม่ validate ชื่อ model** — ส่งชื่อมั่วไปก็ยังตอบกลับมาปกติ → `EndpointRegistry` ([§9.3](../ARCHITECTURE.md#93-endpoint-registry)) **ต้องเช็คกับ `/v1/models` ตอนตั้งค่า** ไม่ใช่รอ error ตอนใช้งานจริง
3. **tool call argument มาเป็นชิ้นๆ ใน streaming** — ต้องสะสมตาม `index` แล้วค่อย parse ตอนจบ (parse ระหว่างทางจะได้ JSON พังตลอด)
4. **chunk ที่ parse ไม่ได้ต้องข้าม ไม่ใช่ throw** — SSE มี chunk แปลกๆ ปนได้ ระบบต้องทนได้
5. **`[String: Any]` ใน Swift 6 ข้าม concurrency boundary ไม่ได้** (บทเรียนเดียวกับ SurrealClient) → JSON Schema เก็บเป็น **string** ซึ่งเหมาะอยู่แล้วเพราะเป็นค่าคงที่

**เทียบ Tier 0 vs Tier 1 (วัดบนเครื่องเดียวกัน)**: routing แบบ structured — Tier 0 ~0.6–0.9 วิ · Tier 1 (8B) ~2.2 วิ **แต่ Tier 1 ไม่ปฏิเสธและผลนิ่งกว่า** → ยืนยันการแบ่งงานใน [§9.2](../ARCHITECTURE.md#92-model-router-tier-0--05--1) ว่าสมเหตุสมผล (โมเดลจริงบน GX10 คือ 27B จะช้ากว่านี้อีก แต่คุณภาพสูงกว่า)

---

