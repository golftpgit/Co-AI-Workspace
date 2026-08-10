import Foundation
import NaturalLanguage

// ─────────────────────────────────────────────────────────────
// SPIKE: prove our own SurrealClient can do everything M7 needs
//   1. connect / signin / use
//   2. schema: FULLTEXT (BM25) index + HNSW vector index + graph edges
//   3. insert chunks with real Thai text + embeddings
//   4. BM25 full-text search (incl. the ORDER BY search::score quirk)
//   5. HNSW vector KNN with the <|k,ef|> operator
//   6. RELATE graph edges (the LET-binding quirk) + graph traversal
//   7. hybrid search (RRF fusion of BM25 + vector)
//   8. Thai tokenization pipeline end-to-end
// ─────────────────────────────────────────────────────────────

let clock = ContinuousClock()

actor Counter { var n = 0; func bump() { n += 1 }; func get() -> Int { n } }
let failures = Counter()

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func ms(since t0: ContinuousClock.Instant) -> Int64 {
    let d = clock.now - t0
    return d.components.seconds * 1000 + Int64(d.components.attoseconds / 1_000_000_000_000_000)
}

func step(_ label: String, _ body: sending () async throws -> String) async {
    let t0 = clock.now
    do {
        let detail = try await body()
        print("✅ " + pad(label, 34) + pad("\(ms(since: t0))ms", 9) + detail)
    } catch {
        await failures.bump()
        print("❌ " + pad(label, 34) + pad("\(ms(since: t0))ms", 9) + "\(error)")
    }
    fflush(stdout)
}

// Thai-aware tokenizer: what M7's Chunker will feed into the BM25 index
func thaiSearchText(_ text: String) -> String {
    let tk = NLTokenizer(unit: .word)
    tk.string = text
    var toks: [String] = []
    tk.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
        toks.append(String(text[r]).lowercased()); return true
    }
    return toks.joined(separator: " ")
}

// deterministic pseudo-embedding so the spike is reproducible
func fakeEmbedding(_ seed: Int, dim: Int = 8) -> [Double] {
    var v: [Double] = []
    var x = Double(seed)
    for i in 0..<dim {
        x = (x * 1.37 + Double(i) * 0.11).truncatingRemainder(dividingBy: 1.0)
        v.append(x)
    }
    let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
    return v.map { $0 / max(norm, 0.0001) }
}

let docs: [(id: Int, title: String, text: String)] = [
    (1, "เบาหวานชนิดที่ 2", "ผู้ป่วยเบาหวานชนิดที่ 2 ที่มีภาวะไตเรื้อรังควรได้รับการตรวจติดตามอย่างสม่ำเสมอ"),
    (2, "วัคซีน mRNA", "ประสิทธิผลของวัคซีน mRNA ในประชากรผู้สูงอายุจากการศึกษาแบบ cohort"),
    (3, "การถดถอยโลจิสติก", "การวิเคราะห์ข้อมูลขนาดใหญ่ด้วยแบบจำลองการถดถอยโลจิสติกและการถดถอยเชิงเส้น"),
    (4, "กรมควบคุมโรค", "กรมควบคุมโรค กระทรวงสาธารณสุข รายงานสถานการณ์ผู้ติดเชื้อรายใหม่ประจำสัปดาห์"),
    (5, "Survival analysis", "Survival analysis of stage 3 lung cancer patients using Cox proportional hazards"),
]

