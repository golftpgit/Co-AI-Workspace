import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import Hub
import Tokenizers

// ─────────────────────────────────────────────────────────────
// Spike (2026-08-11): run bge-m3 in our own process.
//
// The question this answers: does the knowledge base have to depend on
// LM Studio, or can the app own its embedding model the way it already owns
// the SurrealDB sidecar? ARCHITECTURE line 1256 says it must be ours; nobody
// had checked whether that is possible in Swift today.
//
// Checks, in order of what would kill the idea:
//   1. does bge-m3 load and run at all through MLXEmbedders
//   2. does it read Thai — a model that returns one vector per script is
//      useless to us (E.11)
//   3. is it 1024 dimensions, the number P2.1 locked
//   4. does it agree with the GGUF build LM Studio serves
//   5. is it fast enough to embed a document without being painful
// ─────────────────────────────────────────────────────────────

let thai = [
    "การให้อินซูลินในผู้ป่วยเบาหวาน",
    "การควบคุมระดับน้ำตาลในเลือดของผู้ป่วยเบาหวาน",
    "การปนเปื้อนโลหะหนักในแหล่งน้ำดิบ",
]

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count else { return .nan }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in a.indices {
        dot += Double(a[i]) * Double(b[i])
        na += Double(a[i]) * Double(a[i])
        nb += Double(b[i]) * Double(b[i])
    }
    return dot / (na.squareRoot() * nb.squareRoot())
}

/// The two protocols mlx-swift-lm leaves to the host, backed by
/// swift-transformers. This is the whole adapter layer — if the spike works,
/// this is roughly what ships.
struct HubDownloader: Downloader {
    let hub = HubApi()

    func download(id: String, revision: String?, matching patterns: [String],
                  useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        try await hub.snapshot(from: id, revision: revision ?? "main",
                               matching: patterns, progressHandler: progressHandler)
    }
}

/// mlx-swift-lm declares its own minimal `Tokenizer` protocol so it does not
/// depend on swift-transformers. Bridging the two is a dozen lines, and it is
/// the seam that keeps the tokenizer choice ours.
struct BridgedTokenizer: MLXLMCommon.Tokenizer {
    let inner: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        inner.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        inner.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { inner.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { inner.convertIdToToken(id) }

    var bosToken: String? { inner.bosToken }
    var eosToken: String? { inner.eosToken }
    var unknownToken: String? { inner.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]],
                           tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        // Embedding models have no chat template, and nothing in this path
        // asks for one — failing loudly beats returning something plausible.
        throw NSError(domain: "spike", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "an embedding model has no chat template"])
    }
}

struct HubTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        BridgedTokenizer(inner: try await AutoTokenizer.from(modelFolder: directory))
    }
}

func step(_ name: String, _ body: () async throws -> String) async {
    let start = Date()
    do {
        let detail = try await body()
        print(String(format: "  ok   %@ (%.2fs) %@", name, -start.timeIntervalSinceNow, detail))
    } catch {
        print(String(format: "  FAIL %@ (%.2fs) %@", name, -start.timeIntervalSinceNow,
                     "\(error)"))
    }
}

print("== bge-m3 in-process spike ==")

var vectors: [[Float]] = []

await step("load bge-m3 through MLXEmbedders") {
    let container = try await EmbedderModelFactory.shared.loadContainer(
        from: HubDownloader(), using: HubTokenizerLoader(),
        configuration: EmbedderRegistry.bge_m3)

    let start = Date()
    vectors = await container.perform { context in
        let tokenizer = context.tokenizer
        let inputs = thai.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
        let maxLength = inputs.reduce(into: 16) { $0 = max($0, $1.count) }
        let padded = stacked(inputs.map { row in
            MLXArray(row + Array(repeating: tokenizer.eosTokenId ?? 0,
                                 count: maxLength - row.count))
        })
        let mask = (padded .!= (tokenizer.eosTokenId ?? 0))
        let types = MLXArray.zeros(like: padded)
        let result = context.pooling(
            context.model(padded, positionIds: nil, tokenTypeIds: types, attentionMask: mask),
            normalize: true, applyLayerNorm: true)
        result.eval()
        return result.map { $0.asArray(Float.self) }
    }
    return String(format: "%d vectors, %d dims, embed took %.2fs",
                  vectors.count, vectors.first?.count ?? 0, -start.timeIntervalSinceNow)
}

await step("dimensions are the 1024 P2.1 locked") {
    guard vectors.first?.count == 1_024 else {
        throw NSError(domain: "spike", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "got \(vectors.first?.count ?? 0)"])
    }
    return ""
}

await step("it can read Thai") {
    guard vectors.count == 3 else { throw NSError(domain: "spike", code: 2) }
    let related = cosine(vectors[0], vectors[1])
    let unrelated = cosine(vectors[0], vectors[2])
    guard vectors[0] != vectors[1] else {
        throw NSError(domain: "spike", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "identical vectors — blind to Thai, like nomic (E.11)"])
    }
    guard related > unrelated else {
        throw NSError(domain: "spike", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "related \(related) <= unrelated \(unrelated)"])
    }
    return String(format: "related %.3f vs unrelated %.3f", related, unrelated)
}

await step("agrees with the GGUF build LM Studio serves") {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/embeddings")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": "text-embedding-bge-m3", "input": thai,
    ])
    let (data, _) = try await URLSession.shared.data(for: request)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = object["data"] as? [[String: Any]] else {
        throw NSError(domain: "spike", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "no endpoint on :1234 — comparison skipped"])
    }
    let remote = rows
        .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        .compactMap { ($0["embedding"] as? [Double])?.map(Float.init) }
    let agreement = zip(vectors, remote).map { cosine($0, $1) }
    return "cosine per sentence: " + agreement.map { String(format: "%.4f", $0) }
        .joined(separator: ", ")
}

await step("throughput on a document-sized batch") {
    let container = try await EmbedderModelFactory.shared.loadContainer(
        from: HubDownloader(), using: HubTokenizerLoader(),
        configuration: EmbedderRegistry.bge_m3)
    let batch = Array(repeating: thai[0], count: 32)
    let start = Date()
    _ = await container.perform { context in
        let tokenizer = context.tokenizer
        let inputs = batch.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
        let maxLength = inputs.reduce(into: 16) { $0 = max($0, $1.count) }
        let padded = stacked(inputs.map { row in
            MLXArray(row + Array(repeating: tokenizer.eosTokenId ?? 0,
                                 count: maxLength - row.count))
        })
        let mask = (padded .!= (tokenizer.eosTokenId ?? 0))
        let result = context.pooling(
            context.model(padded, positionIds: nil,
                          tokenTypeIds: MLXArray.zeros(like: padded), attentionMask: mask),
            normalize: true, applyLayerNorm: true)
        result.eval()
        return result.map { $0.asArray(Float.self) }
    }
    let elapsed = -start.timeIntervalSinceNow
    return String(format: "32 chunks in %.2fs (%.0f chunks/s)", elapsed, 32 / elapsed)
}
