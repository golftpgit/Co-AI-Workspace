import Foundation
import Knowledge
import EmbeddingRuntime

// ─────────────────────────────────────────────────────────────
// The embedding model's contract, checked against the real model.
//
// This is an executable rather than a test because of how MLX finds its Metal
// kernels: it searches the main bundle and the loaded bundles for
// `mlx-swift_Cmlx.bundle`. Under `swift test` the process is SwiftPM's test
// helper and the .xctest wrapper has no Info.plist, so neither lookup finds
// anything — MLX dies with "Failed to load the default metallib" no matter
// where the bundle is placed. A plain executable resolves it from its own
// directory, which is where scripts/check.sh puts it.
//
// Run by scripts/check.sh. Everything about the embedding layer that does not
// need the model itself is tested normally in Tests/EmbeddingRuntimeTests.
// ─────────────────────────────────────────────────────────────

/// Top-level code is main-actor isolated; the counter has to be too.
@MainActor final class Failures {
    static let shared = Failures()
    var count = 0
}

@MainActor
func check(_ name: String, _ body: () async throws -> String) async {
    let start = Date()
    do {
        let detail = try await body()
        print(String(format: "   ✓ %@ (%.1fs) %@", name, -start.timeIntervalSinceNow, detail))
    } catch {
        print(String(format: "   ✗ %@ (%.1fs) %@", name, -start.timeIntervalSinceNow, "\(error)"))
        Failures.shared.count += 1
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let embedder = MLXEmbedder()
var vectors: [[Float]] = []

await check("model loads and embeds Thai") {
    vectors = try await embedder.embed([
        "การให้อินซูลินในผู้ป่วยเบาหวาน",
        "การควบคุมระดับน้ำตาลในเลือดของผู้ป่วยเบาหวาน",
        "การปนเปื้อนโลหะหนักในแหล่งน้ำดิบ",
    ])
    guard vectors.count == 3 else { throw CheckFailure("got \(vectors.count) vectors") }
    return "\(vectors.count) vectors"
}

await check("dimensions match the profile P2.1 locked") {
    guard let size = vectors.first?.count, size == 1_024 else {
        throw CheckFailure("got \(vectors.first?.count ?? 0), expected 1024")
    }
    return "1024"
}

await check("related text sits closer than unrelated") {
    guard vectors.count == 3 else { throw CheckFailure("no vectors") }
    let related = cosineSimilarity(vectors[0], vectors[1])
    let unrelated = cosineSimilarity(vectors[0], vectors[2])
    guard related > unrelated else {
        throw CheckFailure(String(format: "related %.3f <= unrelated %.3f", related, unrelated))
    }
    return String(format: "%.3f vs %.3f", related, unrelated)
}

await check("not blind to any script we index") {
    let diagnosis = try await diagnose(embedder)
    guard diagnosis.isUsable else { throw CheckFailure("\(diagnosis)") }
    return ""
}

await check("a dimension it does not produce is refused") {
    // Claiming the wrong dimension must fail at the embedder rather than write
    // rows an index cannot use.
    let lying = MLXEmbedder(profile: EmbeddingProfile(
        modelID: "bge-m3", revision: "mlx-8bit", dimensions: 768))
    do {
        _ = try await lying.embed("x")
        throw CheckFailure("a 768-dimension claim was accepted")
    } catch is EmbeddingError {
        return ""
    }
}

exit(Failures.shared.count == 0 ? 0 : 1)
