import Foundation
import NaturalLanguage

// ─────────────────────────────────────────────────────────────
// P2.1 — embedding selection. Measures retrieval quality on the kind of
// text this workspace actually indexes: Thai + English research prose with
// medical/statistical vocabulary and transliterated loanwords.
//
// Candidates:
//   A. NLEmbedding.sentenceEmbedding  (native, static, per-language)
//   B. NLContextualEmbedding          (native, transformer, multilingual)
//   C. nomic-embed-text-v1.5          (via LM Studio, OpenAI-compatible)
//
// Metrics: recall@1, recall@3, MRR over a hand-built relevance set.
// ─────────────────────────────────────────────────────────────

struct Doc: Sendable {
    let id: Int
    let lang: String
    let text: String
}

struct Query: Sendable {
    let text: String
    let lang: String
    /// Doc ids that genuinely answer this query.
    let relevant: Set<Int>
}

let docs: [Doc] = [
    .init(id: 1, lang: "th", text: "ผู้ป่วยเบาหวานชนิดที่ 2 ที่มีภาวะไตเรื้อรังควรได้รับการตรวจติดตามการทำงานของไตอย่างสม่ำเสมอ"),
    .init(id: 2, lang: "th", text: "ประสิทธิผลของวัคซีน mRNA ในประชากรผู้สูงอายุจากการศึกษาแบบ cohort ย้อนหลัง"),
    .init(id: 3, lang: "th", text: "การวิเคราะห์ข้อมูลด้วยแบบจำลองการถดถอยโลจิสติกเพื่อหาปัจจัยเสี่ยง"),
    .init(id: 4, lang: "th", text: "กรมควบคุมโรค กระทรวงสาธารณสุข รายงานสถานการณ์ผู้ติดเชื้อรายใหม่ประจำสัปดาห์"),
    .init(id: 5, lang: "th", text: "การทำ survival analysis ด้วยแบบจำลอง Cox proportional hazards ในผู้ป่วยมะเร็งปอด"),
    .init(id: 6, lang: "th", text: "แนวทางเวชปฏิบัติสำหรับการใช้ยา metformin ในผู้ป่วยเบาหวานที่มีการทำงานของไตลดลง"),
    .init(id: 7, lang: "th", text: "การจัดการข้อมูลสูญหายด้วยวิธี multiple imputation ก่อนการวิเคราะห์ทางสถิติ"),
    .init(id: 8, lang: "th", text: "ความชุกของภาวะซึมเศร้าในกลุ่มวัยรุ่นไทยจากการสำรวจระดับประเทศ"),
    .init(id: 9, lang: "en", text: "Type 2 diabetes patients with chronic kidney disease require regular renal function monitoring"),
    .init(id: 10, lang: "en", text: "Effectiveness of mRNA vaccines in elderly populations from a retrospective cohort study"),
    .init(id: 11, lang: "en", text: "Logistic regression modelling to identify risk factors in observational data"),
    .init(id: 12, lang: "en", text: "Survival analysis using Cox proportional hazards models in lung cancer patients"),
    .init(id: 13, lang: "en", text: "Handling missing data with multiple imputation before statistical analysis"),
    .init(id: 14, lang: "en", text: "Prevalence of depression among Thai adolescents from a national survey"),
    .init(id: 15, lang: "en", text: "Clinical practice guideline for metformin dosing in reduced kidney function"),
    .init(id: 16, lang: "en", text: "Weekly communicable disease situation report from the department of disease control"),
    // Distractors from a different domain — retrieval must not drift to these.
    .init(id: 17, lang: "th", text: "การตั้งค่า Swift Package Manager สำหรับโปรเจกต์ macOS ที่มีหลาย target"),
    .init(id: 18, lang: "en", text: "Configuring Swift Package Manager targets for a multi-module macOS project"),
    .init(id: 19, lang: "th", text: "การเชื่อมต่อฐานข้อมูล PostgreSQL ผ่าน connection pool ในระบบ backend"),
    .init(id: 20, lang: "en", text: "Connecting to PostgreSQL through a connection pool in a backend service"),
]

