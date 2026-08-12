import Testing
import Foundation
@testable import MLXRuntime

// ─────────────────────────────────────────────────────────────
// Whether a model fits, decided without depending on how much memory the
// machine running the tests happens to have free.
// ─────────────────────────────────────────────────────────────

private let gigabyte: Int64 = 1_073_741_824

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "coai-admission-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A model directory with a real shape in its config, so the KV-cache estimate
/// has something to read. These are qwen3.5-9B's numbers.
private func writeModel(_ directory: URL, weightBytes: Int, shaped: Bool = true) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = shaped ? #"""
    {"model_type": "qwen3",
     "text_config": {"max_position_embeddings": 262144, "num_hidden_layers": 32,
                     "num_attention_heads": 16, "num_key_value_heads": 4, "head_dim": 256}}
    """# : #"{"model_type": "qwen3", "max_position_embeddings": 8192}"#
    try config.write(to: directory.appending(path: "config.json"),
                     atomically: true, encoding: .utf8)
    try "{{ messages }}".write(to: directory.appending(path: "chat_template.jinja"),
                               atomically: true, encoding: .utf8)
    try Data(repeating: 3, count: weightBytes)
        .write(to: directory.appending(path: "model.safetensors"))
}

private func model(_ sizeOnDisk: Int64, contextWindow: Int = 32_768) -> LocalModel {
    LocalModel(name: "vendor/test", directory: URL(fileURLWithPath: "/nonexistent"),
               contextWindow: contextWindow, declaredContextWindow: contextWindow,
               sizeOnDisk: sizeOnDisk, supportsTools: true)
}

@Suite("Admission control")
struct AdmissionControlTests {

    /// The whole point of the estimate: a 4 GB model does not cost 4 GB.
    @Test("the KV cache is read from the model's own shape, not guessed")
    func kvCacheComesFromTheConfig() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeModel(root.appending(path: "shaped"), weightBytes: 1_024)

        // 2 (key+value) × 32 layers × 4 kv heads × 256 head dim × 2 bytes.
        let perToken = try #require(
            LocalModelCatalog.kvCacheBytesPerToken(in: root.appending(path: "shaped")))
        #expect(perToken == 131_072)
    }

    @Test("a config with no shape in it still gets an estimate, not a crash")
    func fallsBackWhenShapeIsMissing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeModel(root.appending(path: "plain"), weightBytes: 1_024, shaped: false)

        #expect(LocalModelCatalog.kvCacheBytesPerToken(in: root.appending(path: "plain")) == nil)
        // Weights + a fifth + half a gigabyte of overhead.
        let estimate = AdmissionControl.estimatedResidentBytes(model(5 * gigabyte))
        #expect(estimate > 5 * gigabyte)
        #expect(estimate < 7 * gigabyte)
    }

    /// Checked against the one real measurement there is: qwen3.5-9B-4bit,
    /// 5.6 GB on disk, ~7.4 GB resident at 7.6k tokens.
    @Test("the estimate lands near what was actually measured on this hardware")
    func estimateMatchesTheMeasurement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "qwen")
        try writeModel(directory, weightBytes: 1_024)

        let onDisk = Int64(5.6 * Double(gigabyte))
        let measured = LocalModel(name: "qwen3.5-9B", directory: directory,
                                  contextWindow: 32_768, declaredContextWindow: 262_144,
                                  sizeOnDisk: onDisk, supportsTools: true)
        let estimate = AdmissionControl.estimatedResidentBytes(measured, contextTokens: 7_600)

        let measuredBytes = Int64(7.4 * Double(gigabyte))
        let error = abs(Double(estimate - measuredBytes)) / Double(measuredBytes)
        #expect(error < 0.10, "estimate \(estimate) vs measured \(measuredBytes)")
    }

    @Test("a model that fits comfortably is admitted")
    func comfortableModelFits() {
        let memory = MachineMemory(totalBytes: 32 * gigabyte, availableBytes: 20 * gigabyte)
        let admission = AdmissionControl.admit(model(4 * gigabyte), memory: memory)
        #expect(admission.verdict == .fits)
        #expect(!admission.isBlocking)
    }

    /// Runnable, but the machine would have nothing left. Said out loud and
    /// not blocked — the user may know they are about to close everything else.
    @Test("a model that only just fits is called tight, not refused")
    func borderlineModelIsTight() {
        let memory = MachineMemory(totalBytes: 16 * gigabyte, availableBytes: 8 * gigabyte)
        let admission = AdmissionControl.admit(model(6 * gigabyte), memory: memory)
        #expect(admission.verdict == .tight)
        #expect(!admission.isBlocking)
    }

    /// The Done-when of P5.3. What is being prevented is not a bad answer but
    /// a machine that stops responding while it swaps.
    @Test("a model larger than free memory is refused, with the numbers")
    func oversizedModelIsRefused() {
        let memory = MachineMemory(totalBytes: 16 * gigabyte, availableBytes: 6 * gigabyte)
        let admission = AdmissionControl.admit(model(17 * gigabyte), memory: memory)
        #expect(admission.verdict == .tooLarge)
        #expect(admission.isBlocking)
        #expect(admission.estimatedResidentBytes > admission.availableBytes)
        // A refusal has to carry both numbers, or it reads as an opinion.
        #expect(admission.reason.contains("6.0 GB"))
        #expect(admission.reason.contains("ค้าง"))
    }

    /// Before the download there is nothing on disk to measure, so the
    /// catalogue's recorded size stands in.
    @Test("a catalogue entry is judged before it is downloaded")
    func catalogueEntryIsJudgedUpFront() {
        let memory = MachineMemory(totalBytes: 16 * gigabyte, availableBytes: 10 * gigabyte)
        let big = try! #require(RecommendedModels.all.last)   // the 27B
        #expect(AdmissionControl.admit(big, memory: memory).isBlocking)

        let small = RecommendedModels.all[0]                  // the 0.6B
        #expect(!AdmissionControl.admit(small, memory: memory).isBlocking)
    }

    @Test("the RAM table in §9.4 is the one the code uses")
    func sizeClassesFollowTheTable() {
        #expect(MachineSizeClass.forMachine(totalBytes: 8 * gigabyte) == .under16)
        // A 16 GB Mac reports a shade under 16 GiB and is not an 8 GB machine.
        #expect(MachineSizeClass.forMachine(totalBytes: Int64(15.9 * Double(gigabyte))) == .upTo32)
        #expect(MachineSizeClass.forMachine(totalBytes: 48 * gigabyte) == .upTo64)
        #expect(MachineSizeClass.forMachine(totalBytes: 128 * gigabyte) == .above64)
        #expect(MachineSizeClass.forMachine(totalBytes: 16 * gigabyte).recommendedSize
                == "7–8B (4-bit)")
    }

    @Test("this machine answers the memory question without trapping")
    func readsRealMemory() {
        let memory = MachineMemory.current()
        #expect(memory.totalBytes > 0)
        #expect(memory.availableBytes > 0)
        #expect(memory.availableBytes <= memory.totalBytes)
    }
}

@Suite("Tier 0.5 under memory pressure")
struct LocalTierAdmissionTests {

    /// A tier that says "available" and then takes the machine down is worse
    /// than one that says "not now": the router walks past an unavailable tier
    /// and the work still gets done (§9.2).
    @Test("a model that no longer fits reports itself unavailable")
    func unavailableWhenMemoryIsGone() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "vendor/big")
        try writeModel(directory, weightBytes: 2_048)

        let big = LocalModel(name: "vendor/big", directory: directory,
                             contextWindow: 32_768, declaredContextWindow: 32_768,
                             sizeOnDisk: 17 * gigabyte, supportsTools: true)

        let roomy = LocalTier(model: big, memory: {
            MachineMemory(totalBytes: 64 * gigabyte, availableBytes: 48 * gigabyte)
        })
        #expect(await roomy.isAvailable())

        let crowded = LocalTier(model: big, memory: {
            MachineMemory(totalBytes: 16 * gigabyte, availableBytes: 2 * gigabyte)
        })
        #expect(await crowded.isAvailable() == false)
    }
}
