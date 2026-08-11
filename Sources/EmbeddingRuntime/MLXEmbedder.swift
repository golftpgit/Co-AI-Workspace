import Foundation
import Knowledge
import MLX
import MLXEmbedders
import MLXLMCommon
import Hub
import Tokenizers

// ─────────────────────────────────────────────────────────────
// The embedding model, running in our own process (ARCHITECTURE E.13, P2.8).
//
// Why not an HTTP endpoint: the knowledge base's correctness depends on this
// model never changing underneath it, and a model served by another
// application can be updated, unloaded or deleted without telling us. During
// one afternoon of development LM Studio evicted the model mid-request twice.
//
// Why the model id includes the conversion: `bge-m3` from the MLX conversion
// and `bge-m3` from a GGUF build produce *orthogonal* vectors — measured at
// cosine ≈ 0 on identical sentences (E.13). The name alone does not identify a
// vector space, which is what `EmbeddingProfile.revision` is for.
// ─────────────────────────────────────────────────────────────

public actor MLXEmbedder: Embedder {
    public nonisolated let identifier: String
    public nonisolated let profile: EmbeddingProfile

    private let repository: String
    private var container: EmbedderModelContainer?

    /// What P2.1 measured and locked, in the build that actually loads.
    /// `EmbedderRegistry.bge_m3` points at `BAAI/bge-m3`, whose safetensors use
    /// Hugging Face layer names the bundled BERT port cannot read (E.13).
    public static let bgeM3Repository = "mlx-community/bge-m3-mlx-8bit"

    public static let bgeM3Profile = EmbeddingProfile(
        modelID: "bge-m3", revision: "mlx-8bit", dimensions: 1_024,
        pooling: .cls, normalised: true)

    public init(repository: String = MLXEmbedder.bgeM3Repository,
                profile: EmbeddingProfile = MLXEmbedder.bgeM3Profile) {
        self.repository = repository
        self.profile = profile
        self.identifier = repository
    }

    /// Downloads on first use and keeps the model resident. Weights land in the
    /// Hugging Face cache; P5.2 moves that into the app's own container so the
    /// bundle owns its models outright.
    private func loaded() async throws -> EmbedderModelContainer {
        if let container { return container }
        do {
            let loaded = try await EmbedderModelFactory.shared.loadContainer(
                from: HubDownloader(), using: HubTokenizerLoader(),
                configuration: ModelConfiguration(id: repository))
            container = loaded
            return loaded
        } catch {
            throw EmbeddingError.transport("loading \(repository): \(error)")
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let container = try await loaded()

        let vectors: [[Float]] = await container.perform { context in
            let tokenizer = context.tokenizer
            let encoded = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            let padTo = encoded.reduce(into: 16) { $0 = max($0, $1.count) }
            let padding = tokenizer.eosTokenId ?? 0

            let padded = stacked(encoded.map { row in
                MLXArray(row + Array(repeating: padding, count: padTo - row.count))
            })
            let mask = (padded .!= padding)
            let result = context.pooling(
                context.model(padded, positionIds: nil,
                              tokenTypeIds: MLXArray.zeros(like: padded),
                              attentionMask: mask),
                normalize: true, applyLayerNorm: true)
            result.eval()
            return result.map { $0.asArray(Float.self) }
        }

        guard vectors.count == texts.count else { throw EmbeddingError.empty }
        for vector in vectors where vector.count != profile.dimensions {
            throw EmbeddingError.dimensionMismatch(expected: profile.dimensions,
                                                   got: vector.count)
        }
        return vectors
    }
}

// MARK: - the two protocols mlx-swift-lm leaves to the host

/// mlx-swift-lm ships no downloader on purpose, so the choice of where weights
/// come from stays with the application.
struct HubDownloader: MLXLMCommon.Downloader {
    private let hub = HubApi()

    func download(id: String, revision: String?, matching patterns: [String],
                  useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        try await hub.snapshot(from: id, revision: revision ?? "main",
                               matching: patterns, progressHandler: progressHandler)
    }
}

/// Bridges swift-transformers' tokenizer to the minimal protocol mlx-swift-lm
/// declares so it need not depend on swift-transformers itself.
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
        // An embedding model has no chat template. Nothing on this path asks
        // for one, and failing beats returning something plausible.
        throw EmbeddingError.transport("an embedding model has no chat template")
    }
}

struct HubTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        BridgedTokenizer(inner: try await AutoTokenizer.from(modelFolder: directory))
    }
}
