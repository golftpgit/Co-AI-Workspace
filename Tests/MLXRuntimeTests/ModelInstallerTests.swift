import Testing
import Foundation
import LLMProviders
@testable import MLXRuntime

// ─────────────────────────────────────────────────────────────
// The parts of the model manager that do not need the network.
//
// The download itself is checked against the Hub in `MLXCheck`
// (`COAI_CHECK_DOWNLOAD=1`), because a test suite that downloads gigabytes is
// a test suite nobody runs.
// ─────────────────────────────────────────────────────────────

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "coai-installer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func writeModel(_ directory: URL, bytes: Int = 2_048) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #"{"model_type": "qwen3", "max_position_embeddings": 4096}"#
        .write(to: directory.appending(path: "config.json"), atomically: true, encoding: .utf8)
    try "{{ messages }}".write(to: directory.appending(path: "chat_template.jinja"),
                               atomically: true, encoding: .utf8)
    try Data(repeating: 7, count: bytes).write(to: directory.appending(path: "model.safetensors"))
    return directory
}

@Suite("Model installer")
struct ModelInstallerTests {

    @Test("a download that would not fit is refused before it starts")
    func refusesBeyondQuota() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(destination: root, quotaGigabytes: 1)

        let tooBig = ModelCatalogEntry(
            repository: "vendor/huge", displayName: "Huge", parameters: "70B",
            quantization: "4-bit", downloadBytes: 40_000_000_000,
            minimumRAMBytes: 64_000_000_000, summary: "")

        // Finding out at 90% costs the user everything they already waited for.
        await #expect(throws: ModelInstallError.self) { try await installer.admits(tooBig) }
    }

    @Test("space already used counts against the quota")
    func usedSpaceCounts() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeModel(root.appending(path: "models/vendor/one"), bytes: 4_096)
        let installer = ModelInstaller(destination: root, quotaGigabytes: 1)

        let report = await installer.storage()
        #expect(report.usedBytes > 4_000)
        #expect(report.remainingBytes < report.quotaBytes)
    }

    /// The catalogue also finds LM Studio's library and the Hugging Face
    /// cache. Deleting another application's files from a screen that says
    /// "ลบ" would be an unpleasant surprise.
    @Test("only models this app downloaded can be deleted")
    func refusesToDeleteSomebodyElsesModel() async throws {
        let ours = try temporaryDirectory()
        let theirs = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: ours)
            try? FileManager.default.removeItem(at: theirs)
        }
        try writeModel(theirs.appending(path: "lmstudio/Qwen"))
        let foreign = try #require(await LocalModelCatalog(searchPaths: [theirs]).installed().first)
        let installer = ModelInstaller(destination: ours)

        await #expect(throws: ModelInstallError.self) { try await installer.delete(foreign) }
        #expect(FileManager.default.fileExists(atPath: foreign.directory.path(percentEncoded: false)))
    }

    @Test("deleting ours removes the weights and the empty shell around them")
    func deleteRemovesModelAndEmptyParents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeModel(root.appending(path: "models/mlx-community/Qwen3-4B-4bit"))
        let installer = ModelInstaller(destination: root)
        let model = try #require(await LocalModelCatalog(searchPaths: [root]).installed().first)

        try await installer.delete(model)

        #expect(!FileManager.default.fileExists(atPath: model.directory.path(percentEncoded: false)))
        // A leftover `mlx-community/` reads as "still installed" in Finder.
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "models/mlx-community").path(percentEncoded: false)))
        #expect(await installer.storage().usedBytes == 0)
    }
}

@Suite("Recommended list")
struct RecommendedModelsTests {

    /// Every entry has to be one mlx-swift-lm can build, or the user pays for
    /// the download and finds out at load time.
    @Test("entries are MLX conversions, ordered by the RAM they need, with no duplicates")
    func listIsCoherent() {
        let all = RecommendedModels.all
        #expect(all.count == Set(all.map(\.repository)).count)
        #expect(all.allSatisfy { $0.repository.hasPrefix("mlx-community/") })
        // Ordered by RAM class rather than download size: the list is a ladder
        // the machine's own memory tells the user where to stop, and a 30B MoE
        // is heavier to run than a dense 27B that downloads slightly smaller.
        #expect(all == all.sorted { $0.minimumRAMBytes < $1.minimumRAMBytes })
        #expect(all.allSatisfy { $0.downloadBytes > 0 && $0.minimumRAMBytes > 0 })
    }

    @Test("what this machine can hold is a fact about the machine")
    func fitsUsesPhysicalMemory() {
        let tiny = ModelCatalogEntry(repository: "mlx-community/x", displayName: "x",
                                     parameters: "0.6B", quantization: "4-bit",
                                     downloadBytes: 1, minimumRAMBytes: 1, summary: "")
        let absurd = ModelCatalogEntry(repository: "mlx-community/y", displayName: "y",
                                       parameters: "400B", quantization: "4-bit",
                                       downloadBytes: 1, minimumRAMBytes: 1 << 60, summary: "")
        #expect(RecommendedModels.fits(tiny))
        #expect(!RecommendedModels.fits(absurd))
    }
}

@Suite("Tier 0.5 slot")
struct LocalTierTests {

    @Test("with no model chosen the tier is simply unavailable")
    func emptyTierIsUnavailable() async {
        let tier = LocalTier()
        #expect(await tier.isAvailable() == false)
        #expect(tier.selected == nil)
        // Still coherent for anything that reads declarations before
        // availability rules it out.
        #expect(tier.capabilities.contextWindow > 0)

        await #expect(throws: LLMError.self) {
            for try await _ in tier.respond(to: .init(messages: [.init(.user, "hi")])) {}
        }
    }

    /// The point of the slot: a model downloaded while the app runs is usable
    /// without a restart, and the router plans with *its* capabilities.
    @Test("choosing a model changes what the tier declares")
    func selectionDrivesCapabilities() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeModel(root.appending(path: "vendor/Qwen3-4B-4bit"))
        let model = try #require(await LocalModelCatalog(searchPaths: [root]).installed().first)

        let tier = LocalTier()
        #expect(await tier.isAvailable() == false)

        tier.select(model)
        #expect(tier.selected == model)
        #expect(tier.identifier.contains("Qwen3-4B-4bit"))
        #expect(tier.capabilities.contextWindow == model.contextWindow)
        #expect(await tier.isAvailable())

        tier.select(nil)
        #expect(await tier.isAvailable() == false)
    }
}
