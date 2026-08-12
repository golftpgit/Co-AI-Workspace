import Testing
import Foundation
@testable import MLXRuntime

// ─────────────────────────────────────────────────────────────
// What can be checked without loading a model.
//
// Everything that needs the real weights lives in `Sources/MLXCheck` and runs
// from scripts/check.sh: MLX locates its Metal kernels through the main
// bundle, and under `swift test` the main bundle is SwiftPM's test helper
// (ARCHITECTURE E.13).
// ─────────────────────────────────────────────────────────────

private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "coai-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// Writes the files a catalogue looks at, and nothing else.
    @discardableResult
    func makeModel(_ path: String,
                   config: String = #"{"model_type": "qwen3", "max_position_embeddings": 8192}"#,
                   chatTemplate: String? = "{%- for m in messages %}{{ m.content }}{%- endfor %}",
                   weightBytes: Int = 1_024) throws -> URL {
        let directory = root.appending(path: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try config.write(to: directory.appending(path: "config.json"),
                         atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: weightBytes)
            .write(to: directory.appending(path: "model.safetensors"))
        if let chatTemplate {
            try chatTemplate.write(to: directory.appending(path: "chat_template.jinja"),
                                   atomically: true, encoding: .utf8)
        }
        return directory
    }

    func catalog() -> LocalModelCatalog { LocalModelCatalog(searchPaths: [root]) }
}

@Suite("Local model catalogue")
struct LocalModelCatalogTests {

    @Test("finds a model in a nested directory the way LM Studio lays them out")
    func findsNestedModels() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("lmstudio-community/Qwen3-8B-MLX-4bit")

