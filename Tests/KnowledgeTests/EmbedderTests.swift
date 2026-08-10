import Testing
import Foundation
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// The embedder against a real endpoint. Like the Tier 1 executor tests, the
// model is a property of the machine: P2.1 locked `bge-m3` at 1024 dimensions
// for the shipped system, but a machine serving any embedding model can still
// prove the client speaks the protocol and enforces its dimension.
// ─────────────────────────────────────────────────────────────

private let endpoint = URL(string: "http://127.0.0.1:1234/v1")!

private func servedEmbeddingModel() async -> String? {
    if let pinned = ProcessInfo.processInfo.environment["COAI_TEST_EMBEDDING_MODEL"],
       !pinned.isEmpty { return pinned }
    var request = URLRequest(url: endpoint.appending(path: "models"))
    request.timeoutInterval = 2
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = object["data"] as? [[String: Any]] else { return nil }
    return rows.compactMap { $0["id"] as? String }.first { $0.lowercased().contains("embed") }
}

private func testProfile(_ model: String, dimensions: Int) -> EmbeddingProfile {
    EmbeddingProfile(modelID: model, revision: "served", dimensions: dimensions)
}

/// Asking the endpoint rather than assuming: the same model is 768 dimensions
/// in one build and 1024 in another, and guessing wrong is exactly the failure
/// this client is supposed to catch.
private func dimensions(of model: String) async -> Int? {
    let probe = RemoteEmbedder(baseURL: endpoint, model: model,
                               profile: testProfile(model, dimensions: 1))
    do {
        _ = try await probe.embed("probe")
        return 1
    } catch EmbeddingError.dimensionMismatch(_, let got) {
        return got
    } catch {
        return nil
    }
}

/// Reproduces what LM Studio's nomic build actually does: one constant vector
/// for anything outside Latin script.
private struct ThaiBlindEmbedder: Embedder {
    let identifier = "thai-blind"
    let profile = EmbeddingProfile(modelID: "thai-blind", revision: "test", dimensions: 8)

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            let isThai = text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
            if isThai { return [Float](repeating: 0.5, count: 8) }
            var vector = [Float](repeating: 0, count: 8)
            vector[text.count % 8] = 1
            return vector
        }
    }
}

private struct HonestEmbedder: Embedder {
    let identifier = "honest"
    let profile = EmbeddingProfile(modelID: "honest", revision: "test", dimensions: 8)

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: 8)
            for (offset, scalar) in text.unicodeScalars.enumerated() {
                vector[Int(scalar.value) % 8] += Float(offset % 3 + 1)
            }
            return vector
        }
    }
}

@Suite("Remote embedder", .serialized)
struct EmbedderTests {
    @Test("embeds text and reports the dimension it was told to expect",
          .timeLimit(.minutes(1)))
    func embedsRealText() async throws {
        guard let model = await servedEmbeddingModel(), let size = await dimensions(of: model) else {
            Issue.record("skipped: no embedding model on :1234")
            return
        }
        let embedder = RemoteEmbedder(baseURL: endpoint, model: model,
                                      profile: testProfile(model, dimensions: size))
        let vectors = try await embedder.embed(["การให้อินซูลินในผู้ป่วยเบาหวาน",
                                                "insulin therapy in diabetic patients"])
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == size })
    }

    @Test("a wrong dimension is caught rather than indexed", .timeLimit(.minutes(1)))
    func dimensionMismatchIsFatal() async throws {
        guard let model = await servedEmbeddingModel(), let size = await dimensions(of: model) else {
            Issue.record("skipped: no embedding model on :1234")
            return
        }
        // The failure P2.1 exists to prevent: a model whose dimension differs
        // from the one the index was built with must not quietly write rows.
        let wrong = RemoteEmbedder(baseURL: endpoint, model: model,
                                   profile: testProfile(model, dimensions: size + 1))
        await #expect(throws: EmbeddingError.self) { _ = try await wrong.embed("x") }
    }

    /// The model this machine serves cannot do Thai (ARCHITECTURE E.11), so
    /// the assertion is conditional on the diagnosis rather than on the model:
    /// a healthy model must rank a related sentence closer, and an unhealthy
    /// one must have been *caught* rather than used.
    @Test("a healthy model ranks related text closer; a blind one is caught",
          .timeLimit(.minutes(2)))
    func similarityIsMeaningfulWhenTheModelCanRead() async throws {
        guard let model = await servedEmbeddingModel(), let size = await dimensions(of: model) else {
            Issue.record("skipped: no embedding model on :1234")
            return
        }
        let embedder = RemoteEmbedder(baseURL: endpoint, model: model,
                                      profile: testProfile(model, dimensions: size))
        let diagnosis = try await diagnose(embedder)

        guard diagnosis.isUsable else {
            // Not a skip: the check did its job, and the KB is protected from
            // this model. P2.3 refuses to index through an embedder in this
            // state rather than filling the index with identical vectors.
            #expect(diagnosis == .blind(to: "Thai"),
                    "unexpected diagnosis for \(model): \(diagnosis)")
            return
        }

        let vectors = try await embedder.embed([
            "การให้อินซูลินในผู้ป่วยเบาหวาน",
            "การควบคุมระดับน้ำตาลในเลือดของผู้ป่วยเบาหวาน",
            "การปนเปื้อนโลหะหนักในแหล่งน้ำดิบ",
        ])
        let related = cosineSimilarity(vectors[0], vectors[1])
        let unrelated = cosineSimilarity(vectors[0], vectors[2])
        #expect(related > unrelated, "related \(related) vs unrelated \(unrelated)")
    }

    @Test("the health check catches a model that cannot read a script")
    func diagnosisCatchesBlindness() async throws {
        // Exercised against stubs so the mechanism is tested on every machine,
        // not only on one that happens to serve a broken model.
        #expect(try await diagnose(ThaiBlindEmbedder()) == .blind(to: "Thai"))
        #expect(try await diagnose(HonestEmbedder()) == .healthy)
    }

    @Test("a dead endpoint fails with a legible error", .timeLimit(.minutes(1)))
    func deadEndpoint() async {
        let dead = RemoteEmbedder(baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                                  model: "x", profile: .bgeM3)
        await #expect(throws: EmbeddingError.self) { _ = try await dead.embed("x") }
    }
}
