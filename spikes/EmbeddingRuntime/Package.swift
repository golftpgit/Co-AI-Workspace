// swift-tools-version: 6.2
import PackageDescription

// Spike: can bge-m3 run inside our own process rather than over HTTP to
// LM Studio? Kept outside the main package until the answer is yes, so a
// failed spike costs nothing to delete (ARCHITECTURE §0.3).
//
// mlx-swift-lm ships the model and the pooling but deliberately no downloader
// and no tokenizer — those are protocols the host supplies. swift-transformers
// has both, so the adapters in the source below are the actual work an
// EmbeddingRuntime would need.
let package = Package(
    name: "EmbeddingRuntimeSpike",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "EmbeddingRuntimeSpike",
            dependencies: [
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ])
    ]
)
