import Foundation
import Knowledge
import EmbeddingRuntime

// ─────────────────────────────────────────────────────────────
// Why there is no embedding filter in front of the conflict detector
// (§11.7, P18.2 · E.25).
//
// P18.2 planned one: `bge-m3` embeds Thai and English in one space (E.10), so a
// cross-language pair sitting very close was to be treated as a translation and
// never shown to the model. This measures whether that separation exists on the
// real weights. It does not — and this check exists so the finding keeps being
// true rather than being remembered.
//
// **It is not a check that something is broken.** It prints both distributions
// and passes while they overlap, which is today's state and the reason the
// filter is absent. If a future embedder does separate them, it turns red and
// says so: that is the day P18.2 can be reconsidered, and a check that stayed
// quiet through it would leave the plan's decision resting on a number nobody
// re-took.
// ─────────────────────────────────────────────────────────────

struct TranslationCalibration {
    let embedder: MLXEmbedder

    /// Pairs that mean the same thing in two languages — the cards that started
    /// §11.7. A filter would have to score these *above* the group below.
    private static let translations: [(String, String)] = [
        ("การนอนหลับที่เพียงพอช่วยลดความเสี่ยงของโรคหัวใจในผู้ใหญ่",
         "Adequate sleep reduces the risk of heart disease in adults"),
        ("การออกกำลังกายสม่ำเสมอช่วยควบคุมระดับน้ำตาลในเลือดของผู้ป่วยเบาหวานชนิดที่ 2",
         "Regular exercise helps control blood glucose in patients with type 2 diabetes"),
        ("ผู้สูงอายุควรได้รับวัคซีนไข้หวัดใหญ่ทุกปีเพื่อลดการเข้ารักษาในโรงพยาบาล",
         "Older adults should receive an annual influenza vaccine to reduce hospital admissions"),
        ("การสูบบุหรี่เพิ่มความเสี่ยงของมะเร็งปอดอย่างมีนัยสำคัญ",
         "Smoking significantly increases the risk of lung cancer"),
    ]

    /// Pairs in two languages that genuinely disagree — same question,
    /// incompatible answers. Each one is a card somebody needs to see, so a
    /// filter must score these *below* the group above.
    private static let disagreements: [(String, String)] = [
        ("ผู้ใหญ่ควรนอนอย่างน้อยวันละ 7 ชั่วโมงเพื่อสุขภาพหัวใจที่ดี",
         "Adults need no more than four hours of sleep for good heart health"),
        ("ผู้ป่วยเบาหวานชนิดที่ 2 ควรเริ่มยา metformin เป็นยาตัวแรกเสมอ",
         "Metformin should never be used as first-line therapy in type 2 diabetes"),
        ("วัคซีนไข้หวัดใหญ่ลดอัตราการเข้ารักษาในโรงพยาบาลของผู้สูงอายุ",
         "Influenza vaccination has no effect on hospital admissions in older adults"),
        ("การสูบบุหรี่เพิ่มความเสี่ยงของมะเร็งปอด",
         "Smoking has no measurable association with lung cancer risk"),
    ]

    func run(check: (String, () async throws -> String) async -> Void) async {
        await check("ระยะ embedding แยก 'คำแปล' ออกจาก 'ขัดแย้งจริง' ไม่ได้ (ยังจริงอยู่)") {
            var translated: [Double] = []
            var disagreeing: [Double] = []
            for (thai, english) in Self.translations {
                translated.append(try await similarity(thai, english))
            }
            for (thai, english) in Self.disagreements {
                disagreeing.append(try await similarity(thai, english))
            }

            let lowestTranslation = translated.min() ?? 0
            let highestDisagreement = disagreeing.max() ?? 1
            print("     คำแปล: " + translated.sorted()
                    .map { String(format: "%.3f", $0) }.joined(separator: ", "))
            print("     ขัดแย้งจริง: " + disagreeing.sorted()
                    .map { String(format: "%.3f", $0) }.joined(separator: ", "))

            guard lowestTranslation <= highestDisagreement else {
                // The good kind of failure: the assumption behind the missing
                // feature has changed, and the plan should be re-read.
                throw CheckFailure(String(
                    format: "สองกลุ่มแยกกันแล้ว (คำแปลต่ำสุด %.3f > ขัดแย้งสูงสุด %.3f) — "
                        + "กลับไปอ่าน P18.2 ใหม่ ด่านกรองด้วย embedding อาจทำได้แล้ว",
                    lowestTranslation, highestDisagreement))
            }
            return String(format: "ทับกันที่ %.3f–%.3f — ไม่มีเกณฑ์ไหนที่ปลอดภัย จึงไม่มีด่านกรอง",
                          lowestTranslation, highestDisagreement)
        }
    }

    private func similarity(_ a: String, _ b: String) async throws -> Double {
        let vectors = try await embedder.embed([a, b])
        guard vectors.count == 2 else { throw CheckFailure("embedder คืนเวกเตอร์ไม่ครบ") }
        return TextScriptReader.cosine(vectors[0], vectors[1])
    }
}
