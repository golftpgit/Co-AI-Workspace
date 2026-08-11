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
                   config: String = #"{"max_position_embeddings": 8192}"#,
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
    func findsNestedModels() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("lmstudio-community/Qwen3-8B-MLX-4bit")

        let found = fixture.catalog().installed()
        #expect(found.count == 1)
        #expect(found.first?.name == "lmstudio-community/Qwen3-8B-MLX-4bit")
        #expect(found.first?.contextWindow == 8_192)
    }

    /// The embedding model sits in the same cache as the chat models, has the
    /// same three files, and fails deep inside generation if it is loaded as
    /// one. The chat template is what tells them apart.
    @Test("an embedding model is not offered as a chat model")
    func ignoresEmbeddingModels() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("models--mlx-community--bge-m3-mlx-8bit/snapshots/abc123",
                              chatTemplate: nil)
        try fixture.makeModel("models--mlx-community--Qwen3-4B-4bit/snapshots/def456")

        let found = fixture.catalog().installed()
        #expect(found.count == 1)
        // A Hugging Face cache entry reads back as the repository it came from.
        #expect(found.first?.name == "mlx-community/Qwen3-4B-4bit")
    }

    @Test("a directory with no weights is not a model")
    func requiresWeights() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = fixture.root.appending(path: "empty")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{}".write(to: directory.appending(path: "config.json"),
                       atomically: true, encoding: .utf8)

        #expect(fixture.catalog().installed().isEmpty)
    }

    /// The router filters candidates on the declared window. A checkpoint that
    /// advertises 262,144 tokens on a 16 GB machine would attract exactly the
    /// prompts that take the machine down — measured: a 7.6k-token prompt to a
    /// 9B model already cost ~7.4 GB (the note in Engine.swift).
    @Test("a context window larger than the machine can serve is capped")
    func capsAbsurdContextWindows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel(
            "vendor/Qwen3.5-9B",
            config: #"{"text_config": {"max_position_embeddings": 262144}}"#)

        let model = try #require(fixture.catalog().installed().first)
        #expect(model.declaredContextWindow == 262_144)
        #expect(model.contextWindow == LocalModelCatalog.servableContextWindowCap)
    }

    @Test("a config that says nothing gets a small window, not a generous guess")
    func unknownContextWindowIsConservative() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("vendor/mystery", config: "{}")

        let model = try #require(fixture.catalog().installed().first)
        #expect(model.contextWindow == LocalModelCatalog.conservativeContextWindow)
    }

    /// Declared, not assumed: the router sends tool work to whoever says they
    /// can do it, and a template with no tool markup cannot emit a tool call
    /// however the request is phrased.
    @Test("tool support is read off the model's own chat template")
    func toolSupportComesFromTheTemplate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("vendor/plain", chatTemplate: "{{ messages[0].content }}")
        try fixture.makeModel("vendor/withtools",
                              chatTemplate: "{% for t in tools %}<tool_call>{{ t }}</tool_call>{% endfor %}")

        let catalog = fixture.catalog()
        #expect(catalog.model(named: "plain")?.supportsTools == false)
        #expect(catalog.model(named: "withtools")?.supportsTools == true)
    }

    @Test("the preferred model is the largest one installed")
    func preferredIsLargest() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.makeModel("vendor/small", weightBytes: 1_024)
        try fixture.makeModel("vendor/large", weightBytes: 64_000)

        #expect(fixture.catalog().preferred()?.name == "vendor/large")
    }

    @Test("a search path that does not exist is not an error")
    func missingSearchPathIsFine() {
        let catalog = LocalModelCatalog(
            searchPaths: [URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")])
        #expect(catalog.installed().isEmpty)
    }
}