let queries: [Query] = [
    .init(text: "เบาหวานกับโรคไตเรื้อรัง ต้องติดตามอะไรบ้าง", lang: "th", relevant: [1, 6, 9, 15]),
    .init(text: "วัคซีน mRNA ได้ผลแค่ไหนในผู้สูงอายุ", lang: "th", relevant: [2, 10]),
    .init(text: "การถดถอยโลจิสติกใช้หาปัจจัยเสี่ยงอย่างไร", lang: "th", relevant: [3, 11]),
    .init(text: "วิเคราะห์การรอดชีพผู้ป่วยมะเร็ง", lang: "th", relevant: [5, 12]),
    .init(text: "ข้อมูลหายต้องทำอย่างไรก่อนวิเคราะห์", lang: "th", relevant: [7, 13]),
    .init(text: "ภาวะซึมเศร้าในวัยรุ่น", lang: "th", relevant: [8, 14]),
    .init(text: "chronic kidney disease monitoring in diabetes", lang: "en", relevant: [9, 1, 15, 6]),
    .init(text: "mRNA vaccine effectiveness older adults", lang: "en", relevant: [10, 2]),
    .init(text: "cox proportional hazards lung cancer", lang: "en", relevant: [12, 5]),
    .init(text: "multiple imputation missing values", lang: "en", relevant: [13, 7]),
    .init(text: "metformin dosing kidney", lang: "en", relevant: [15, 6]),
    .init(text: "swift package manager multi module setup", lang: "en", relevant: [18, 17]),
]

// MARK: - providers

protocol EmbeddingProvider: Sendable {
    var name: String { get }
    var dimension: Int { get async }
    func embed(_ text: String, language: String) async -> [Double]?
}

/// A — Apple's static per-language sentence embedding.
/// NOTE: loading this model per call stalls hard; it must be cached.
actor NLSentenceProvider: EmbeddingProvider {
    nonisolated let name = "NLEmbedding.sentence"
    private var cache: [String: NLEmbedding] = [:]

    private func model(_ language: String) -> NLEmbedding? {
        if let hit = cache[language] { return hit }
        let lang: NLLanguage = language == "th" ? .thai : .english
        guard let e = NLEmbedding.sentenceEmbedding(for: lang) else { return nil }
        cache[language] = e
        return e
    }

    var dimension: Int { model("en")?.dimension ?? 0 }

    func embed(_ text: String, language: String) async -> [Double]? {
        guard let e = model(language) else { return nil }   // Thai returns nil: no such model
        return e.vector(for: text)
    }
}

/// B — Apple's multilingual transformer embedding (macOS 14+).
actor NLContextualProvider: EmbeddingProvider {
    nonisolated let name = "NLContextualEmbedding"
    private var loaded: NLContextualEmbedding?

    var dimension: Int {
        get async { model()?.dimension ?? 0 }
    }

    private var assetsRequested = false

    private func model() -> NLContextualEmbedding? {
        if let loaded { return loaded }
        let candidate = NLContextualEmbedding(language: .thai) ?? NLContextualEmbedding(language: .english)
        guard let e = candidate else { return nil }
        guard e.hasAvailableAssets else { return nil }
        guard (try? e.load()) != nil else { return nil }
        loaded = e
        return e
    }

    /// Assets ship on demand; ask once and wait a bounded time for them.
    func prepareAssets(timeout: Duration) async -> Bool {
        if model() != nil { return true }
        guard !assetsRequested,
              let e = NLContextualEmbedding(language: .thai) ?? NLContextualEmbedding(language: .english)
        else { return model() != nil }
        assetsRequested = true
        e.requestAssets { _, _ in }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if e.hasAvailableAssets { return model() != nil }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    func embed(_ text: String, language: String) async -> [Double]? {
        guard let e = model() else { return nil }
        let lang: NLLanguage = language == "th" ? .thai : .english
        guard let result = try? e.embeddingResult(for: text, language: lang) else { return nil }
        // Mean-pool the token vectors into one sentence vector.
        var sum = [Double](repeating: 0, count: e.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for (i, v) in vector.enumerated() where i < sum.count { sum[i] += v }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return sum.map { $0 / Double(count) }
    }
}

/// C — any embedding model served by an OpenAI-compatible endpoint.
struct ServedProvider: EmbeddingProvider {
    let name: String
    let model: String
    /// Some models (e5 family) expect an instruction prefix on both sides.
    var queryPrefix: String = ""
    var docPrefix: String = ""
    let endpoint = URL(string: "http://127.0.0.1:1234/v1/embeddings")!
    var dimension: Int { get async { await embed("probe", language: "en")?.count ?? 0 } }

    func embed(_ text: String, language: String) async -> [Double]? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": text,
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]],
              let vec = arr.first?["embedding"] as? [Double] else { return nil }
        return vec
    }
}

