import Testing
import Foundation
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// "วัด BM25 recall เทียบก่อน/หลัง merge layer" — P2.2's second Done-when.
//
// The measurement came out against the assumption behind the task. Recall is
// identical with and without the merge layer, exactly as ARCHITECTURE E.3
// predicted: index and query pass through the same segmenter, so a query for
// `โลจิสติก` shatters into the same fragments the document did and still finds
// it. What the layer actually buys is precision — see the second test, where a
// search for สติ (mindfulness) pulls up a logistic-regression paper without it.
//
// These tests keep both numbers so the claim stays measured rather than
// remembered.
// ─────────────────────────────────────────────────────────────

private let corpus: [(id: String, text: String)] = [
    ("logistic", "งานวิจัยนี้ใช้แบบจำลองการถดถอยโลจิสติกเพื่อทำนายความเสี่ยงของผู้ป่วย"),
    ("mindfulness", "การฝึกสติช่วยลดความเครียดในผู้ดูแลผู้ป่วยเรื้อรัง"),
    ("metal", "การปนเปื้อนโลหะหนักในแหล่งน้ำดิบส่งผลต่อสุขภาพประชาชน"),
    ("blood", "ระดับโลหิตจางในหญิงตั้งครรภ์สัมพันธ์กับภาวะทุพโภชนาการ"),
    ("covid", "การระบาดของโควิดในประเทศไทยทำให้ระบบสาธารณสุขรับภาระหนัก"),
    ("video", "สื่อวิดีทัศน์ให้ความรู้เรื่องการล้างมือแก่นักเรียนประถม"),
    ("vaccine", "วัคซีนชนิด mRNA กระตุ้นภูมิคุ้มกันได้ดีในผู้สูงอายุ"),
    ("diabetes", "ผู้ป่วยเบาหวานชนิดที่ 2 ที่มีภาวะไตเรื้อรังต้องปรับขนาดยา"),
    ("insulin", "การให้อินซูลินแบบพื้นฐานร่วมกับยากินช่วยคุมน้ำตาลได้ดีขึ้น"),
    ("stats", "ค่าพารามิเตอร์ของโมเดลถูกประมาณด้วยวิธีความควรจะเป็นสูงสุด"),
]

private let queries: [(query: String, relevant: String)] = [
    ("โลจิสติก", "logistic"),
    ("โควิด", "covid"),
    ("วัคซีน", "vaccine"),
    ("อินซูลิน", "insulin"),
    ("พารามิเตอร์", "stats"),
]

private struct Measurement {
    let recallAt1: Double
    let mrr: Double
    var summary: String { String(format: "recall@1 %.2f · MRR %.2f", recallAt1, mrr) }
}

private func index(merging: Bool) -> BM25Index {
    var index = BM25Index(tokenizer: Tokenizer(mergesDictionaryTerms: merging))
    for document in corpus { index.index(id: document.id, text: document.text) }
    return index
}

private func measure(merging: Bool) -> Measurement {
    let index = index(merging: merging)
    var hits = 0
    var reciprocalRanks = 0.0
    for (query, relevant) in queries {
        let results = index.search(query, limit: 10)
        if results.first?.id == relevant { hits += 1 }
        if let rank = results.firstIndex(where: { $0.id == relevant }) {
            reciprocalRanks += 1.0 / Double(rank + 1)
        }
    }
    return Measurement(recallAt1: Double(hits) / Double(queries.count),
                       mrr: reciprocalRanks / Double(queries.count))
}

@Suite("What the merge layer is worth")
struct RetrievalMeasurementTests {
    @Test("recall is not what the merge layer fixes")
    func recallIsUnchanged() {
        let without = measure(merging: false)
        let with = measure(merging: true)

        // Both are 1.00 on this corpus. The assertion is deliberately equality:
        // if a future change makes shattered retrieval *worse*, the layer's
        // justification changes with it and this should be re-read, not
        // silently satisfied by an inequality.
        #expect(with.recallAt1 == without.recallAt1,
                "with [\(with.summary)] vs without [\(without.summary)]")
        #expect(with.mrr == without.mrr,
                "with [\(with.summary)] vs without [\(without.summary)]")
        #expect(with.recallAt1 == 1.0, "with the layer: \(with.summary)")
    }

    @Test("what it fixes is matching the wrong document entirely")
    func fragmentsCauseFalsePositives() {
        // "โลจิสติก" shatters into โล|จิ|สติ|ก, and สติ is a Thai word meaning
        // mindfulness. Someone searching for it gets a statistics paper.
        let shattered = index(merging: false).search("สติ", limit: 10).map(\.id)
        #expect(shattered.contains("logistic"),
                "if this passes, the fragments no longer collide and E.3 needs revisiting")

        let merged = index(merging: true).search("สติ", limit: 10).map(\.id)
        #expect(!merged.contains("logistic"), "still matching on a fragment: \(merged)")
        #expect(merged.contains("mindfulness"), "lost the document that is actually about สติ")
    }

    @Test("the layer does not invent matches of its own")
    func noNewFalsePositives() {
        // Every result the merged index returns for each query must also be a
        // result the plain index found: the layer is allowed to remove noise,
        // never to add reach it cannot justify.
        for (query, _) in queries {
            let plain = Set(index(merging: false).search(query, limit: 10).map(\.id))
            let merged = Set(index(merging: true).search(query, limit: 10).map(\.id))
            #expect(merged.isSubset(of: plain), "\(query): \(merged) ⊄ \(plain)")
        }
    }
}