        let found = await fixture.catalog().installed()
        #expect(found.count == 1)
        #expect(found.first?.name == "lmstudio-community/Qwen3-8B-MLX-4bit")
        #expect(found.first?.contextWindow == 8_192)
    }

    /// The embedding model sits in the same cache as the chat models, has the
    /// same three files, and fails deep inside generation if it is loaded as
    /// one. The chat template is what tells them apart.
    @Test("an embedding model is not offered as a chat model")
    func ignoresEmbeddingModels() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("models--mlx-community--bge-m3-mlx-8bit/snapshots/abc123",
                              chatTemplate: nil)
        try fixture.makeModel("models--mlx-community--Qwen3-4B-4bit/snapshots/def456")

        let found = await fixture.catalog().installed()
        #expect(found.count == 1)
        // A Hugging Face cache entry reads back as the repository it came from.
        #expect(found.first?.name == "mlx-community/Qwen3-4B-4bit")
    }

    /// LM Studio's `Qwen3-VL-4B-Instruct` has every file a chat model has —
    /// weights, tokenizer, chat template — and dies at load with
    /// `unsupportedModelType("qwen3_vl")`. Offering it hands the router a tier
    /// that cannot answer, and on a machine where it is the largest model it
    /// would have been *the* Tier 0.5 model.
    @Test("an architecture this runtime cannot build is not offered")
    func ignoresUnsupportedArchitectures() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
                              config: #"{"model_type": "qwen3_vl"}"#)
        try fixture.makeModel("lmstudio-community/Qwen3-8B-MLX-4bit")

        let found = await fixture.catalog().installed()
        #expect(found.map(\.name) == ["lmstudio-community/Qwen3-8B-MLX-4bit"])
    }

    /// A cancelled download leaves the small files behind — config, template,
    /// the first shard — and keeping them is the point: restarting continues
    /// from there. What must not happen is the half-downloaded model being
    /// offered as a working one and failing at load.
    @Test("a half-downloaded model is not offered until its last shard arrives")
    func ignoresPartialDownloads() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = try fixture.makeModel("mlx-community/Qwen3-30B-A3B-4bit")
        try #"""
        {"weight_map": {"a": "model-00001-of-00002.safetensors",
                        "b": "model-00002-of-00002.safetensors"}}
        """#.write(to: directory.appending(path: "model.safetensors.index.json"),
                     atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 16)
            .write(to: directory.appending(path: "model-00001-of-00002.safetensors"))

        #expect(await fixture.catalog().installed().isEmpty)

        // The last shard arrives; now it is a model.
        try Data(repeating: 1, count: 16)
            .write(to: directory.appending(path: "model-00002-of-00002.safetensors"))
        #expect(await fixture.catalog().installed().count == 1)
    }

    @Test("a directory with no weights is not a model")
    func requiresWeights() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = fixture.root.appending(path: "empty")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"model_type": "qwen3"}"#.write(to: directory.appending(path: "config.json"),
                       atomically: true, encoding: .utf8)

        #expect(await fixture.catalog().installed().isEmpty)
    }

    /// The router filters candidates on the declared window. A checkpoint that
    /// advertises 262,144 tokens on a 16 GB machine would attract exactly the
    /// prompts that take the machine down — measured: a 7.6k-token prompt to a
    /// 9B model already cost ~7.4 GB (the note in Engine.swift).
    @Test("a context window larger than the machine can serve is capped")
    func capsAbsurdContextWindows() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel(
            "vendor/Qwen3.5-9B",
            config: #"{"model_type": "qwen3", "text_config": {"max_position_embeddings": 262144}}"#)

        let model = try #require(await fixture.catalog().installed().first)
        #expect(model.declaredContextWindow == 262_144)
        #expect(model.contextWindow == LocalModelCatalog.servableContextWindowCap)
    }

    @Test("a config that says nothing gets a small window, not a generous guess")
    func unknownContextWindowIsConservative() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("vendor/mystery", config: #"{"model_type": "qwen3"}"#)

        let model = try #require(await fixture.catalog().installed().first)
        #expect(model.contextWindow == LocalModelCatalog.conservativeContextWindow)
    }

    /// Declared, not assumed: the router sends tool work to whoever says they
    /// can do it, and a template with no tool markup cannot emit a tool call
    /// however the request is phrased.
    @Test("tool support is read off the model's own chat template")
    func toolSupportComesFromTheTemplate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("vendor/plain", chatTemplate: "{{ messages[0].content }}")
        try fixture.makeModel("vendor/withtools",
                              chatTemplate: "{% for t in tools %}<tool_call>{{ t }}</tool_call>{% endfor %}")

        let catalog = fixture.catalog()
        #expect(await catalog.model(named: "plain")?.supportsTools == false)
        #expect(await catalog.model(named: "withtools")?.supportsTools == true)
    }

    @Test("the preferred model is the largest one that fits")
    func preferredIsLargestThatFits() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("vendor/small", weightBytes: 1_024)
        try fixture.makeModel("vendor/large", weightBytes: 64_000)

        let roomy = MachineMemory(totalBytes: 64_000_000_000, availableBytes: 48_000_000_000)
        #expect(await fixture.catalog().preferred(memory: roomy)?.name == "vendor/large")
    }

    /// Biggest-that-fits, not biggest: a model over the line does not answer
    /// worse, it takes the machine down (P5.3). The two fixtures differ in
    /// *shape* rather than file size, because what makes a model impossible on
    /// a small machine is usually its KV cache, not its weights.
    @Test("a model that would not fit loses to one that would, even if it is bigger")
    func preferredSkipsWhatDoesNotFit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // 4 layers, 2 kv heads, 64-wide: ~2 KB per token.
        try fixture.makeModel(
            "vendor/light",
            config: #"{"model_type":"qwen3","max_position_embeddings":8192,"num_hidden_layers":4,"num_attention_heads":4,"num_key_value_heads":2,"head_dim":64}"#,
            weightBytes: 1_024)
        // 80 layers, 64 kv heads, 256-wide: ~5 MB per token, so ~42 GB of KV
        // cache at the assumed 8k context — impossible on any laptop.
        try fixture.makeModel(
            "vendor/heavy",
            config: #"{"model_type":"qwen3","max_position_embeddings":8192,"num_hidden_layers":80,"num_attention_heads":64,"num_key_value_heads":64,"head_dim":256}"#,
            weightBytes: 64_000)

        let memory = MachineMemory(totalBytes: 16_000_000_000, availableBytes: 8_000_000_000)
        let all = await fixture.catalog().installed()
        #expect(all.count == 2)
        // The bigger file is the one that cannot run here…
        let heavy = try #require(all.first { $0.name == "vendor/heavy" })
        #expect(AdmissionControl.admit(heavy, memory: memory).isBlocking)
        // …so the smaller one is what gets chosen, despite the size sort.
        #expect(await fixture.catalog().preferred(memory: memory)?.name == "vendor/light")
    }

    @Test("a search path that does not exist is not an error")
    func missingSearchPathIsFine() async {
        let catalog = LocalModelCatalog(
            searchPaths: [URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")])
        #expect(await catalog.installed().isEmpty)
    }
}
