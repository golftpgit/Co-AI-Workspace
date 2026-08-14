# Engineering Notes — quirk ที่กัดจริง และวิธีที่แก้ไปแล้ว

> เอกสารอ้างอิง · คู่กับ [`ARCHITECTURE.md`](../ARCHITECTURE.md)
> อ่านเมื่อ: กำลังเขียนโค้ดที่แตะ SurrealDB / การ bind ค่า / decoding JSON แล้วเจออาการแปลก ๆ — ก่อนจะสรุปว่าเป็นบั๊กของ engine อ่านที่นี่ก่อน
>
> **บทเรียนรวมของทั้งไฟล์**: 3 ใน 5 ข้อที่ "ดูเหมือนบั๊กของ SurrealDB" **เป็นบั๊กของเราเอง** — เจอได้เพราะเทสกับ engine จริง (mock ผ่านหมดทุกข้อ)

| ส่วน | เนื้อหา |
|---|---|
| [C.0](#c0-surrealdb-v320-quirks--ยืนยันซ้ำค้นพบใหม่จาก-spike-ฝั่ง-swift-2026-08-10) | SurrealDB v3.2.0 quirks ฝั่ง Swift + 7 บั๊กที่มี regression test คุมแล้ว |
| [C.1](#c1-surrealdb-v3-quirks-เจอจริงตอน-implement-v1--เป็น-surrealql-level-ไม่ใช่-rust-specific) | SurrealQL-level quirks จาก v1 |
| [C.2](#c2-บทเรียนเชิงกระบวนการจาก-v1) | บทเรียนเชิงกระบวนการ |

---


## C.0 SurrealDB v3.2.0 quirks — ยืนยันซ้ำ/ค้นพบใหม่จาก spike ฝั่ง Swift (2026-08-10)

ทดสอบจริงกับ SurrealDB **v3.2.0** ผ่าน `SurrealClient` ที่เขียนเอง ([E.8](VERIFICATION_LOG.md#e8-surrealclient-spike--เขียน-client-เอง-กับ-surrealdb-v320)):

| quirk | สถานะ | รายละเอียด |
|---|---|---|
| `type::thing('tbl', $id)` | 🆕 **ถูกถอดออกแล้วใน v3.2** | error: *"Invalid function/constant path, did you maybe mean `type::record`"* → ใช้ **`type::record('tbl', $id)`** แทน (v1 ใช้ `type::thing` ทั้งระบบ — ต้องเปลี่ยนทุกจุด) |
| `DEFINE ANALYZER/TABLE/INDEX` ซ้ำ | 🆕 **ไม่ idempotent** | รันซ้ำ = error *"analyzer already exists"* → schema bootstrap **ต้องใช้ `IF NOT EXISTS` ทุก statement** ไม่งั้นแอปเปิดครั้งที่สองพัง |
| `ORDER BY search::score(1)` | ✅ ยืนยันว่ายังจริง | ต้อง project ก่อน: `SELECT *, search::score(1) AS relevance ... ORDER BY relevance DESC` |
| `RELATE` ต้อง bind ผ่าน `LET` | ✅ ยืนยันว่ายังจริง | `LET $src = entity:x; LET $tgt = entity:y; RELATE $src->edge->$tgt` ทำงานถูกต้อง, traversal `SELECT ->edge->entity.name FROM entity:x` คืนค่าถูก |
| `FULLTEXT ANALYZER ... BM25(k1,b) HIGHLIGHTS` | ✅ ยืนยันว่ายังจริง | ไม่ใช่ `SEARCH ANALYZER` |
| HNSW `<\|k,ef\|>` + `vector::distance::knn()` | ✅ **ใช้ได้ทั้ง `$param` และ literal** | ครั้งแรกที่เห็นค่าเป็น `false` เกิดจากบั๊ก decoder ฝั่งเราเอง ไม่ใช่ของ SurrealDB (ดูแถวถัดไป) |

**🆕 ค้นพบเพิ่มระหว่าง implement P1.2–P1.6 (2026-08-10) — ทุกข้อมี regression test คุมแล้ว**:

| # | อาการ | สาเหตุจริง | วิธีแก้ที่ใช้ |
|---|---|---|---|
| 1 | bound string ที่มี `/` (path, URL) → **RPC ไม่ตอบกลับเลย ค้างจนหมด timeout** | 🔴 **บั๊กของเราเอง** — `JSONSerialization` escape `/` เป็น `\/` โดย default แล้ว WS parser ของ SurrealDB ค้างกับ escape นั้น | ใส่ `.withoutEscapingSlashes` ตอน serialize RPC frame — หลังแก้ path/URL/ไทย/colon ผ่านหมด ([`BindingShapeTests`](../Tests/PersistenceTests/BindingShapeTests.swift) คุมไว้ 12 shape) |
| 2 | bound string ที่หน้าตาเป็น UUID → กลายเป็น **ค่า UUID** (`u'…'`) ตกเงื่อนไข `TYPE string` | SurrealDB v3 เดาชนิดจากรูปร่างของ string ที่ bind มา | ใช้ `AgentKit.OpaqueID` (prefix + hex ไม่มี dash) เป็น id ทุกที่ — ไม่มีทางถูกตีความเป็นชนิดอื่น |
| 3 | `UPDATE` บน record ที่ยังไม่มี → error ไม่ใช่ upsert | v3 แยก `UPDATE` กับ `UPSERT` ชัดเจน | ใช้ `UPSERT` สำหรับ span/schema_meta |
| 4 | `NULL` ผ่าน `option<string>` ไม่ได้ | `NULL` ≠ `NONE` ใน v3 | `ContentBuilder` **ตัด field ที่เป็น nil ทิ้ง** แทนการ bind null |
| 5 | client ค้างถาวรเมื่อยิง request ถี่ๆ | 🔴 **race ในโค้ดเรา** — ลงทะเบียน continuation ผ่าน `Task` แยก ทำให้ response ที่มาเร็วกว่าหา waiter ไม่เจอแล้วถูกทิ้ง | ลงทะเบียนแบบ synchronous ในบริบท actor ก่อนส่ง frame; timeout แยกเป็น task ที่ fail รายการใน `pending` (กัน double-resume ด้วย `removeValue`) |

**🆕 ค้นพบเพิ่มระหว่าง implement P1.7–P1.10 (2026-08-10) — ต่อยอดจากข้อ 2 ข้างบน**:

| # | อาการ | สาเหตุจริง | วิธีแก้ที่ใช้ |
|---|---|---|---|
| 6 | **span ทุกตัวที่ gate/router/broker/process ปล่อยออกมา หายไปเงียบๆ** ทั้งที่ span ชื่อ `turn` เข้า DB ปกติ | ข้อ 2 ในรูปแบบที่ร้ายกว่า: **bound string ที่มีรูปร่าง `table:id` ถูกตีเป็น record link** → `tool:run_shell`, `llm:gx10`, `approval:run_shell` ตกเงื่อนไข `TYPE string` ทั้งหมด (`Couldn't coerce value for field name … Expected string but found tool:run_shell`) — และ `SurrealSpanSink` กลืน error ลง console fallback ตามดีไซน์ จึงไม่มีใครเห็น | `ContentBuilder.setString()` bind ผ่าน **`type::string($x)`** สำหรับทุก field ที่เป็นข้อความซึ่งเราไม่ได้กำหนดรูปร่างเอง (span name/detail/parent, message content, conversation title) |
| 7 | ผลข้างเคียงของข้อ 6 ที่ยังไม่ทันเกิด: **ข้อความของผู้ใช้ที่พิมพ์ว่า `note:1` จะบันทึกไม่ลง** | เหมือนกัน — user text ไม่มีทางบังคับรูปร่างได้ | `append()` bind `content` ผ่าน `type::string()` เช่นกัน ([`RecordShapedTextTests`](../Tests/PersistenceTests/PersistenceTests.swift) คุมทั้งสองข้อ) |

**หลักที่ได้**: id ของเราเลี่ยง `:` ได้ (OpaqueID) แต่ **ข้อความที่ module อื่นหรือผู้ใช้เป็นคนเลือก เลี่ยงไม่ได้** → ต้องปักชนิดด้วย `type::string()` ที่ขอบ persistence ไม่ใช่ไปห้ามคนตั้งชื่อ. อีกบทเรียน: **sink ที่ fail แบบเงียบเพื่อไม่ให้ล้ม turn จะซ่อนบั๊กชนิดนี้ได้นาน** — สิ่งที่จับได้คือ end-to-end test ที่อ่าน span กลับจาก DB จริง ไม่ใช่ unit test ที่ใช้ in-memory sink

**บทเรียนรวม**: 3 ใน 5 ข้อที่ "ดูเหมือนบั๊กของ SurrealDB" **เป็นบั๊กของเราเอง** — การเทสกับ engine จริงตั้งแต่ต้นคือสิ่งเดียวที่ทำให้เจอ (mock จะผ่านหมดทุกข้อ)

**🆕 กับดักฝั่ง Swift ที่ไม่เกี่ยวกับ SurrealDB แต่ทำให้ข้อมูลเพี้ยนเงียบๆ**:

- **`x as? Bool` สำเร็จกับ `NSNumber` ทุกตัวใน Swift** — `0.8469` ถูกแปลงเป็น `true` เงียบๆ ตอน decode JSON ทำให้ score/distance กลายเป็น boolean โดยไม่มี error ใดๆ → **ต้องตรวจ `NSNumber` ก่อนเสมอ และตัดสินความเป็น boolean ด้วย `CFGetTypeID(n) == CFBooleanGetTypeID()`** ไม่ใช่ด้วยการ cast (ดูโค้ดจริงใน [`spikes/SurrealClient/SurrealClient.swift`](../spikes/SurrealClient/SurrealClient.swift))
- **Swift 6 strict concurrency ไม่ยอมให้ `Any` ข้าม actor boundary** — บังคับให้ wire type เป็น enum `Sendable` (`SurrealValue`) ตั้งแต่ต้น ซึ่งเป็น design ที่ดีกว่าอยู่แล้ว (typed access ไม่ต้อง cast)
- **closure ที่ส่งเข้า helper แบบ async ต้องประกาศ `sending`** ไม่งั้นชน `#SendableClosureCaptures`

## C.1 SurrealDB v3 quirks (เจอจริงตอน implement v1 — เป็น SurrealQL-level ไม่ใช่ Rust-specific)

- HNSW query ต้องใช้ operator `<|k,ef|>` (เช่น `<|5,40|>`) ไม่ใช่ `<|k|>` เฉยๆ (แบบเก่าถูกถอดออกแล้ว)
- **`RELATE type::record(...)->edge->type::record(...)` parse ไม่ผ่าน** — grammar ต้องการ graph-expression operand ตรงตำแหน่งนั้น ต้อง bind แต่ละฝั่งเข้า `LET` param ก่อน แล้ว `RELATE $src->edge->$tgt`
- **full-text index clause คือ `FULLTEXT ANALYZER <name> BM25(k1,b) HIGHLIGHTS`** ไม่ใช่ `SEARCH ANALYZER ...` แบบที่ docs เก่ากว่าเขียน
- **`ORDER BY search::score(1)` parse ไม่ผ่าน** — `ORDER BY` รับแค่ plain field ต้อง project ก่อน: `SELECT *, search::score(1) AS relevance ... ORDER BY relevance DESC`
- ระวังการ bind ค่าที่มี array ตัวเลข (เช่น `embedding: [Float]`) — ใน Rust ต้องห่อ `SerdeWrapper` ไม่งั้น insert ผ่านแต่อ่านกลับไม่ได้ **ฝั่ง Swift ต้องเทสจุดนี้ซ้ำตั้งแต่ chunk แรก** อย่า assume ว่า SDK จัดการให้

## C.2 บทเรียนเชิงกระบวนการจาก v1

- **"ทดสอบกับของจริงก่อนอ้างว่าใช้ได้"** — v1 ตรวจ CDN จริงก่อนสรุปว่า DuckDB extension "mongo" ใช้ไม่ได้ (build ถึงแค่ core v1.5.4 แต่ project pin v1.5.5) แทนที่จะเชื่อ docs → นโยบายนี้เก็บไว้
- **integration test กับ instance จริง ไม่ mock** — v1 เทส KB store/MCP/notebook kernel กับของจริงทั้งหมด เจอ behavior ที่ docs ไม่ได้เขียนหลายจุด
- **เอกสารต้อง sync กับโค้ดทันทีหลัง merge** — v1 มี stale comment/doc หลายจุดที่บอกว่า feature ยังไม่ทำทั้งที่ทำแล้ว