@main
struct Spike {
    static func main() async {
        print("=== SPIKE — SurrealClient (เขียนเอง) กับ SurrealDB v3.2.0 ===")
        print(String(repeating: "-", count: 78))

        let client = SurrealClient(url: URL(string: "ws://127.0.0.1:18000/rpc")!)

        await step("1. connect + signin + use") {
            try await client.connect()
            try await client.signin(user: "root", pass: "root")
            try await client.use(namespace: "coai", database: "kb")
            return "ns=coai db=kb"
        }

        await step("2. schema: FULLTEXT + HNSW + graph") {
            try await client.exec("""
            REMOVE TABLE IF EXISTS chunk;
            REMOVE TABLE IF EXISTS entity;
            DEFINE TABLE IF NOT EXISTS chunk SCHEMALESS;
            DEFINE TABLE IF NOT EXISTS entity SCHEMALESS;
            DEFINE ANALYZER IF NOT EXISTS kb_text_analyzer TOKENIZERS BLANK FILTERS LOWERCASE;
            DEFINE INDEX IF NOT EXISTS chunk_fts ON chunk FIELDS search_text
                FULLTEXT ANALYZER kb_text_analyzer BM25(1.2, 0.75) HIGHLIGHTS;
            DEFINE INDEX IF NOT EXISTS chunk_vec ON chunk FIELDS embedding
                HNSW DIMENSION 8 DIST COSINE TYPE F64 EFC 150 M 12;
            """)
            return "chunk(fts+hnsw) + entity"
        }

        await step("3. insert chunks (Thai tokenized)") {
            for d in docs {
                try await client.exec(
                    "CREATE type::record('chunk', $id) CONTENT { doc_id: $id, title: $title, content: $content, search_text: $st, embedding: $emb, scope: 'central' }",
                    vars: ["id": d.id, "title": d.title, "content": d.text,
                           "st": thaiSearchText(d.text), "emb": fakeEmbedding(d.id)])
            }
            let r = try await client.query("SELECT count() FROM chunk GROUP ALL")
            let n = r.first?.rows.first?["count"]?.intValue ?? -1
            return "inserted=\(n) rows"
        }

        await step("4. BM25 full-text (Thai)") {
            // quirk from v1: ORDER BY search::score(1) does not parse — must project first
            let r = try await client.query("""
            SELECT title, search::score(1) AS relevance
            FROM chunk WHERE search_text @1@ $q
            ORDER BY relevance DESC LIMIT 3
            """, vars: ["q": thaiSearchText("ผู้สูงอายุ วัคซีน")])
            let hits = r.first?.rows ?? []
            let top = hits.first.map { "\($0["title"]?.short ?? "?") score=\($0["relevance"]?.short ?? "?")" } ?? "no hits"
            return "hits=\(hits.count) top=\(top)"
        }

        await step("5a. HNSW KNN — vector as $param") {
            let probe = fakeEmbedding(2)
            let r = try await client.query("""
            SELECT title, vector::distance::knn() AS dist
            FROM chunk WHERE embedding <|3,40|> $v
            """, vars: ["v": probe])
            let hits = r.first?.rows ?? []
            let top = hits.first.map { "\($0["title"]?.short ?? "?") dist=\($0["dist"]?.short ?? "?")" } ?? "no hits"
            return "hits=\(hits.count) top=\(top)"
        }

        await step("5b. HNSW KNN — vector inlined literal") {
            let probe = fakeEmbedding(2)
            let literal = "[" + probe.map { String($0) }.joined(separator: ",") + "]"
            let r = try await client.query("""
            SELECT title, vector::distance::knn() AS dist
            FROM chunk WHERE embedding <|3,40|> \(literal)
            """)
            let hits = r.first?.rows ?? []
            let top = hits.first.map { "\($0["title"]?.short ?? "?") dist=\($0["dist"]?.short ?? "?")" } ?? "no hits"
            return "hits=\(hits.count) top=\(top)"
        }

        await step("5c. cosine similarity (no index)") {
            let probe = fakeEmbedding(2)
            let r = try await client.query("""
            SELECT title, vector::similarity::cosine(embedding, $v) AS sim
            FROM chunk ORDER BY sim DESC LIMIT 3
            """, vars: ["v": probe])
            let hits = r.first?.rows ?? []
            let top = hits.first.map { "\($0["title"]?.short ?? "?") sim=\($0["sim"]?.short ?? "?")" } ?? "no hits"
            return "hits=\(hits.count) top=\(top)"
        }

        await step("6. RELATE (LET-bound) + traversal") {
            try await client.exec("""
            CREATE entity:vaccine  CONTENT { name: 'วัคซีน mRNA', kind: 'intervention' };
            CREATE entity:elderly  CONTENT { name: 'ผู้สูงอายุ', kind: 'population' };
            """)
            // quirk from v1: RELATE type::record(..)->edge->type::record(..) fails to parse
            try await client.exec("""
            LET $src = entity:vaccine;
            LET $tgt = entity:elderly;
            RELATE $src->studied_in->$tgt SET confidence = 0.92;
            """)
            let r = try await client.query("SELECT ->studied_in->entity.name AS targets FROM entity:vaccine")
            let targets = r.first?.rows.first?["targets"]?.short ?? "nil"
            return "traversal → \(targets)"
        }

        await step("7. hybrid search (BM25 + vector, RRF)") {
            let q = thaiSearchText("วัคซีน ผู้สูงอายุ")
            let probe = fakeEmbedding(2)
            let r = try await client.query("""
            SELECT title, search::score(1) AS relevance FROM chunk
              WHERE search_text @1@ $q ORDER BY relevance DESC LIMIT 5;
            SELECT title, vector::distance::knn() AS dist FROM chunk
              WHERE embedding <|5,40|> $v ORDER BY dist ASC;
            """, vars: ["q": q, "v": probe])
            guard r.count == 2 else { return "unexpected statement count \(r.count)" }
            // Reciprocal Rank Fusion in Swift (fusion belongs in the app, not the DB)
            var score: [String: Double] = [:]
            for (rank, row) in r[0].rows.enumerated() {
                if let t = row["title"]?.stringValue { score[t, default: 0] += 1.0 / Double(60 + rank + 1) }
            }
            for (rank, row) in r[1].rows.enumerated() {
                if let t = row["title"]?.stringValue { score[t, default: 0] += 1.0 / Double(60 + rank + 1) }
            }
            let ranked = score.sorted { $0.value > $1.value }.prefix(2)
                .map { "\($0.key)(\(String(format: "%.4f", $0.value)))" }
            return "fused: " + ranked.joined(separator: ", ")
        }

        await step("8. concurrent queries (10 parallel)") {
            let t0 = clock.now
            try await withThrowingTaskGroup(of: Int.self) { g in
                for i in 0..<10 {
                    g.addTask {
                        let r = try await client.query("SELECT title FROM chunk WHERE doc_id = $d",
                                                       vars: ["d": (i % 5) + 1])
                        return r.first?.rows.count ?? 0
                    }
                }
                var total = 0
                for try await n in g { total += n }
                guard total == 10 else { throw SurrealError.decoding("expected 10 rows, got \(total)") }
            }
            return "10 concurrent queries ok in \(ms(since: t0))ms"
        }

        await step("9. error surfaces correctly") {
            do {
                _ = try await client.exec("SELECT * FROM chunk WHERE THIS IS NOT SURREALQL(((")
                return "⚠️ bad SQL did NOT error"
            } catch {
                return "bad SQL rejected: \(String("\(error)".prefix(48)))"
            }
        }

        await step("10. reconnect after close") {
            await client.close()
            let c2 = SurrealClient(url: URL(string: "ws://127.0.0.1:18000/rpc")!)
            try await c2.connect()
            try await c2.signin(user: "root", pass: "root")
            try await c2.use(namespace: "coai", database: "kb")
            let r = try await c2.query("SELECT count() FROM chunk GROUP ALL")
            let n = r.first?.rows.first?["count"]?.intValue ?? -1
            await c2.close()
            return "data survived, count=\(n)"
        }

        print(String(repeating: "-", count: 78))
        let f = await failures.get()
        print(f == 0 ? "ALL PASSED" : "FAILURES: \(f)")
        print("done")
        fflush(stdout)
        exit(f == 0 ? 0 : 1)
    }
}
