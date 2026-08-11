import Testing
import Foundation
import Knowledge
@testable import EmbeddingRuntime

// ─────────────────────────────────────────────────────────────
// What can be checked without loading the model.
//
// Anything that needs the real weights lives in `Sources/EmbeddingCheck` and
// runs from scripts/check.sh instead: MLX locates its Metal kernels through
// the main bundle, and under `swift test` the main bundle is SwiftPM's test
// helper — the lookup cannot reach ours no matter where the kernels are put.
// ─────────────────────────────────────────────────────────────

@Suite("MLX embedder")
struct MLXEmbedderTests {
    @Test("the profile names the conversion, not just the model")
    func profileIdentifiesTheVectorSpace() {
        let profile = MLXEmbedder.bgeM3Profile
        #expect(profile.dimensions == 1_024)
        #expect(profile.revision == "mlx-8bit")

        // The MLX conversion and the GGUF build of "bge-m3" produce orthogonal
        // vectors — cosine ≈ 0 on identical sentences (ARCHITECTURE E.13). If
        // the two shared an index id they would silently destroy each other.
        let gguf = EmbeddingProfile(modelID: "bge-m3", revision: "gguf-q8_0",
                                    dimensions: 1_024)
        #expect(profile.id != gguf.id, "two incompatible builds share an index id")
    }

    @Test("the repository is the conversion that actually loads")
    func repositoryIsTheWorkingConversion() {
        // EmbedderRegistry.bge_m3 points at BAAI/bge-m3, whose safetensors use
        // Hugging Face layer names the bundled BERT port cannot read; it fails
        // with keyNotFound(["encoder","layers","0","ln2","weight"]).
        #expect(MLXEmbedder.bgeM3Repository == "mlx-community/bge-m3-mlx-8bit")
    }

    @Test("an embedder declares the dimension its profile promises")
    func dimensionsComeFromTheProfile() {
        #expect(MLXEmbedder().dimensions == MLXEmbedder.bgeM3Profile.dimensions)
    }
}