// MARK: - metrics

func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    guard na > 0, nb > 0 else { return -1 }
    return dot / (na.squareRoot() * nb.squareRoot())
}

struct Result: Sendable {
    let name: String
    let dimension: Int
    let recall1: Double
    let recall3: Double
    let mrr: Double
    let crossLingual: Double   // fraction of queries whose top-3 includes the other language's match
    let elapsedMs: Int
    let failures: Int
}

func evaluate(_ provider: any EmbeddingProvider) async -> Result {
    let clock = ContinuousClock()
    let t0 = clock.now
    var failures = 0

    var docVectors: [Int: [Double]] = [:]
    for doc in docs {
        if let v = await provider.embed(doc.text, language: doc.lang) {
            docVectors[doc.id] = v
        } else { failures += 1 }
    }

    var hits1 = 0, hits3 = 0, rr = 0.0, cross = 0
    for query in queries {
        guard let qv = await provider.embed(query.text, language: query.lang) else {
            failures += 1
            continue
        }
        let ranked = docVectors
            .map { (id: $0.key, score: cosine(qv, $0.value)) }
            .sorted { $0.score > $1.score }

        if let first = ranked.first, query.relevant.contains(first.id) { hits1 += 1 }
        let top3 = ranked.prefix(3).map(\.id)
        if top3.contains(where: query.relevant.contains) { hits3 += 1 }
        if let rank = ranked.firstIndex(where: { query.relevant.contains($0.id) }) {
            rr += 1.0 / Double(rank + 1)
        }
        // Cross-lingual: does a Thai query surface the English twin (or vice versa)?
        let otherLang = query.lang == "th" ? "en" : "th"
        let otherIDs = Set(docs.filter { $0.lang == otherLang }.map(\.id))
        if top3.contains(where: { query.relevant.contains($0) && otherIDs.contains($0) }) { cross += 1 }
    }

    let n = Double(queries.count)
    let elapsed = clock.now - t0
    let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    return Result(name: provider.name,
                  dimension: await provider.dimension,
                  recall1: Double(hits1) / n,
                  recall3: Double(hits3) / n,
                  mrr: rr / n,
                  crossLingual: Double(cross) / n,
                  elapsedMs: ms,
                  failures: failures)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

func pct(_ v: Double) -> String { String(format: "%5.1f%%", v * 100) }

@main
struct EvalMain {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
    print("=== P2.1 — EMBEDDING SELECTION ===")
    print("\(docs.count) docs (ไทย \(docs.filter { $0.lang == "th" }.count) / อังกฤษ \(docs.filter { $0.lang == "en" }.count)), \(queries.count) queries")
    print(String(repeating: "-", count: 92))
    print(pad("provider", 26) + pad("dim", 6) + pad("recall@1", 10) + pad("recall@3", 10)
          + pad("MRR", 9) + pad("cross-ling", 12) + pad("time", 9) + "fails")
    print(String(repeating: "-", count: 92))

    let providers: [any EmbeddingProvider] = [
        NLSentenceProvider(),
        NLContextualProvider(),
        ServedProvider(name: "nomic-embed-text-v1.5", model: "text-embedding-nomic-embed-text-v1.5"),
        ServedProvider(name: "bge-m3 (multilingual)", model: "text-embedding-bge-m3"),
    ]

    for p in providers {
        print("  → \(p.name) …")
        if let ctx = p as? NLContextualProvider {
            let ready = await ctx.prepareAssets(timeout: .seconds(90))
            print("     assets: \(ready ? "พร้อม" : "ยังโหลดไม่เสร็จ — ข้าม")")
        }
        let r = await evaluate(p)
        print(pad(r.name, 26) + pad("\(r.dimension)", 6) + pad(pct(r.recall1), 10)
              + pad(pct(r.recall3), 10) + pad(String(format: "%.3f", r.mrr), 9)
              + pad(pct(r.crossLingual), 12) + pad("\(r.elapsedMs)ms", 9) + "\(r.failures)")
        fflush(stdout)
    }

    print(String(repeating: "-", count: 92))
    print("done")
    fflush(stdout)
    }
}
